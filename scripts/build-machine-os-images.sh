#!/bin/bash
# Rebuild payload component "machine-os-images" (base ISO used by the agent
# installer, `oc adm node-image` and metal3) with the SCOS 9 live ISO.
source "$(dirname "$0")/lib.sh"

if have_local_image_labeled "${MOS_IMAGE}" "${BOOTIMAGE_LABEL}" "${SCOS9_BOOTIMAGE_BUILD}"; then
    log "${MOS_IMAGE} already built with SCOS ${SCOS9_BOOTIMAGE_BUILD} (FORCE=1 to rebuild)"
    exit 0
fi

"${ROOT_DIR}/scripts/fetch-bootimages.sh" --iso

ctx="${WORK_DIR}/ctx/machine-os-images"
rm -rf "${ctx}"
mkdir -p "${ctx}/coreos" "${ctx}/bin" "${ctx}/bin-extra"
cp "${ROOT_DIR}/images/machine-os-images/Containerfile" "${ctx}/"
ln "${BOOTIMAGE_DIR}/coreos-x86_64.iso" "${ctx}/coreos/coreos-x86_64.iso" 2>/dev/null \
    || cp "${BOOTIMAGE_DIR}/coreos-x86_64.iso" "${ctx}/coreos/"
cp "${BOOTIMAGE_DIR}/coreos-x86_64.iso.sha256" "${ctx}/coreos/"
cp "${BOOTIMAGE_DIR}/stream.json" "${ctx}/coreos/coreos-stream.json"
cp "${ROOT_DIR}/upstream/${OKD_MINOR}/machine-os-images/scripts/"* "${ctx}/bin/"

# coreos-installer is not shipped in CentOS Stream 9; reuse the el9 binary
# from the upstream image (ISA-checked below).
upstream_mos="$(upstream_image_for machine-os-images)"
log "extracting coreos-installer from ${upstream_mos}"
oc_cmd image extract "${upstream_mos}" --confirm --path "/usr/bin/coreos-installer:${ctx}/bin-extra"
chmod 0755 "${ctx}/bin-extra/coreos-installer"
python3 -I "${ROOT_DIR}/scripts/check-isa.py" "${ctx}/bin-extra" || die "coreos-installer is not x86-64-v2 compatible"

log "building ${MOS_IMAGE}"
"${PODMAN}" build "${ctx}" \
    --build-arg "BASE_IMAGE=${C9S_BASE_IMAGE}" \
    --build-arg "OC_IMAGE=${OC_IMAGE}" \
    --label "io.openshift.build.commit.id=$(upstream_commit machine-os-images)" \
    --label "${BOOTIMAGE_LABEL}=${SCOS9_BOOTIMAGE_BUILD}" \
    -t "${MOS_IMAGE}"
