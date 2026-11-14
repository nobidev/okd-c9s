# shellcheck shell=bash
# Common helpers sourced by every build script.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${ROOT_DIR}/build}"

# Load versions.env without letting it override values exported by the caller
# (so `REGISTRY=... make node` works).
while IFS='=' read -r key value; do
    [[ -z "${key}" || "${key}" == \#* ]] && continue
    if [[ -z "${!key:-}" ]]; then
        printf -v "${key}" '%s' "${value}"
        export "${key?}"
    fi
done < "${ROOT_DIR}/versions.env"

PODMAN="${PODMAN:-podman}"
SCOS_USE_LOCKFILE="${SCOS_USE_LOCKFILE:-1}"
WITH_CRED_PROVIDERS="${WITH_CRED_PROVIDERS:-1}"

RELEASE_NAME="${RELEASE_NAME:-${OKD_VERSION}-${RELEASE_SUFFIX}}"
RCC_COMMIT="$(git -C "${ROOT_DIR}/upstream/rhel-coreos-config" rev-parse --short=10 HEAD 2>/dev/null || echo unknown)"

# Image references produced by this repository.
BASE_IMAGE="${BASE_IMAGE:-${REGISTRY}/scos-base:9-${RCC_COMMIT}}"
NODE_IMAGE="${NODE_IMAGE:-${REGISTRY}/stream-coreos:${OKD_VERSION}}"
EXTENSIONS_IMAGE="${EXTENSIONS_IMAGE:-${REGISTRY}/stream-coreos-extensions:${OKD_VERSION}}"
DTK_BASE_IMAGE="${DTK_BASE_IMAGE:-${REGISTRY}/c9s-dtk-base:${OKD_VERSION}}"
DTK_IMAGE="${DTK_IMAGE:-${REGISTRY}/driver-toolkit:${OKD_VERSION}}"
MOS_IMAGE="${MOS_IMAGE:-${REGISTRY}/machine-os-images:${OKD_VERSION}}"
INSTALLER_IMAGE="${INSTALLER_IMAGE:-${REGISTRY}/installer:${OKD_VERSION}}"
INSTALLER_ARTIFACTS_IMAGE="${INSTALLER_ARTIFACTS_IMAGE:-${REGISTRY}/installer-artifacts:${OKD_VERSION}}"
RELEASE_IMAGE="${RELEASE_IMAGE:-${REGISTRY}/release:${RELEASE_NAME}}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# Registry credentials shared by podman, skopeo and oc.
if [[ -n "${REGISTRY_AUTH_FILE:-}" ]]; then
    AUTH_FILE="${REGISTRY_AUTH_FILE}"
elif [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    AUTH_FILE="${XDG_RUNTIME_DIR}/containers/auth.json"
else
    # podman's default for root without a user session
    AUTH_FILE="/run/containers/$(id -u)/auth.json"
fi

# Run `oc`, preferring a host binary and falling back to the pinned cli image
# (CentOS Stream 9 based, so it also runs on x86-64-v2 build hosts).
# Registry credentials are always passed explicitly.
oc_cmd() {
    if command -v oc >/dev/null 2>&1; then
        if [[ -f "${AUTH_FILE}" ]]; then
            oc "$@" --registry-config="${AUTH_FILE}"
        else
            oc "$@"
        fi
        return
    fi
    local extra=() oc_args=()
    if [[ -f "${AUTH_FILE}" ]]; then
        extra=(-v "${AUTH_FILE}:/run/okd-auth.json:ro")
        oc_args=(--registry-config=/run/okd-auth.json)
    fi
    mkdir -p "${BUILD_DIR}"
    "${PODMAN}" run --rm --net=host --security-opt label=disable \
        -v "${BUILD_DIR}:${BUILD_DIR}" -w "${BUILD_DIR}" "${extra[@]}" \
        "${OC_IMAGE}" oc "$@" "${oc_args[@]}"
}

# Pull spec of a component in the upstream release payload.
upstream_image_for() {
    local name="$1"
    local cache="${BUILD_DIR}/upstream-images.txt"
    mkdir -p "${BUILD_DIR}"
    if [[ ! -s "${cache}" ]]; then
        oc_cmd adm release info --pullspecs -o json "${UPSTREAM_RELEASE_IMAGE}" \
            | python3 -c 'import json,sys; [print(t["name"], t["from"]["name"]) for t in json.load(sys.stdin)["references"]["spec"]["tags"]]' \
            > "${cache}.tmp"
        mv "${cache}.tmp" "${cache}"
    fi
    awk -v n="${name}" '$1 == n { print $2; found=1 } END { exit !found }' "${cache}" \
        || die "component ${name} not found in ${UPSTREAM_RELEASE_IMAGE}"
}

# Copy upstream/<name> to build/src/<name> and apply patches/<name>/*.patch.
# Submodules stay pristine; all modifications happen in the copy.
prepare_src() {
    local name="$1"
    local src="${ROOT_DIR}/upstream/${name}"
    local dst="${BUILD_DIR}/src/${name}"
    [[ -e "${src}/.git" ]] || die "submodule upstream/${name} is not initialised (run: git submodule update --init --recursive)"
    log "preparing ${dst}"
    rm -rf "${dst}"
    mkdir -p "$(dirname "${dst}")"
    cp -a "${src}" "${dst}"
    find "${dst}" -name .git -prune -exec rm -rf {} +
    # build/ lives inside this repository's work tree, where `git apply` would
    # resolve paths against the top-level repo; use a throwaway repo instead.
    git -C "${dst}" init -q
    local p
    shopt -s nullglob
    for p in "${ROOT_DIR}/patches/${name}"/*.patch; do
        log "  applying $(basename "${p}")"
        git -C "${dst}" apply -p1 --whitespace=nowarn "${p}" \
            || die "patch $(basename "${p}") does not apply to upstream/${name}"
    done
    shopt -u nullglob
    rm -rf "${dst}/.git"
}

# rpm-ostree postprocess scripts (e.g. `semanage boolean`) rename directories
# that live in lower image layers (/etc/selinux/targeted/active). Kernel
# overlayfs only allows that with redirect_dir enabled; otherwise rename(2)
# fails with EXDEV and libsemanage aborts. containers/storage detects the
# setting and switches to its naive layer diff, so enabling it is safe.
ensure_overlay_redirect_dir() {
    local param=/sys/module/overlay/parameters/redirect_dir
    [[ -f "${param}" ]] || return 0
    case "$(cat "${param}")" in
        Y|y|on|follow) return 0 ;;
    esac
    log "enabling overlayfs redirect_dir (${param})"
    if ! echo Y > "${param}" 2>/dev/null; then
        die "overlayfs redirect_dir is disabled and cannot be enabled from here; run as root on the host: echo Y > ${param}"
    fi
}

# Fail early when the image already exists locally and FORCE is not set.
have_local_image() {
    [[ "${FORCE:-0}" != 1 ]] && "${PODMAN}" image exists "$1"
}
