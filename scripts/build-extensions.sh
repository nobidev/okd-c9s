#!/bin/bash
# Build the RHCOS/SCOS extensions repo image ("stream-coreos-extensions":
# kernel-rt, usbguard, ipsec, kata, ...) matching the c9s node image.
source "$(dirname "$0")/lib.sh"

if have_local_image "${EXTENSIONS_IMAGE}"; then
    log "${EXTENSIONS_IMAGE} already built (FORCE=1 to rebuild)"
    exit 0
fi
"${PODMAN}" image exists "${NODE_IMAGE}" || die "run 'make node' first"

[[ -d "${BUILD_DIR}/src/os" ]] || prepare_src os
src="${BUILD_DIR}/src/os"
empty_repo="${BUILD_DIR}/empty.repo"
: > "${empty_repo}"

log "building ${EXTENSIONS_IMAGE}"
"${PODMAN}" build "${src}" -f "${src}/extensions/Containerfile" \
    --build-arg "IMAGE_FROM=${NODE_IMAGE}" \
    --build-arg "STREAM_CLASS=${STREAM_CLASS}" \
    --secret "id=yumrepos,src=${empty_repo}" \
    --security-opt label=disable \
    -t "${EXTENSIONS_IMAGE}"
