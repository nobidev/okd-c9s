#!/bin/bash
# Build the RHCOS/SCOS extensions repo image ("stream-coreos-extensions":
# kernel-rt, usbguard, ipsec, kata, ...) matching the c9s node image.
source "$(dirname "$0")/lib.sh"

if have_local_image "${EXTENSIONS_IMAGE}"; then
    log "${EXTENSIONS_IMAGE} already built (FORCE=1 to rebuild)"
    exit 0
fi
"${PODMAN}" image exists "${NODE_IMAGE}" || die "run 'make node' first"

[[ -d "${SRC_DIR}/os" ]] || prepare_src os
src="${SRC_DIR}/os"
containerfile="${src}/extensions/Containerfile"
[[ -f "${containerfile}" ]] || containerfile="${src}/extensions/Dockerfile"   # <= 4.21
mkdir -p "${WORK_DIR}"
empty_repo="${WORK_DIR}/empty.repo"
: > "${empty_repo}"

log "building ${EXTENSIONS_IMAGE}"
# --from replaces the first stage's base (an ARG in 4.22, a CI-only image
# before), i.e. the c9s node image whose package set the extensions match.
"${PODMAN}" build "${src}" -f "${containerfile}" \
    --from "${NODE_IMAGE}" \
    --build-arg "IMAGE_FROM=${NODE_IMAGE}" \
    --build-arg "STREAM_CLASS=${STREAM_CLASS}" \
    --secret "id=yumrepos,src=${empty_repo}" \
    --security-opt label=disable \
    -t "${EXTENSIONS_IMAGE}"
