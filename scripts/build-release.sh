#!/bin/bash
# Assemble the release payload: the upstream OKD release with the EL10
# components replaced by the c9s rebuilds. Everything else (188 of 191
# images in 4.22.0-okd-scos.10) is reused by digest: those images are
# already built on CentOS Stream 9.
source "$(dirname "$0")/lib.sh"

digests="${BUILD_DIR}/digests.env"
[[ -s "${digests}" ]] || die "missing ${digests}; run 'make push' first"
# shellcheck disable=SC1090
source "${digests}"

log "creating ${RELEASE_IMAGE} (${RELEASE_NAME}) from ${UPSTREAM_RELEASE_IMAGE}"
oc_cmd adm release new \
    --from-release="${UPSTREAM_RELEASE_IMAGE}" \
    --to-image="${RELEASE_IMAGE}" \
    --name="${RELEASE_NAME}" \
    "stream-coreos=${NODE_REF}" \
    "stream-coreos-extensions=${EXTENSIONS_REF}" \
    "driver-toolkit=${DTK_REF}" \
    "machine-os-images=${MOS_REF}" \
    "installer=${INSTALLER_REF}" \
    "installer-artifacts=${INSTALLER_ARTIFACTS_REF}"

oc_cmd adm release info "${RELEASE_IMAGE}" | head -20
log "release image: ${RELEASE_IMAGE}"
