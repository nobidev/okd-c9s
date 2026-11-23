#!/bin/bash
# Store the locked el9 node RPMs of OKD_MINOR as an image, RPM_BUNDLE_IMAGE
# (${REGISTRY}/el9-rpms:<minor>-<sha256(lock)[:16]>): FROM scratch with
# /rpms/*.rpm and /okd-el9.lock. The upstream mirror deletes superseded builds;
# fetch-rpms.sh restores from this image, so a lock keeps building after that.
# The tag is derived from the lock file; an already published tag is left as is.
source "$(dirname "$0")/lib.sh"

[[ -f "${RPM_LOCK}" ]] || die "no lock file ${RPM_LOCK} (make rpms-lock)"

# Cheap check without downloading the bundle. Only skopeo can do it:
# `podman manifest inspect` rejects single-image OCI manifests.
if command -v skopeo >/dev/null 2>&1; then
    skopeo_args=()
    read -r -a skopeo_args <<< "${SKOPEO_ARGS:-}"   # e.g. --tls-verify=false for a local test registry
    if skopeo inspect --raw "${skopeo_args[@]}" "docker://${RPM_BUNDLE_IMAGE}" >/dev/null 2>&1; then
        log "${RPM_BUNDLE_IMAGE} already published"
        exit 0
    fi
fi
# Otherwise (or if skopeo failed for another reason than a missing tag) try to
# pull it (never a local copy, which may never have been pushed): success
# means it is published, and also refills the local cache.
if restore_rpm_bundle --pull=always; then
    log "${RPM_BUNDLE_IMAGE} already published"
    exit 0
fi

# Not published: build it from a complete, verified set (cache, then mirror).
python3 -I "${ROOT_DIR}/scripts/rpms-lock.py" fetch "${RPM_LOCK}" "${RPM_CACHE_DIR}"

ctx="${WORK_DIR}/ctx/rpm-bundle"
rm -rf -- "${ctx:?}"
mkdir -p "${ctx}/rpms"
cp -a "${RPM_CACHE_DIR}"/*.rpm "${ctx}/rpms/"
cp "${RPM_LOCK}" "${ctx}/okd-el9.lock"
cat > "${ctx}/Containerfile" <<'CF'
FROM scratch
COPY okd-el9.lock /okd-el9.lock
COPY rpms/ /rpms/
CF

labels=(--label "io.okd-c9s.rpms.minor=${OKD_MINOR}"
        --label "io.okd-c9s.rpms.lock-sha256=$(sha256sum "${RPM_LOCK}" | cut -d' ' -f1)")
# GHCR links a new package to the repository named here, which gives the
# repository's workflow token access to it.
if [[ "${REGISTRY}" == ghcr.io/*/* ]]; then
    repo="${REGISTRY#ghcr.io/}"
    labels+=(--label "org.opencontainers.image.source=https://github.com/${repo%%/*}/$(cut -d/ -f2 <<< "${repo}")")
fi
log "building ${RPM_BUNDLE_IMAGE} ($(find "${ctx}/rpms" -name '*.rpm' | wc -l) RPMs)"
"${PODMAN}" build "${ctx}" -f "${ctx}/Containerfile" "${labels[@]}" -t "${RPM_BUNDLE_IMAGE}"
log "push ${RPM_BUNDLE_IMAGE}"
"${PODMAN}" push --retry 3 "${RPM_BUNDLE_IMAGE}" 2>/dev/null || "${PODMAN}" push "${RPM_BUNDLE_IMAGE}"
