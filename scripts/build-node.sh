#!/bin/bash
# Build the OKD node image (payload component "stream-coreos") on top of the
# SCOS 9 base image, using upstream/<minor>/os + patches/<minor>/os.
source "$(dirname "$0")/lib.sh"

if have_local_image "${NODE_IMAGE}"; then
    log "${NODE_IMAGE} already built (FORCE=1 to rebuild)"
    exit 0
fi
"${PODMAN}" image exists "${BASE_IMAGE}" || "${PODMAN}" pull "${BASE_IMAGE}" \
    || die "base image ${BASE_IMAGE} not available; run 'make base' first"

prepare_src os
src="${SRC_DIR}/os"
"${ROOT_DIR}/scripts/fetch-rpms.sh"

if [[ "${WITH_CRED_PROVIDERS}" == 1 ]]; then
    "${ROOT_DIR}/scripts/extract-cred-providers.sh" "${src}/extra-rootfs"
fi

# 4.22+ Containerfiles take the base via a build-args file (added for c9s by
# patches/4.22/os); older ones hard-code FROM. --from covers both.
build_args=(--from "${BASE_IMAGE}")
if [[ -f "${src}/build-args-${OKD_MINOR}-c9s.conf" ]]; then
    args_file="${WORK_DIR}/build-args-node.conf"
    sed -e "s|^IMAGE_FROM=.*|IMAGE_FROM=${BASE_IMAGE}|" \
        -e "s|^STREAM_CLASS=.*|STREAM_CLASS=${STREAM_CLASS}|" \
        "${src}/build-args-${OKD_MINOR}-c9s.conf" > "${args_file}"
    build_args+=(--build-arg-file "${args_file}")
fi

ensure_overlay_redirect_dir
log "building ${NODE_IMAGE}"
# Invocation documented in openshift/os docs/building.md.
"${PODMAN}" build "${src}" \
    "${build_args[@]}" \
    --secret "id=yumrepos,src=${WORK_DIR}/okd-el9.repo" \
    --security-opt label=disable \
    --label "org.opencontainers.image.source=https://github.com/openshift/os" \
    --label "io.openshift.build.commit.id=$(upstream_commit os)" \
    -t "${NODE_IMAGE}"
