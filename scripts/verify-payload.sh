#!/bin/bash
# Cheap check of every image referenced by a release payload: flag images
# whose labels say they are built on CentOS Stream 10 / SCOS 10 (and would
# therefore need x86-64-v3). Only image configs are fetched, no layers.
#
# usage: verify-payload.sh [RELEASE_IMAGE]   (default: the rebuilt release)
source "$(dirname "$0")/lib.sh"

release="${1:-${RELEASE_IMAGE}}"
list="${BUILD_DIR}/payload-$(echo "${release}" | tr '/:@' '___').txt"
oc_cmd adm release info --pullspecs -o json "${release}" \
    | python3 -c 'import json,sys; [print(t["name"], t["from"]["name"]) for t in json.load(sys.stdin)["references"]["spec"]["tags"]]' \
    > "${list}"
log "checking $(wc -l < "${list}") images of ${release}"

bad=0
while read -r name ref; do
    labels="$(oc_cmd image info --filter-by-os=linux/amd64 -o json "${ref}" \
        | python3 -c 'import json,sys; l=json.load(sys.stdin)["config"]["config"].get("Labels") or {}; print(" ".join(f"{k}={v}" for k,v in l.items() if k in ("org.label-schema.name","release","com.coreos.stream","io.openshift.build.version-display-names")))')"
    if grep -qE 'Stream 10|scos10|stream=c10s|CoreOS 10' <<<"${labels}"; then
        printf 'EL10  %-40s %s\n' "${name}" "${labels}"
        bad=1
    fi
done < "${list}"
[[ "${bad}" == 0 ]] || die "payload still contains EL10 (x86-64-v3) images"
log "no EL10 images in ${release}"
