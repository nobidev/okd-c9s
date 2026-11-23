# Contingency: machine-config-server fallback for newer Ignition specs

**Not applied by any build.** Kept so the fix can be adopted quickly if a 4.20
or 4.21 boot image newer than Ignition 2.25.x is ever required.

The OKD 4.20 (MCO `8af0c84e`) and 4.21 (`1a0b9eee`) machine-config-server
answer HTTP 400 to `Accept: application/vnd.coreos.ignition+json;version=3.6.0`
(sent by Ignition 2.26 and later). OKD 4.22 (`90b26966`) contains upstream
MCO-2182 (`9a0ff4208`, 4.21 backport `c24449d90`): for a newer minor of the
same major it serves its newest spec (3.5.0) instead. The patches here
backport that behaviour, with a unit test, to the 4.20/4.21 commits used by
okd-c9s; both apply cleanly (`git apply --check`).

Today okd-c9s avoids the problem by pinning boot images whose Ignition
requests spec 3.5.0 (`SCOS9_BOOTIMAGE_BUILD` in `versions/<minor>.env`,
enforced by `make check-bootimages`). Prefer that while it is possible: this
contingency means rebuilding a control-plane binary with a non-Red Hat Go
toolchain (non-FIPS) and re-overlaying the MCO image on every `OKD_VERSION`
bump.

## Recipe (validated once, by hand)

```bash
git clone https://github.com/openshift/machine-config-operator src
git -C src checkout 8af0c84e6fcc34c60768b3955366a78a440b7a85      # 4.20
git -C src apply ../4.20-0001-mcs-newer-ignition-minor.patch
podman build -f Containerfile . \
  --build-arg UPSTREAM_IMAGE="$(oc adm release info --image-for=machine-config-operator quay.io/okd/scos-release:4.20.0-okd-scos.17)" \
  --build-arg VERSION_OVERRIDE=4.20.0-okd-scos.17 \
  --build-arg SOURCE_GIT_COMMIT=8af0c84e6fcc34c60768b3955366a78a440b7a85 \
  -t <registry>/machine-config-operator:<release>
```

`Containerfile` overlays only `/usr/bin/machine-config-server` on the upstream
MCO image (built with `TAGS=scos`, `GOAMD64=v2`, tests in `pkg/server` run
first). Adopting it takes two releases:

1. Ship a release whose payload carries the patched MCO (add
   `machine-config-operator` to the replaced components and the release
   mappings) while keeping the current boot image pin.
2. Only in a later release, raise `SCOS9_BOOTIMAGE_BUILD`. Clusters upgrade
   from step 1, so their MCS already has the fallback when the new ISO arrives
   (metal3 is updated before the MCO during an upgrade).

`make check-bootimages` probes the *upstream* MCO of `UPSTREAM_RELEASE_IMAGE`
and `UPGRADE_FROM_RELEASES`, so it would still reject the newer boot image:
teach it to probe the patched MCO image instead (and list the step-1 release,
not the upstream one, as the upgrade source) before step 2.
