# okd-c9s

Rebuild of [OKD](https://okd.io) 4.20+ that runs on **x86-64-v2** CPUs
(Intel Nehalem…Broadwell-era Xeons without AVX2, older AMD Opterons, many
Atom/Celeron parts, VMs with a conservative CPU model, …).

Since 4.20 the OKD node OS is SCOS 10 (CentOS Stream 10), which is compiled for
**x86-64-v3**. On a v2 CPU every EL10 program dies immediately with
`Fatal glibc error: CPU does not support x86-64-v3`. This repository swaps
the EL10 pieces of an upstream OKD release for CentOS Stream 9 (x86-64-v2)
builds and publishes a new release payload.

The repository contains only **submodules, patches and build files**.

| Item | Value |
|------|-------|
| Upstream release | `quay.io/okd/scos-release:4.22.0-okd-scos.10` |
| Rebuilt release | `ghcr.io/nobidev/okd-c9s/release:4.22.0-okd-scos.10-c9s` |
| Node OS | SCOS 9 (CentOS Stream CoreOS 9), kernel 5.14.0-763.el9 |
| Settings | [`versions.env`](versions.env) |

## What gets rebuilt

A scan of all 191 images in `4.22.0-okd-scos.10` showed that 188 are already
built on CentOS Stream 9; only these depend on EL10 (or embed EL10 artifacts):

| Payload component | Upstream | Rebuilt from |
|---|---|---|
| `stream-coreos` (node OS) | SCOS 10 | `upstream/rhel-coreos-config` (c9s variant) + `upstream/os` + [`patches/os`](patches/os) |
| `stream-coreos-extensions` | c10s RPMs | `upstream/os` `extensions/centos-9.yaml` |
| `driver-toolkit` | c10s kernel-devel | `upstream/driver-toolkit` on CentOS Stream 9, node kernel |
| `machine-os-images` | SCOS 10 live ISO | SCOS 9 live ISO + `upstream/machine-os-images` scripts |
| `installer`, `installer-artifacts` | SCOS 10 `coreos-bootimages` | thin overlay with SCOS 9 boot images |

Everything else is reused from the upstream release by digest. See
[docs/design.md](docs/design.md) for the reasoning, sources and trade-offs.

## Layout

```
upstream/                 pinned submodules (never modified in place)
  rhel-coreos-config/     coreos/rhel-coreos-config  (SCOS base, c9s variant)
  os/                     openshift/os release-4.22  (OKD node layer)
  driver-toolkit/         openshift/driver-toolkit release-4.22
  machine-os-images/      openshift/machine-os-images release-4.22
patches/<submodule>/      git patches applied to a copy in build/src/<submodule>
rpms/okd-el9.lock         pinned el9 node RPMs (cri-o, kubelet, oc, ...) + sha256
images/                   Containerfiles for public-base replacements / overlays
scripts/                  build, verification and release tooling
versions.env              every version / image / URL in one place
.github/workflows/        CI: lint on PRs, build + verify + publish
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
make info                       # resolved image names

podman login ghcr.io            # or set REGISTRY=... to push elsewhere
make images                     # base, node, extensions, dtk, machine-os-images, installer
make verify                     # ISA scan + run binaries on an emulated Nehalem CPU
make push release               # push components, assemble the release payload
make verify-payload             # no payload image may still be EL10
```

Useful knobs (environment or `make VAR=value`):

| Variable | Default | Meaning |
|---|---|---|
| `REGISTRY` | `ghcr.io/nobidev/okd-c9s` | where images are pushed |
| `SCOS_USE_LOCKFILE` | `1` | `0` builds the SCOS 9 base from the newest c9s packages instead of the rhel-coreos-config lockfile (needed once the c9s mirror drops the locked kernel) |
| `WITH_CRED_PROVIDERS` | `1` | copy the ECR/ACR/GCR/CRI-O kubelet credential providers from the upstream node image |
| `FORCE` | `0` | rebuild images that already exist locally |
| `QEMU_CPU` | `Nehalem` | CPU model emulated by `make verify` |

### CI

`.github/workflows/build.yml`:

* pull requests: `make check` (shellcheck, python syntax, patches apply);
* pushes to `main`: full build + `make verify`, nothing is published;
* `workflow_dispatch` with *publish* or a `v*` tag: also `make push release verify-payload`
  to `ghcr.io/<owner>/okd-c9s`.

GHCR packages are private when first created. Make them public (package
settings) or add a pull secret for `ghcr.io` to the cluster's install config.

## Installing a cluster

See [docs/install.md](docs/install.md). In short: extract `openshift-install`
from the rebuilt release, and boot nodes from the SCOS 9 ISO/PXE artifacts
listed by `build/bootimages/stream.json`.

## Updating to a newer OKD release

1. Set `OKD_VERSION` / `UPSTREAM_RELEASE_IMAGE` (and `OC_IMAGE`) in `versions.env`.
2. `make print-upstream-commits` and move `upstream/os`, `upstream/driver-toolkit`,
   `upstream/machine-os-images` to those commits; move `upstream/rhel-coreos-config`
   to the commit of the newest SCOS 9 boot image build and set `SCOS9_BOOTIMAGE_BUILD`.
3. `make rpms-lock` (re-pins cri-o/kubelet/oc to the newest el9 builds).
4. `make check`, rebase `patches/` if needed, then build.
5. `make verify-payload RELEASE_IMAGE=<upstream release>` first: if upstream has moved
   more images to EL10, they must be added to the rebuild list.
