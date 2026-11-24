#!/bin/bash
# Thorough check of every image referenced by a release payload: stream all
# layers and flag x86-64 ELF objects that need more than x86-64-v2 (the same
# rules as check-isa.py). Complements verify-payload.sh, which only reads image
# labels, and verify-image.sh, which also executes binaries but only covers the
# images rebuilt here. Nothing is written to disk; expect ~20 GB of downloads.
#
# usage: verify-payload-isa.sh [RELEASE_IMAGE]   (default: the rebuilt release)
source "$(dirname "$0")/lib.sh"

release="${1:-${RELEASE_IMAGE}}"
mkdir -p "${WORK_DIR}"
list="${WORK_DIR}/payload-$(echo "${release}" | tr '/:@' '___').txt"
release_pullspecs "${release}" "${list}"
log "ISA scan of all $(wc -l < "${list}") images of ${release}"
auth=()
[[ -f "${AUTH_FILE}" ]] && auth=(--auth "${AUTH_FILE}")
python3 -I "${ROOT_DIR}/scripts/check-payload-isa.py" "${auth[@]}" \
    --jobs "${ISA_SCAN_JOBS:-4}" "${list}" \
    || die "payload ISA scan of ${release} failed (see above)"
