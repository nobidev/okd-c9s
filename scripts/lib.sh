# shellcheck shell=bash
# Variables defined here are consumed by the scripts that source this file.
# shellcheck disable=SC2034
# Common helpers sourced by every build script.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-${ROOT_DIR}/build}"

# Load versions/common.env and versions/<OKD_MINOR>.env without letting them
# override values exported by the caller (so `REGISTRY=... make node` works).
load_env() {
    local key value
    while IFS='=' read -r key value; do
        [[ -z "${key}" || "${key}" == \#* ]] && continue
        if [[ -z "${!key:-}" ]]; then
            printf -v "${key}" '%s' "${value}"
            export "${key?}"
        fi
    done < "$1"
}
load_env "${ROOT_DIR}/versions/common.env"
OKD_MINOR="${OKD_MINOR:-${DEFAULT_OKD_MINOR}}"
export OKD_MINOR
[[ -f "${ROOT_DIR}/versions/${OKD_MINOR}.env" ]] \
    || { echo "error: unsupported OKD_MINOR=${OKD_MINOR} (no versions/${OKD_MINOR}.env)" >&2; exit 1; }
load_env "${ROOT_DIR}/versions/${OKD_MINOR}.env"

PODMAN="${PODMAN:-podman}"
SCOS_USE_LOCKFILE="${SCOS_USE_LOCKFILE:-1}"
# Build ID of the SCOS 9 base image (machine-os version), CoreOS style.
SCOS_BUILD_VERSION="${SCOS_BUILD_VERSION:-9.0.$(date -u +%Y%m%d)-0}"
WITH_CRED_PROVIDERS="${WITH_CRED_PROVIDERS:-1}"

# Per-minor locations
SRC_DIR="${BUILD_DIR}/src/${OKD_MINOR}"
WORK_DIR="${BUILD_DIR}/${OKD_MINOR}"
RPM_LOCK="${ROOT_DIR}/rpms/okd-el9-${OKD_MINOR}.lock"

RELEASE_NAME="${RELEASE_NAME:-${OKD_VERSION}-${RELEASE_SUFFIX}}"
RCC_COMMIT="$(git -C "${ROOT_DIR}/upstream/rhel-coreos-config" rev-parse --short=10 HEAD 2>/dev/null || echo unknown)"

# Payload components replaced by this repository. Each is published as
# ${REGISTRY}/<component>:${OKD_VERSION}.
read -r -a REPLACED_COMPONENTS <<< "stream-coreos stream-coreos-extensions driver-toolkit machine-os-images ${BOOTIMAGES_COMPONENTS}"
component_image() { echo "${REGISTRY}/$1:${OKD_VERSION}"; }

# Images built here are pushed under the same tags they are built with. When
# a build stage (or `podman run`) names such an image by tag, podman may pull
# the previously *published* one and silently replace the fresh local build —
# observed in CI even with --pull=missing. Locally built images are therefore
# always referenced by image ID (local_image_id), which cannot be pulled, and
# builds use --pull=missing so only external bases (centos, ubi, ...) are
# fetched.
PULL_LOCAL=(--pull=missing)

# ID of a locally built image (fails if it is not in local storage).
local_image_id() {
    "${PODMAN}" image inspect --format '{{.Id}}' "$1" 2>/dev/null \
        || die "image $1 is not in local storage"
}

# Image references produced by this repository.
BASE_IMAGE="${BASE_IMAGE:-${REGISTRY}/scos-base:9-${RCC_COMMIT}}"
NODE_IMAGE="${NODE_IMAGE:-$(component_image stream-coreos)}"
EXTENSIONS_IMAGE="${EXTENSIONS_IMAGE:-$(component_image stream-coreos-extensions)}"
DTK_BASE_IMAGE="${DTK_BASE_IMAGE:-${REGISTRY}/c9s-dtk-base:latest}"
DTK_IMAGE="${DTK_IMAGE:-$(component_image driver-toolkit)}"
MOS_IMAGE="${MOS_IMAGE:-$(component_image machine-os-images)}"
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
    local cache="${WORK_DIR}/upstream-images.txt"
    mkdir -p "${WORK_DIR}"
    if [[ ! -s "${cache}" ]]; then
        oc_cmd adm release info --pullspecs -o json "${UPSTREAM_RELEASE_IMAGE}" \
            | python3 -c 'import json,sys; [print(t["name"], t["from"]["name"]) for t in json.load(sys.stdin)["references"]["spec"]["tags"]]' \
            > "${cache}.tmp"
        mv "${cache}.tmp" "${cache}"
    fi
    awk -v n="${name}" '$1 == n { print $2; found=1 } END { exit !found }' "${cache}" \
        || die "component ${name} not found in ${UPSTREAM_RELEASE_IMAGE}"
}

# Copy a submodule to ${SRC_DIR}/<name> and apply its patches. Submodules stay
# pristine; all modifications happen in the copy.
#   rhel-coreos-config -> upstream/rhel-coreos-config, patches/rhel-coreos-config
#   anything else      -> upstream/<minor>/<name>,      patches/<minor>/<name>
prepare_src() {
    local name="$1" rel
    if [[ "${name}" == rhel-coreos-config ]]; then rel="${name}"; else rel="${OKD_MINOR}/${name}"; fi
    local src="${ROOT_DIR}/upstream/${rel}"
    local dst="${SRC_DIR}/${name}"
    [[ -e "${src}/.git" ]] || die "submodule upstream/${rel} is not initialised (run: git submodule update --init --recursive)"
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
    for p in "${ROOT_DIR}/patches/${rel}"/*.patch; do
        log "  applying $(basename "${p}")"
        git -C "${dst}" apply -p1 --whitespace=nowarn "${p}" \
            || die "patch $(basename "${p}") does not apply to upstream/${rel}"
    done
    shopt -u nullglob
    rm -rf "${dst}/.git"
}

# rpm-ostree postprocess scripts (e.g. `semanage boolean`) rename directories
# that live in lower image layers (/etc/selinux/targeted/active). Kernel
# overlayfs only allows that with redirect_dir enabled; otherwise rename(2)
# fails with EXDEV and libsemanage aborts. containers/storage detects the
# setting and switches to its naive layer diff, so enabling it is safe.
# patches/<minor>/os also copies the SELinux store into the build layer, which is
# what actually fixes libsemanage; this is a best-effort extra.
ensure_overlay_redirect_dir() {
    local param=/sys/module/overlay/parameters/redirect_dir
    [[ -f "${param}" ]] || return 0
    case "$(cat "${param}")" in
        Y|y|on|follow) return 0 ;;
    esac
    log "enabling overlayfs redirect_dir (${param})"
    if ! echo Y > "${param}" 2>/dev/null; then
        log "warning: cannot enable overlayfs redirect_dir; relying on the SELinux store copy in patches/${OKD_MINOR}/os"
    fi
}

# Fail early when the image already exists locally and FORCE is not set.
have_local_image() {
    [[ "${FORCE:-0}" != 1 ]] && "${PODMAN}" image exists "$1"
}

# Commit of a per-minor submodule, for image labels.
upstream_commit() {
    git -C "${ROOT_DIR}/upstream/${OKD_MINOR}/$1" rev-parse HEAD
}
