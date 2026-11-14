#!/bin/bash
# Build the OKD node image (payload component "stream-coreos") on top of the
# SCOS 9 base image, using openshift/os + patches/os.
source "$(dirname "$0")/lib.sh"

if have_local_image "${NODE_IMAGE}"; then
    log "${NODE_IMAGE} already built (FORCE=1 to rebuild)"
    exit 0
fi
"${PODMAN}" image exists "${BASE_IMAGE}" || "${PODMAN}" pull "${BASE_IMAGE}" \
    || die "base image ${BASE_IMAGE} not available; run 'make base' first"

prepare_src os
src="${BUILD_DIR}/src/os"
"${ROOT_DIR}/scripts/fetch-rpms.sh"

if [[ "${WITH_CRED_PROVIDERS}" == 1 ]]; then
    "${ROOT_DIR}/scripts/extract-cred-providers.sh" "${src}/extra-rootfs"
fi

args_file="${BUILD_DIR}/build-args-node.conf"
sed -e "s|^IMAGE_FROM=.*|IMAGE_FROM=${BASE_IMAGE}|" \
    -e "s|^STREAM_CLASS=.*|STREAM_CLASS=${STREAM_CLASS}|" \
    "${src}/build-args-${OKD_MINOR}-c9s.conf" > "${args_file}"

log "building ${NODE_IMAGE}"
# Invocation documented in openshift/os docs/building.md.
"${PODMAN}" build "${src}" \
    --build-arg-file "${args_file}" \
    --secret "id=yumrepos,src=${BUILD_DIR}/okd-el9.repo" \
    --security-opt label=disable \
    --label "org.opencontainers.image.source=https://github.com/openshift/os" \
    --label "io.openshift.build.commit.id=$(git -C "${ROOT_DIR}/upstream/os" rev-parse HEAD)" \
    -t "${NODE_IMAGE}"
