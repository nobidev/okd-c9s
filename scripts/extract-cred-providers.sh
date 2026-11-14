#!/bin/bash
# Copy the kubelet image credential provider plugins (ECR/ACR/GCR/CRI-O) out of
# the upstream OKD node image into an overlay rootfs for the c9s node build.
#
# These are el9 builds from OpenShift ART (GOAMD64=v2, dynamically linked
# against the el9 glibc), but they are not published as RPMs outside of
# OpenShift CI. The copied binaries are ISA-checked before use.
source "$(dirname "$0")/lib.sh"

dest="${1:?usage: $0 <overlay-rootfs-dir>}"
plugin_dir=/usr/libexec/kubelet-image-credential-provider-plugins
cache="${BUILD_DIR}/cache/cred-providers-${OKD_MINOR}"

if [[ ! -d "${cache}${plugin_dir}" ]] || [[ -z "$(ls -A "${cache}${plugin_dir}" 2>/dev/null)" ]]; then
    upstream_node="$(upstream_image_for stream-coreos)"
    log "extracting ${plugin_dir} from ${upstream_node}"
    rm -rf "${cache}"
    mkdir -p "${cache}${plugin_dir}"
    oc_cmd image extract "${upstream_node}" --confirm \
        --path "${plugin_dir}/:${cache}${plugin_dir}"
fi
[[ -n "$(ls -A "${cache}${plugin_dir}")" ]] || die "no credential providers extracted"
chmod 0755 "${cache}${plugin_dir}"/*

python3 -I "${ROOT_DIR}/scripts/check-isa.py" "${cache}" \
    || die "upstream credential providers require more than x86-64-v2; rerun with WITH_CRED_PROVIDERS=0"

mkdir -p "${dest}${plugin_dir}"
cp -a "${cache}${plugin_dir}/." "${dest}${plugin_dir}/"
log "credential providers: $(find "${dest}${plugin_dir}" -mindepth 1 -printf "%f ")"
