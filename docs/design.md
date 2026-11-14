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

## Findings that shaped the approach (4.22.0-okd-scos.10)

* **Payload content is still EL9.** Of the 191 images, 188 carry
  `org.label-schema.name=CentOS Stream 9 Base Image`
  (`release=...assembly.stream.scos9`). Only `stream-coreos`,
  `stream-coreos-extensions` and `driver-toolkit` are EL10. 4.20 and 4.21 look
  the same; **OKD 5.0 moved every image to CentOS Stream 10**, so this cheap
  approach stops working there (5.x would need a full source rebuild).
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
`Containerfile` documents. The submodule is pinned to the commit used by the
SCOS 9 boot image build in `versions.env`, so the boot image and the node
image start from the same package set.

The lockfile pins exact NEVRAs. CentOS Stream mirrors only keep a few builds
of each package (notably the kernel), so an old pin eventually becomes
unbuildable: either move the submodule forward, or build with
`SCOS_USE_LOCKFILE=0`.

### Node image (`make node`, `patches/os`)

`openshift/os` (the OKD/OCP node layer) with a patch that re-adds a
`centos-9` variant, modelled on how release-4.19 did it:

* `c9s.repo` and `build-args-4.22-c9s.conf`;
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

`okd-el9-local` is a local repo generated from `rpms/okd-el9.lock` (exact NEVRA
+ sha256; `gpgcheck=0` because the Red Hat key is not part of CentOS Stream —
integrity comes from the pinned checksums). It is passed in via the
`yumrepos` build secret.

Kubelet image credential providers are not published as public RPMs. With
`WITH_CRED_PROVIDERS=1` the four binaries are copied from the upstream node
image (they are el9 ART builds, `GOAMD64=v2`) and ISA-checked first.

**Stream class.** The OKD 4.22 MCO hard-codes a single OS stream named
`centos-10` for SCOS (`pkg/osimagestream/streams.go`). The node and
extensions images therefore keep `io.openshift.os.streamclass=centos-10`
although they are CentOS Stream 9. The label is only a selector; patching the
MCO instead would mean rebuilding it from source.

### Extensions (`make extensions`)

`openshift/os` `extensions/Containerfile` against the c9s node image; it uses
the existing `extensions/centos-9.yaml` (kernel-rt, kernel-devel, usbguard,
ipsec, kerberos, sysstat, kata-containers).

### driver-toolkit (`make dtk`)

The upstream Dockerfile builds `FROM registry.ci.openshift.org/ocp/<ver>:base-rhel9`,
which is not public. `--from` replaces it with `images/dtk-base` (CentOS
Stream 9 with CRB/RT/NFV enabled). `KERNEL_VERSION` is read from the node
image so kmods built with DTK match the running kernel; `TAGS=scos` rewrites
the manifests to `stream-coreos` like upstream OKD does.

### Boot images, machine-os-images, installer overlay

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
| SCOS 9 + OKD 4.22 is not a combination upstream tests | Unknown regressions (MCO, networking, storage) | OCP 4.22 runs on EL9 (RHCOS 9.8); test on a lab cluster before production |
| `streamclass=centos-10` label on an EL9 image | Purely a label; an MCO change in a later 4.22.z could rely on the OS really being EL10 | Re-check `pkg/osimagestream` when bumping |
| el9 kubelet/cri-o/oc come from the rolling `4.22-el9-beta` mirror | Newer z-stream than the payload; the mirror deletes old builds | Same minor version (supported skew); `rpms/okd-el9.lock` + CI cache; `make rpms-lock` to re-pin |
| c9s mirror drops old kernels | Lockfile builds fail after a few weeks | Bump `upstream/rhel-coreos-config` or `SCOS_USE_LOCKFILE=0` |
| Credential providers copied as binaries | Not tracked by RPM | ISA-checked; disable with `WITH_CRED_PROVIDERS=0` if unused (bare metal) |
| `openshift-install` keeps its embedded SCOS 10 stream | IPI on clouds/vSphere downloads SCOS 10 images | Override the OS image in `install-config.yaml` (docs/install.md) |
| Release is not signed | `oc adm upgrade` needs `--allow-explicit-upgrade --force` | Expected for self-built payloads |
| Upstream may move more images to EL10 in later 4.22.z | Pods crash on v2 | `make verify-payload` on the upstream release before bumping |
| OKD 5.x | Every image is EL10 | Out of scope for this approach |
