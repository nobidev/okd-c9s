#!/bin/bash
# Overlay the upstream payload components that ship the coreos-bootimages
# ConfigMap (BOOTIMAGES_COMPONENTS: installer, installer-artifacts and, in
# 4.20, installer-altinfra) with one that points at SCOS 9 boot images. The
# release payload's openshift-machine-config-operator/coreos-bootimages
# ConfigMap is taken from these images' /manifests.
#
# The openshift-install binary itself is unchanged: its built-in stream
# metadata (used by IPI to download cloud images) still refers to SCOS 10.
# See docs/install.md for how to point installs at SCOS 9 boot images.
source "$(dirname "$0")/lib.sh"

"${ROOT_DIR}/scripts/fetch-bootimages.sh"
ctx="${WORK_DIR}/ctx/installer"
rm -rf "${ctx}"
mkdir -p "${ctx}"
cp "${ROOT_DIR}/images/installer/Containerfile" "${ctx}/"
python3 -I "${ROOT_DIR}/scripts/gen-bootimages-cm.py" "${BOOTIMAGE_DIR}/stream.json" \
    > "${ctx}/coreos-bootimages.yaml"

for component in ${BOOTIMAGES_COMPONENTS}; do
    target="$(component_image "${component}")"
    if have_local_image_labeled "${target}" "${BOOTIMAGE_LABEL}" "${SCOS9_BOOTIMAGE_BUILD}"; then
        log "${target} already built (FORCE=1 to rebuild)"
        continue
    fi
    upstream="$(upstream_image_for "${component}")"
    log "building ${target} from ${upstream}"
    "${PODMAN}" build "${ctx}" --build-arg "UPSTREAM_IMAGE=${upstream}" \
        --label "${BOOTIMAGE_LABEL}=${SCOS9_BOOTIMAGE_BUILD}" -t "${target}"
done
