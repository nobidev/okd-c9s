#!/bin/bash
# Check that the patches of every given OKD minor apply to its submodules.
# usage: check-patches.sh MINOR [MINOR...]
set -euo pipefail

tmp="$(mktemp -d)"
cleanup() { rm -rf -- "${tmp:?}"; }
trap cleanup EXIT

for minor in "$@"; do
    (
        export OKD_MINOR="${minor}" BUILD_DIR="${tmp}/${minor}"
        # shellcheck source=scripts/lib.sh
        source "$(dirname "$0")/lib.sh"
        for component in rhel-coreos-config os driver-toolkit machine-os-images; do
            prepare_src "${component}"
        done
        log "OKD ${OKD_MINOR} (${OKD_VERSION}): sources prepared"
    )
done
