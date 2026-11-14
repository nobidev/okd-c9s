#!/bin/bash
# Push the rebuilt images and record their digests in
# build/<minor>/digests.env (consumed by build-release.sh).
source "$(dirname "$0")/lib.sh"

digests="${WORK_DIR}/digests.env"
mkdir -p "${WORK_DIR}"
: > "${digests}.tmp"
push() {
    local key="$1" image="$2" df
    "${PODMAN}" image exists "${image}" || die "${image} not built"
    df="$(mktemp)"
    log "push ${image}"
    "${PODMAN}" push --retry 3 --digestfile "${df}" "${image}"
    echo "${key}=${image%:*}@$(cat "${df}")" >> "${digests}.tmp"
    rm -f "${df}"
}
push scos-base "${BASE_IMAGE}"
for component in "${REPLACED_COMPONENTS[@]}"; do
    push "${component}" "$(component_image "${component}")"
done
mv "${digests}.tmp" "${digests}"
cat "${digests}"
