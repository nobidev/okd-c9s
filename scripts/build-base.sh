#!/bin/bash
# Build the SCOS 9 (CentOS Stream 9) base bootable container from
# coreos/rhel-coreos-config. Everything in it targets the x86-64-v2 baseline.
source "$(dirname "$0")/lib.sh"

if have_local_image "${BASE_IMAGE}"; then
    log "${BASE_IMAGE} already built (FORCE=1 to rebuild)"
    exit 0
fi

prepare_src rhel-coreos-config
src="${SRC_DIR}/rhel-coreos-config"
upstream_args="${src}/build-args-${SCOS_VARIANT}.conf"
[[ -f "${upstream_args}" ]] || die "$(basename "${upstream_args}") not found in rhel-coreos-config"

# The CoreOS pipeline always overrides VERSION (default "9.0") with a build ID
# such as 9.0.20261110-0. It ends up in os-release (OSTREE_VERSION) and in the
# io.openshift.build.versions=machine-os=<VERSION> label, which
# `oc adm release new` requires to be a full semantic version.
[[ "${SCOS_BUILD_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] \
    || die "SCOS_BUILD_VERSION=${SCOS_BUILD_VERSION} is not a semantic version"
mkdir -p "${WORK_DIR}"
args_file="${WORK_DIR}/build-args-base.conf"
grep -v '^VERSION=' "${upstream_args}" > "${args_file}"
echo "VERSION=${SCOS_BUILD_VERSION}" >> "${args_file}"

if [[ "${SCOS_USE_LOCKFILE}" != 1 ]]; then
    # CentOS Stream mirrors only keep a few builds of each package (notably the
    # kernel). Without the lockfile the newest available packages are used.
    log "SCOS_USE_LOCKFILE=${SCOS_USE_LOCKFILE}: building without the ${SCOS_VARIANT} lockfile"
    rm -f "${src}/lockfiles/${SCOS_VARIANT}/manifest-lock.x86_64.json"
fi

log "building ${BASE_IMAGE} (SCOS ${SCOS_BUILD_VERSION})"
# Invocation documented in fedora-coreos-config/Containerfile.
(
    cd "${src}"
    "${PODMAN}" build \
        --security-opt=label=disable --cap-add=all --device /dev/fuse \
        --build-arg-file "${args_file}" \
        -v "${src}:/run/src" \
        --label "org.opencontainers.image.source=https://github.com/coreos/rhel-coreos-config" \
        --label "org.opencontainers.image.revision=$(git -C "${ROOT_DIR}/upstream/rhel-coreos-config" rev-parse HEAD)" \
        -t "${BASE_IMAGE}" .
)
