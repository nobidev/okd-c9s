#!/bin/bash
# Download the locked el9 OpenShift node RPMs and turn them into a local repo
# inside the openshift/os build context (build/src/<minor>/os/okd-el9-rpms).
source "$(dirname "$0")/lib.sh"

lock="${RPM_LOCK}"
cache="${BUILD_DIR}/cache/okd-el9-rpms-${OKD_MINOR}"
repo="${SRC_DIR}/os/okd-el9-rpms"
[[ -d "${SRC_DIR}/os" ]] || die "run prepare_src os first"

log "fetching RPMs from ${lock}"
python3 -I "${ROOT_DIR}/scripts/rpms-lock.py" fetch "${lock}" "${cache}"
rm -rf "${repo}"
mkdir -p "${repo}"
cp -a "${cache}"/*.rpm "${repo}/"

if command -v createrepo_c >/dev/null 2>&1; then
    createrepo_c -q "${repo}"
else
    "${PODMAN}" run --rm --security-opt label=disable -v "${repo}:/repo" "${C9S_BASE_IMAGE}" \
        bash -c 'dnf -q -y install createrepo_c >/dev/null && createrepo_c -q /repo'
fi

# Injected through the `yumrepos` build secret (mounted in /etc/yum.repos.d).
# The packages are integrity-checked against the sha256 in the lock file, the
# Red Hat signing key is not part of CentOS Stream, hence gpgcheck=0.
mkdir -p "${WORK_DIR}"
cat > "${WORK_DIR}/okd-el9.repo" <<REPO
[okd-el9-local]
name=OpenShift ${OKD_MINOR} el9 node RPMs (locked, local)
baseurl=file:///run/src/okd-el9-rpms
enabled=1
gpgcheck=0
REPO
log "local repo ready: ${repo}"
