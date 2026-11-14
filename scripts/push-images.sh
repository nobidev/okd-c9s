#!/bin/bash
# Push the rebuilt component images and record their digests in
# build/digests.env (consumed by build-release.sh).
source "$(dirname "$0")/lib.sh"

digests="${BUILD_DIR}/digests.env"
mkdir -p "${BUILD_DIR}"
: > "${digests}.tmp"
push() {
    local var="$1" image="$2" df
    "${PODMAN}" image exists "${image}" || die "${image} not built"
    df="$(mktemp)"
    log "push ${image}"
    "${PODMAN}" push --retry 3 --digestfile "${df}" "${image}"
    echo "${var}=${image%:*}@$(cat "${df}")" >> "${digests}.tmp"
    rm -f "${df}"
}
push BASE_REF "${BASE_IMAGE}"
push NODE_REF "${NODE_IMAGE}"
push EXTENSIONS_REF "${EXTENSIONS_IMAGE}"
push DTK_REF "${DTK_IMAGE}"
push MOS_REF "${MOS_IMAGE}"
push INSTALLER_REF "${INSTALLER_IMAGE}"
push INSTALLER_ARTIFACTS_REF "${INSTALLER_ARTIFACTS_IMAGE}"
mv "${digests}.tmp" "${digests}"
cat "${digests}"
