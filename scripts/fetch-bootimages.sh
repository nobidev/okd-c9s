#!/bin/bash
# Produce SCOS 9 stream metadata (build/bootimages/<build>/stream.json) for
# SCOS9_BOOTIMAGE_BUILD and, with --iso, download + verify its live ISO.
source "$(dirname "$0")/lib.sh"

out="${BOOTIMAGE_DIR}"
url="${SCOS9_BOOTIMAGE_BASEURL}/${SCOS9_BOOTIMAGE_BUILD}/x86_64"
mkdir -p "${out}"

if [[ ! -s "${out}/meta-${SCOS9_BOOTIMAGE_BUILD}.json" ]]; then
    log "fetching ${url}/meta.json"
    curl -fsSL --retry 5 "${url}/meta.json" -o "${out}/meta.tmp"
    mv "${out}/meta.tmp" "${out}/meta-${SCOS9_BOOTIMAGE_BUILD}.json"
fi
python3 -I "${ROOT_DIR}/scripts/gen-stream-json.py" \
    --meta "${out}/meta-${SCOS9_BOOTIMAGE_BUILD}.json" --base-url "${url}" --stream c9s \
    > "${out}/stream.json"
log "stream metadata: ${out}/stream.json"

if [[ "${1:-}" == --iso ]]; then
    iso_url="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["architectures"]["x86_64"]["artifacts"]["metal"]["formats"]["iso"]["disk"]["location"])' "${out}/stream.json")"
    iso_sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["architectures"]["x86_64"]["artifacts"]["metal"]["formats"]["iso"]["disk"]["sha256"])' "${out}/stream.json")"
    iso="${out}/coreos-x86_64.iso"
    if [[ -f "${iso}" ]] && echo "${iso_sha}  ${iso}" | sha256sum -c --status; then
        log "ISO cached: ${iso}"
    else
        log "downloading ${iso_url}"
        curl -fSL --retry 5 -o "${iso}.part" "${iso_url}"
        echo "${iso_sha}  ${iso}.part" | sha256sum -c --status || die "ISO checksum mismatch"
        mv "${iso}.part" "${iso}"
    fi
    printf '%s' "${iso_sha}" > "${iso}.sha256"
fi
