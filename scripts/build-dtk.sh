#!/bin/bash
# Build driver-toolkit for the kernel shipped in the c9s node image.
source "$(dirname "$0")/lib.sh"

if have_local_image "${DTK_IMAGE}"; then
    log "${DTK_IMAGE} already built (FORCE=1 to rebuild)"
    exit 0
fi
"${PODMAN}" image exists "${NODE_IMAGE}" || die "run 'make node' first"

kernel="$("${PODMAN}" run --rm --entrypoint rpm "${NODE_IMAGE}" -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}' kernel-core)"
log "node kernel: ${kernel}"

log "building ${DTK_BASE_IMAGE}"
"${PODMAN}" build "${ROOT_DIR}/images/dtk-base" \
    --build-arg "BASE_IMAGE=${C9S_BASE_IMAGE}" -t "${DTK_BASE_IMAGE}"

prepare_src driver-toolkit
log "building ${DTK_IMAGE}"
# --from replaces the CI-only registry.ci.openshift.org/ocp/<ver>:base-rhel9.
# TAGS=scos rewrites the manifests to reference stream-coreos.
"${PODMAN}" build "${SRC_DIR}/driver-toolkit" \
    --from "${DTK_BASE_IMAGE}" \
    --build-arg "KERNEL_VERSION=${kernel}" \
    --build-arg "RT_KERNEL_VERSION=${kernel}" \
    --build-arg "TAGS=scos" \
    --label "io.openshift.build.commit.id=$(upstream_commit driver-toolkit)" \
    -t "${DTK_IMAGE}"
