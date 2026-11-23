# Design notes

## Problem

OKD 4.20 moved its node OS from SCOS 9 to SCOS 10 (CentOS Stream 10). EL10 is
built for the x86-64-v3 ISA (AVX, AVX2, BMI1/2, FMA, MOVBE …) and its glibc
refuses to start on anything older:

```
Fatal glibc error: CPU does not support x86-64-v3
```

`scripts/verify-image.sh` reproduces this with qemu-user emulating a Nehalem
CPU: a CentOS Stream 10 rootfs fails on `bash -c true`, a CentOS Stream 9
rootfs passes.

## Findings that shaped the approach

* **Payload content is still EL9.** Every image of the three upstream releases
  was inspected (`scripts/verify-payload.sh` does the same check):

  | Release | Images | EL10 / SCOS 10 |
  |---|---|---|
  | 4.20.0-okd-scos.17 | 194 | `stream-coreos`, `stream-coreos-extensions` |
  | 4.21.0-okd-scos.11 | 188 | `stream-coreos`, `stream-coreos-extensions`, `driver-toolkit` |
  | 4.22.0-okd-scos.10 | 191 | `stream-coreos`, `stream-coreos-extensions`, `driver-toolkit` |

  All others carry `org.label-schema.name=CentOS Stream 9 Base Image`
  (`release=...assembly.stream.scos9`). **OKD 5.0 moved every image to CentOS
  Stream 10**, so this approach stops working there (5.x would need a full
  source rebuild).
* **SCOS 9 is still maintained upstream.** `coreos/rhel-coreos-config` keeps the
  `c9s` variant (manifest, lockfile, build args) and the CoreOS pipeline still
  publishes SCOS 9 boot images (`rhcos.mirror.openshift.com/.../streams/c9s`).
* **EL9 is a first-class OS for 4.22 code.** OCP 4.22 itself runs on RHCOS 9.8;
  the MCO has explicit EL9 paths (`osrelease.IsEL9`).
* **The node packages exist as public el9 builds.** In the upstream SCOS 10 node
  image, `openshift-kubelet`, `openshift-clients` and the credential providers
  already are el9 ART builds; only `cri-o`/`cri-tools`/`conmon-rs` come from the
  c10s Cloud SIG. `mirror.openshift.com/.../rpms/4.22-el9-beta` publishes el9
  `cri-o`, `cri-tools`, `conmon-rs`, `openshift-kubelet`, `openshift-clients`.
  These el9 Go binaries are built with `GOAMD64=v2`; the upstream c10s `crio`
  binary is `GOAMD64=v3` (checked with `scripts/check-isa.py`).

## Components

### SCOS 9 base (`make base`)

`coreos/rhel-coreos-config` built with `build-args-c9s.conf`, exactly as its
`Containerfile` documents. All minors share this base. It is independent
from the boot image (see below): a node only runs the boot image until its first
reboot into this node image.

The lockfile pins exact NEVRAs. CentOS Stream mirrors only keep a few builds
of each package (notably the kernel), so an old pin eventually becomes
unbuildable: either move the submodule forward, or build with
`SCOS_USE_LOCKFILE=0`.

### Node image (`make node`, `patches/<minor>/os`)

`openshift/os` (the OKD/OCP node layer). Its release-4.20 and release-4.21
branches still carry a `centos-9` variant (`c9s.repo`, `extensions/centos-9.yaml`);
release-4.22 dropped it, so `patches/4.22/os` re-adds it modelled on 4.21:

* 4.22 only: `c9s.repo` and `build-args-4.22-c9s.conf`;
* `packages-openshift.yaml`: for `centos-9`, packages come from c9s
  BaseOS/AppStream, the NFV SIG (`openvswitch3.5`) and `okd-el9-local`;
  the four `ose-*-credential-provider` packages are only requested for the
  other variants;
* `build-node-image.sh`: the "ART repo for SCOS" hack only runs when an ART
  repo exists (otherwise it writes a section-less repo file that breaks dnf),
  and an optional `/run/src/extra-rootfs` overlay is copied in;
* `build-node-image.sh`: `/etc/selinux/targeted` is copied into the build
  layer before packages are installed. libsemanage commits (the
  `openvswitch-selinux-extra-policy` scriptlet, then `semanage boolean`)
  atomically rename `active`/`previous`/`tmp`; on overlay storage those
  directories sit in lower layers and rename(2) fails with EXDEV, after which
  libsemanage's copy fallback ends in `Directory not empty`. Seen on GitHub's
  Ubuntu runners, reproduced locally with a plain overlay mount.

`okd-el9-local` replaces two repos the upstream `centos-9` variant cannot use
outside OpenShift CI: the CentOS Cloud SIG `okd-<minor>` repo (no c9s builds
after okd-4.20) and the CI-only ART `rhel-9.x-server-ose-<minor>` repo.
It is a local repo generated from `rpms/okd-el9-<minor>.lock` (exact NEVRA
+ sha256; `gpgcheck=0` because the Red Hat key is not part of CentOS Stream —
integrity comes from the pinned checksums). It is passed in via the
`yumrepos` build secret.

Kubelet image credential providers are not published as public RPMs. With
`WITH_CRED_PROVIDERS=1` the binaries (three in 4.20, four later) are copied from the upstream node
image (they are el9 ART builds, `GOAMD64=v2`) and ISA-checked first.

**Stream class.** The 4.22 Containerfile labels the node and extensions images
with `io.openshift.os.streamclass`. The MCO's OSImageStream feature that reads
it is disabled for SCOS in 4.21 and 4.22 (`pkg/osimagestream/helpers.go`:
`... && !version.IsSCOS()`), and the 4.22 MCO would default SCOS to
`centos-10` (`streams.go`). The label is kept as `centos-10` so the image
looks like upstream's should that change; 4.20 has no such label.

### Extensions (`make extensions`)

`openshift/os` `extensions/Containerfile` (`extensions/Dockerfile` before 4.22)
built with `--from` the c9s node image; it uses
the existing `extensions/centos-9.yaml` (kernel-rt, kernel-devel, usbguard,
ipsec, kerberos, sysstat, kata-containers).

### driver-toolkit (`make dtk`)

The upstream Dockerfile builds `FROM registry.ci.openshift.org/ocp/<ver>:base-rhel9`,
which is not public. `--from` replaces it with `images/dtk-base` (CentOS
Stream 9 with CRB/RT/NFV enabled). `KERNEL_VERSION` is read from the node
image so kmods built with DTK match the running kernel; `TAGS=scos` rewrites
the manifests to `stream-coreos` like upstream OKD does.

### Boot images, machine-os-images, installer overlay

**Rule: a minor's boot image must run an Ignition whose config spec its
machine-config-server can serve.** A new node's first boot runs the boot image's
Ignition, which fetches `https://api-int:22623/config/<pool>` with
`Accept: application/vnd.coreos.ignition+json;version=X.Y.Z, */*;q=0.1`
(a literal in coreos/ignition `internal/resource/url.go`: 3.5.0 up to Ignition
2.25.x, 3.6.0 from 2.26.0). The MCS of OKD 4.20 (`8af0c84e`) and 4.21
(`1a0b9eee`) supports at most 3.5.0 and answers 400 to 3.6.0
(`pkg/server/api.go` `detectSpecVersionFromAcceptHeader`); 4.22 (`90b26966`)
falls back to 3.5.0 (upstream MCO-2182). Ignition does not retry a 400, so the
node stops in the emergency shell. Upstream OKD keeps boot image and MCS paired
per release; okd-c9s first shipped one newer boot image (`9.0.20261110-0`,
Ignition 2.28) for every minor and broke 4.20/4.21 node joins.

The pin is therefore per minor (`SCOS9_BOOTIMAGE_BUILD` in
`versions/<minor>.env`), and must also suit the MCS of the releases a cluster
is upgraded *from*: CVO rolls cluster-baremetal-operator (runlevel 31, metal3
and the machine-os-images ISO) before the MCO (runlevel 80), so during an
upgrade new hosts get the new ISO but the old MCS. `UPGRADE_FROM_RELEASES`
lists those releases. `make check-bootimages` (`scripts/check-bootimage.sh`,
CI job `bootimage-compat`, gating the build) checks the pinned build's
artifacts, reads its Ignition version from `commitmeta.json`, takes the exact
Accept literal from coreos/ignition at that tag, starts each relevant upstream
MCS in `bootstrap` mode on `tests/mcs-bootstrap` and requires HTTP 200 with a
config. With `9.0.20261110-0` pinned it reproduces the 400 of the field report.

All three minors use `9.0.20260324-0`, the newest c9s build with Ignition
2.25.1 (kernel 5.14.0-687.el9). An MCS backport that lifts the restriction for
4.20/4.21 is kept, unapplied, in `patches/contingency/machine-config-operator/`.

On bare metal (metal3, `install_coreos` without an image URL) the installed OS
*is* the machine-os-images live ISO: IPA runs `coreos-installer --offline` from
it. The `coreos-bootimages` ConfigMap matters for MachineSets with image URLs and
the installer, not for that path.

* `scripts/gen-stream-json.py` turns the SCOS 9 build's `meta.json` into
  CoreOS stream metadata (metal ISO/PXE/raw, qemu).
* `machine-os-images` (agent installer, `oc adm node-image`, metal3 base ISO)
  is rebuilt with the SCOS 9 live ISO; `coreos-installer` and `oc` are taken
  from upstream el9 images and ISA-checked.
* `installer` / `installer-artifacts` get a one-file overlay replacing
  `/manifests/coreos-bootimages.yaml`; `oc adm release new` turns it into the
  `openshift-machine-config-operator/coreos-bootimages` ConfigMap.

### Release (`make release`)

`oc adm release new --from-release <upstream>` with the six replaced
components. All other images stay byte-identical to upstream.

## Verification

* `scripts/check-isa.py`: walks a rootfs and flags ELF objects whose
  `GNU_PROPERTY_X86_ISA_1_NEEDED` note requires v3/v4 (how EL10 marks
  binaries), and Go binaries built with `GOAMD64=v3/v4`.
* `scripts/verify-image.sh`: the above plus executing key binaries
  (bash, python, systemd, rpm-ostree, kubelet, crio, oc, ovs-vswitchd, …)
  with `qemu-x86_64-static -cpu Nehalem`.
* `scripts/verify-payload.sh`: label check of every image in the release.

## Known limitations and risks

| Risk | Impact | Mitigation |
|---|---|---|
| Boot images frozen at Ignition 2.25.x for 4.20/4.21 (kernel 5.14.0-687) | Hosts needing newer drivers during deploy/first boot could fail before the pivot to the node OS | `make check-bootimages` blocks unsafe bumps; MCS backport in `patches/contingency/` |
| SCOS 9 + OKD 4.22 is not a combination upstream tests | Unknown regressions (MCO, networking, storage) | OCP 4.22 runs on EL9 (RHCOS 9.8); test on a lab cluster before production |
| `streamclass=centos-10` label on an EL9 image (4.22) | Unused today (OSImageStream is off for SCOS); a later MCO could start relying on it | Re-check `pkg/osimagestream` when bumping |
| el9 kubelet/cri-o/oc come from the rolling `<minor>-el9-beta` mirrors | Newer z-stream than the payload; the mirror deletes old builds | Same minor version (supported skew); `rpms/okd-el9-<minor>.lock` + CI cache; `make rpms-lock` to re-pin |
| MCO 4.22 "persist NIC names" step runs on EL9 hosts (meant for the EL9→EL10 move) | Writes `.link` files pinning current NIC names | Harmless for a c9s→c9s update; names stay as they are |
| c9s mirror drops old kernels | Lockfile builds fail after a few weeks | Bump `upstream/rhel-coreos-config` or `SCOS_USE_LOCKFILE=0` |
| Credential providers copied as binaries | Not tracked by RPM | ISA-checked; disable with `WITH_CRED_PROVIDERS=0` if unused (bare metal) |
| `openshift-install` keeps its embedded SCOS 10 stream | IPI on clouds/vSphere downloads SCOS 10 images | Override the OS image in `install-config.yaml` (docs/install.md) |
| Release is not signed | `oc adm upgrade` needs `--allow-explicit-upgrade --force` | Expected for self-built payloads |
| Upstream may move more images to EL10 in later 4.22.z | Pods crash on v2 | `make verify-payload` on the upstream release before bumping |
| OKD 5.x | Every image is EL10 | Out of scope for this approach |
