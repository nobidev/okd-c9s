#!/bin/bash
# Check that new nodes booted from this minor's SCOS 9 boot image can fetch
# their config, on this minor and on every release it is upgraded from.
#
# A node's first boot runs the Ignition of the boot image (on bare metal the
# machine-os-images live ISO, installed by install_coreos). It requests
# /config/<pool> from the machine-config-server with
#   Accept: application/vnd.coreos.ignition+json;version=X.Y.Z, */*;q=0.1
# and an MCS that cannot serve X.Y.Z answers 400 (OKD 4.20/4.21 do so for
# 3.6.0), leaving the node in the emergency shell. This script:
#  1. checks that every artifact of SCOS9_BOOTIMAGE_BUILD is downloadable,
#  2. reads the build's ignition version and takes the exact Accept header
#     from coreos/ignition at that tag (internal/resource/url.go),
#  3. runs the real machine-config-server of UPSTREAM_RELEASE_IMAGE and of each
#     UPGRADE_FROM_RELEASES entry (+ EXTRA_MCS_RELEASES) in bootstrap mode and
#     requires HTTP 200 with an Ignition config for that header.
#
# usage: OKD_MINOR=4.20 scripts/check-bootimage.sh     (make check-bootimages)
source "$(dirname "$0")/lib.sh"

REQUIRED_IMAGES=(live-iso live-kernel live-initramfs live-rootfs metal metal4k qemu)
url="${SCOS9_BOOTIMAGE_BASEURL}/${SCOS9_BOOTIMAGE_BUILD}/x86_64"
mkdir -p "${WORK_DIR}"
work="$(mktemp -d "${WORK_DIR}/check-bootimage.XXXXXX")"
containers=()
cleanup() {
    local c
    for c in "${containers[@]}"; do "${PODMAN}" rm -f "${c}" >/dev/null 2>&1 || true; done
    rm -rf -- "${work:?}"
}
trap cleanup EXIT

fetch() { curl -fsSL --retry 5 --retry-all-errors "$@"; }

# --- 1. artifacts -----------------------------------------------------------
log "OKD ${OKD_MINOR}: boot image ${SCOS9_BOOTIMAGE_BUILD}"
fetch "${url}/meta.json" -o "${work}/meta.json" || die "cannot fetch ${url}/meta.json"
fetch "${url}/commitmeta.json" -o "${work}/commitmeta.json" || die "cannot fetch ${url}/commitmeta.json"
missing=0
for image in "${REQUIRED_IMAGES[@]}"; do
    path="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("images", {}).get(sys.argv[2], {}).get("path", ""))' \
        "${work}/meta.json" "${image}")" || die "cannot parse ${url}/meta.json"
    if [[ -z "${path}" ]]; then
        echo "  missing  ${image} (not in meta.json)"; missing=1; continue
    fi
    # Ranged GET: the mirror answers 206/200 for present files, 403 otherwise.
    if fetch -r 0-0 -o /dev/null "${url}/${path}"; then
        echo "  ok       ${image}  ${path}"
    else
        echo "  missing  ${image}  ${url}/${path}"; missing=1
    fi
done
[[ "${missing}" == 0 ]] || die "boot image ${SCOS9_BOOTIMAGE_BUILD} lacks downloadable artifacts"

# --- 2. Ignition and the Accept header it sends ------------------------------
ign_version="$(python3 -c 'import json,sys; print(next(p[2] for p in json.load(open(sys.argv[1]))["rpmostree.rpmdb.pkglist"] if p[0] == "ignition"))' \
    "${work}/commitmeta.json")" || die "no ignition package in ${url}/commitmeta.json"
git -C "${work}" init -q ignition
git -C "${work}/ignition" fetch -q --depth 1 https://github.com/coreos/ignition "refs/tags/v${ign_version}" \
    || die "cannot fetch coreos/ignition tag v${ign_version}"
accept="$(git -C "${work}/ignition" show FETCH_HEAD:internal/resource/url.go \
    | { grep -oE 'application/vnd\.coreos\.ignition\+json;version=[0-9]+\.[0-9]+\.[0-9]+, \*/\*;q=0\.1' || true; } | head -1)"
[[ -n "${accept}" ]] || die "no Accept literal in coreos/ignition v${ign_version} internal/resource/url.go; review the check"
log "ignition ${ign_version} sends: Accept: ${accept}"

# --- 3. probe each relevant machine-config-server -----------------------------
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=okd-c9s-mcs-check \
    -keyout "${work}/tls.key" -out "${work}/tls.crt" >/dev/null 2>&1 || die "openssl failed"
chmod 0644 "${work}/tls.key"
fixtures="${ROOT_DIR}/tests/mcs-bootstrap"
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

read -r -a releases <<< "${UPSTREAM_RELEASE_IMAGE} ${UPGRADE_FROM_RELEASES:-} ${EXTRA_MCS_RELEASES:-}"
failed=0
for release in "${releases[@]}"; do
    mco="$(oc_cmd adm release info --image-for=machine-config-operator "${release}")" \
        || die "cannot resolve machine-config-operator of ${release}"
    "${PODMAN}" pull -q "${mco}" >/dev/null || "${PODMAN}" pull -q "${mco}" >/dev/null \
        || die "cannot pull ${mco}"
    secure="$(free_port)"; insecure="$(free_port)"
    name="okd-c9s-mcs-check-$$-${insecure}"
    # No --rm: if the MCS exits early its logs must still be readable below.
    "${PODMAN}" run -d --name "${name}" --net=host \
        -v "${fixtures}:/ft:ro,z" -v "${work}:/tls:ro,z" \
        --entrypoint /usr/bin/machine-config-server "${mco}" \
        bootstrap --server-basedir /ft/bs --bootstrap-kubeconfig /ft/kubeconfig \
        --cert /tls/tls.crt --key /tls/tls.key \
        --secure-port "${secure}" --insecure-port "${insecure}" >/dev/null \
        || die "cannot start the machine-config-server of ${release}"
    containers+=("${name}")
    code=000
    for _ in $(seq 1 60); do
        code="$(curl -s --noproxy '*' -o "${work}/body" -w '%{http_code}' -H "Accept: ${accept}" \
            "http://127.0.0.1:${insecure}/config/master" || true)"
        [[ "${code}" != 000 ]] && break
        [[ "$("${PODMAN}" container inspect -f '{{.State.Running}}' "${name}" 2>/dev/null)" == true ]] || break
        sleep 1
    done
    served="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ignition"]["version"])' \
        "${work}/body" 2>/dev/null || echo -)"
    if [[ "${code}" == 200 && "${served}" != - ]]; then
        printf '  ok    %-48s HTTP %s, serves spec %s\n' "${release}" "${code}" "${served}"
    else
        printf '  FAIL  %-48s HTTP %s\n' "${release}" "${code}"
        "${PODMAN}" logs --tail 15 "${name}" 2>&1 | sed 's/^/          /'
        failed=1
    fi
    "${PODMAN}" rm -f "${name}" >/dev/null 2>&1 || true
done

[[ "${failed}" == 0 ]] || die "OKD ${OKD_MINOR}: boot image ${SCOS9_BOOTIMAGE_BUILD} (ignition ${ign_version}) cannot fetch configs from every MCS above; pin an older build in versions/${OKD_MINOR}.env"
log "OKD ${OKD_MINOR}: boot image ${SCOS9_BOOTIMAGE_BUILD} (ignition ${ign_version}) is served by all ${#releases[@]} MCS"
