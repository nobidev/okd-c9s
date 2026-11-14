#!/bin/bash
# Assemble the release payload: the upstream OKD release with the EL10
# components (REPLACED_COMPONENTS) swapped for the c9s rebuilds. Every other
# image is reused by digest; those are already built on CentOS Stream 9.
source "$(dirname "$0")/lib.sh"

digests="${WORK_DIR}/digests.env"
[[ -s "${digests}" ]] || die "missing ${digests}; run 'make push' first"

mappings=()
for component in "${REPLACED_COMPONENTS[@]}"; do
    ref="$(awk -F= -v c="${component}" '$1 == c { print $2 }' "${digests}")"
    [[ -n "${ref}" ]] || die "no digest for ${component} in ${digests}"
    mappings+=("${component}=${ref}")
done

# The release image is a layer on top of cluster-version-operator. `oc` finds
# that image through the upstream release's base-image-digest label, which
# fails when the upstream release is a manifest list (4.20): the label holds
# the per-arch digest while the payload references manifest-list digests.
# Name the base explicitly; it is the image `oc` would otherwise pick.
base_image="$(upstream_image_for cluster-version-operator)"

log "creating ${RELEASE_IMAGE} (${RELEASE_NAME}) from ${UPSTREAM_RELEASE_IMAGE}"
printf '  %s\n' "base: ${base_image}" "${mappings[@]}" >&2
oc_cmd adm release new \
    --from-release="${UPSTREAM_RELEASE_IMAGE}" \
    --to-image-base="${base_image}" \
    --to-image="${RELEASE_IMAGE}" \
    --name="${RELEASE_NAME}" \
    "${mappings[@]}"

oc_cmd adm release info "${RELEASE_IMAGE}" | head -20
digest="$(oc_cmd image info -o json "${RELEASE_IMAGE}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["digest"])')"
printf 'RELEASE_IMAGE=%s\nRELEASE_DIGEST_REF=%s@%s\n' "${RELEASE_IMAGE}" "${RELEASE_IMAGE%:*}" "${digest}" \
    | tee "${WORK_DIR}/release.env"
log "release image: ${RELEASE_IMAGE%:*}@${digest}"
