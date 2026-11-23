# okd-c9s

Rebuild of [OKD](https://okd.io) 4.20, 4.21 and 4.22 that runs on **x86-64-v2**
CPUs (Intel Nehalem…Broadwell-era Xeons without AVX2, older AMD Opterons, many
Atom/Celeron parts, VMs with a conservative CPU model, …).

Since 4.20 the OKD node OS is SCOS 10 (CentOS Stream 10), which is compiled for
**x86-64-v3**. On a v2 CPU every EL10 program dies immediately with
`Fatal glibc error: CPU does not support x86-64-v3`. This repository swaps
the EL10 pieces of an upstream OKD release for CentOS Stream 9 (x86-64-v2)
builds and publishes a new release payload — enough to keep an OKD 4.19
cluster on old hardware upgrading through 4.20 → 4.21 → 4.22
([docs/upgrade.md](docs/upgrade.md)).

The repository contains only **submodules, patches and build files**.

| Minor | Upstream release | Rebuilt release (`ghcr.io/nobidev/okd-c9s/release:…`) |
|---|---|---|
| 4.20 | `quay.io/okd/scos-release:4.20.0-okd-scos.17` | `4.20.0-okd-scos.17-c9s.1` |
| 4.21 | `quay.io/okd/scos-release:4.21.0-okd-scos.11` | `4.21.0-okd-scos.11-c9s.1` |
| 4.22 | `quay.io/okd/scos-release:4.22.0-okd-scos.10` | `4.22.0-okd-scos.10-c9s.1` |

Node OS for all three: SCOS 9 (CentOS Stream CoreOS 9, kernel 5.14.0-763.el9).
Boot image for all three: SCOS 9 `9.0.20260324-0` (Ignition 2.25.1, requests
config spec 3.5.0, see below). The earlier `-c9s` releases shipped
`9.0.20261110-0`, whose Ignition 2.28 requests spec 3.6.0, which the 4.20/4.21
machine-config-server rejects: new nodes could not join. Use `-c9s.1`.
Settings: [`versions/`](versions).

## What gets rebuilt

Scans of every image in the three upstream releases (194 / 188 / 191 images)
show that all but a handful are already built on CentOS Stream 9. Only these
depend on EL10 or embed EL10 artifacts:

| Payload component | Upstream | Rebuilt from |
|---|---|---|
| `stream-coreos` (node OS) | SCOS 10 | `upstream/rhel-coreos-config` (c9s variant) + `upstream/<minor>/os` + `patches/<minor>/os` |
| `stream-coreos-extensions` | c10s RPMs | `upstream/<minor>/os` `extensions/centos-9.yaml` |
| `driver-toolkit` | c10s kernel-devel | `upstream/<minor>/driver-toolkit` on CentOS Stream 9, node kernel |
| `machine-os-images` | SCOS 10 live ISO | SCOS 9 live ISO + `upstream/<minor>/machine-os-images` scripts |
| `installer`, `installer-artifacts` (+ `installer-altinfra` in 4.20) | SCOS 10 `coreos-bootimages` | thin overlay with SCOS 9 boot images |

Everything else is reused from the upstream release by digest. See
[docs/design.md](docs/design.md) for the reasoning, sources and trade-offs.

## Layout

```
upstream/                     pinned submodules (never modified in place)
  rhel-coreos-config/         coreos/rhel-coreos-config (SCOS 9 base, shared)
  <minor>/os/                 openshift/os release-<minor> (OKD node layer)
  <minor>/driver-toolkit/     openshift/driver-toolkit release-<minor>
  <minor>/machine-os-images/  openshift/machine-os-images release-<minor>
patches/<minor>/<submodule>/  git patches applied to a copy in build/src/<minor>/
rpms/okd-el9-<minor>.lock     pinned el9 node RPMs (cri-o, kubelet, oc, ...) + sha256
versions/common.env           settings shared by all minors
versions/<minor>.env          upstream release, cli image, RPM repo, ... per minor
images/                       Containerfiles for public-base replacements / overlays
scripts/                      build, verification and release tooling
.github/workflows/            CI: lint on PRs, build matrix + verify + publish
```

## Building

Requirements: Linux x86_64, podman ≥ 5 running as root (the SCOS base build
needs `--cap-add=all --device /dev/fuse`), `make`, `git`, `python3`,
`createrepo_c` (optional, a container is used otherwise),
`qemu-user-static` (for the execution test), ~60 GB of disk.
The build host itself may be an x86-64-v2 machine.

```bash
git clone --recurse-submodules https://github.com/nobidev/okd-c9s
cd okd-c9s
make help
make minors                          # 4.20 4.21 4.22
make info OKD_MINOR=4.20             # resolved image names

podman login ghcr.io                 # or set REGISTRY=... to push elsewhere
export OKD_MINOR=4.20
make images                          # base, node, extensions, dtk, machine-os-images, installer
make verify                          # ISA scan + run binaries on an emulated Nehalem CPU
make push release                    # push components, assemble the release payload
make verify-payload                  # no payload image may still be EL10
```

Useful knobs (environment or `make VAR=value`):

| Variable | Default | Meaning |
|---|---|---|
| `OKD_MINOR` | `4.22` | which `versions/<minor>.env` to build |
| `REGISTRY` | `ghcr.io/nobidev/okd-c9s` | where images are pushed |
| `SCOS_USE_LOCKFILE` | `1` | `0` builds the SCOS 9 base from the newest c9s packages instead of the rhel-coreos-config lockfile (needed once the c9s mirror drops the locked kernel) |
| `WITH_CRED_PROVIDERS` | `1` | copy the ECR/ACR/GCR(/CRI-O) kubelet credential providers from the upstream node image |
| `FORCE` | `0` | rebuild images that already exist locally |
| `QEMU_CPU` | `Nehalem` | CPU model emulated by `make verify` |

### CI

`.github/workflows/build.yml`:

* pull requests: `make check` (shellcheck, python syntax, patches of every minor apply)
  and `make check-bootimages` (each minor's boot image against the real
  machine-config-servers it will meet);
* pushes to `main`: build + `make verify` for every minor in parallel; no release
  images are published, only the `el9-rpms` bundles (see below);
* `workflow_dispatch` (choose a minor or `all`, tick *publish*) or a `v*` tag:
  also `make push release verify-payload` to `ghcr.io/<owner>/okd-c9s`.

GHCR packages are private when first created. Make them public (package
settings) or add a pull secret for `ghcr.io` to the cluster.

### Locked el9 RPMs (`el9-rpms` bundles)

cri-o, kubelet and oc come from the `<minor>-el9-beta` mirror, which deletes
superseded builds, so a lock file stops being buildable after a while. Every
non-PR CI build therefore stores the locked set (best effort, before building) as
`${REGISTRY}/el9-rpms:<minor>-<first 16 hex of the lock file's sha256>` (a
`FROM scratch` image holding `/rpms/*.rpm` and `/okd-el9.lock`; skipped if the
tag already exists). `make rpms-bundle` does the same by hand. Builds restore
the RPMs from that image first and only fall back to the mirror for what is
missing; every file is still checked against the sha256 in the lock file.
Local builds need pull access to the `el9-rpms` package (public, or
`podman login ghcr.io`); without it they log the miss and use the mirror.
`RPM_BUNDLE_IMAGE` overrides the full image reference (keep one tag per minor
and lock file). A bundle pushed by hand to GHCR first is linked to this
repository through its `org.opencontainers.image.source` label; if CI cannot
write to it, grant the repository access in the package's settings.

## Using the releases

* Upgrading an existing OKD 4.19 cluster: `./upgrade.py 4.22 --dry-run`, then
  `./upgrade.py 4.22` (one minor at a time, with checks and etcd backups);
  details and the manual procedure in [docs/upgrade.md](docs/upgrade.md).
* New installs: [docs/install.md](docs/install.md).

## Updating to newer upstream releases

1. Edit `versions/<minor>.env`: `OKD_VERSION`, `UPSTREAM_RELEASE_IMAGE` and
   `OC_IMAGE` (the release's `cli` image).
2. `make print-upstream-commits OKD_MINOR=<minor>` and move
   `upstream/<minor>/{os,driver-toolkit,machine-os-images}` to those commits.
   Move `upstream/rhel-coreos-config` forward as needed (node OS base).
   If `OKD_VERSION` changed within the minor, add the previous upstream release
   to `UPGRADE_FROM_RELEASES` in the same file.
3. Boot image: `SCOS9_BOOTIMAGE_BUILD` is set per minor in `versions/<minor>.env`.
   Its Ignition must request a config spec that the minor's machine-config-server,
   and that of every release in `UPGRADE_FROM_RELEASES`, can serve:
   `make check-bootimages` (needs network + podman; also a CI gate) runs those
   servers and fails otherwise. 4.20/4.21 stay on Ignition <= 2.25.x boot images
   (spec 3.5.0) unless `patches/contingency/machine-config-operator` is adopted.
4. `make rpms-lock OKD_MINOR=<minor>` (re-pins cri-o/kubelet/oc to the newest el9 builds),
   then `make rpms-bundle OKD_MINOR=<minor>` (or let the next CI build do it) to
   store the new set in GHCR before the mirror deletes it.
5. `make check` and `make check-bootimages`, rebase `patches/<minor>/` if needed, then build.
6. Run `make verify-payload RELEASE_IMAGE=<upstream release>` first: if upstream
   moved more images to EL10, they must be added to the rebuild list.

A new minor needs `versions/<minor>.env`, `rpms/okd-el9-<minor>.lock`, the three
`upstream/<minor>/` submodules, `patches/<minor>/os` and a CI matrix entry.
OKD 5.x builds every image on CentOS Stream 10 and is out of scope.
