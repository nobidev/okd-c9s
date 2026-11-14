#!/bin/bash
# Verify that a container image runs on x86-64-v2 hardware:
#  1. static scan of every ELF object (scripts/check-isa.py)
#  2. execute a set of key binaries under qemu-user emulating an Intel
#     Nehalem CPU (x86-64-v2, no AVX/AVX2/BMI/FMA). A CentOS Stream 10 binary
#     fails there with "Fatal glibc error: CPU does not support x86-64-v3".
#
# usage: verify-image.sh IMAGE [IMAGE...]
source "$(dirname "$0")/lib.sh"

QEMU_CPU="${QEMU_CPU:-Nehalem}"
qemu="$(command -v qemu-x86_64-static || true)"

# Commands executed (when present) inside the image rootfs.
SMOKE_CMDS=(
    "/usr/bin/bash -c true"
    "/usr/bin/python3 -c pass"
    "/usr/lib/systemd/systemd --version"
    "/usr/bin/rpm -q glibc"
    "/usr/bin/rpm-ostree --version"
    "/usr/bin/bootc --version"
    "/usr/bin/kubelet --version"
    "/usr/bin/crio --version"
    "/usr/bin/crictl --version"
    "/usr/bin/conmonrs --version"
    "/usr/bin/crun --version"
    "/usr/bin/runc --version"
    "/usr/bin/oc version --client"
    "/usr/sbin/ovs-vswitchd --version"
    "/usr/bin/coreos-installer --version"
    "/usr/bin/podman --version"
    "/usr/bin/nmstatectl --version"
    "/usr/libexec/kubelet-image-credential-provider-plugins/ecr-credential-provider --help"
)

verify_one() {
    local image="$1" rootfs ctr rc=0
    rootfs="$(mktemp -d "${BUILD_DIR}/verify.XXXXXX")"
    log "verify ${image}"
    ctr="$("${PODMAN}" create "${NO_PULL[@]}" --entrypoint /bin/true "${image}")"
    "${PODMAN}" export "${ctr}" | tar -x -C "${rootfs}" --exclude='dev/*' 2>/dev/null || true
    "${PODMAN}" rm -f "${ctr}" >/dev/null

    python3 -I "${ROOT_DIR}/scripts/check-isa.py" "${rootfs}" || rc=1

    if [[ -z "${qemu}" ]]; then
        log "qemu-x86_64-static not found; skipping execution test"
    else
        cp "${qemu}" "${rootfs}/.qemu-x86_64"
        local cmd bin out
        for cmd in "${SMOKE_CMDS[@]}"; do
            bin="${cmd%% *}"
            [[ -x "${rootfs}${bin}" ]] || continue
            # shellcheck disable=SC2086
            if out="$(chroot "${rootfs}" /.qemu-x86_64 -cpu "${QEMU_CPU}" ${cmd} 2>&1 </dev/null)"; then
                printf '  ok    [%s] %s\n' "${QEMU_CPU}" "${cmd}"
            else
                # Only treat ISA failures as fatal; other errors (missing /proc,
                # no D-Bus, ...) are expected inside a bare chroot.
                if grep -qiE 'x86-64-v[34]|ISA level|v3 microarchitecture|v4 microarchitecture|Illegal instruction|SIGILL' <<<"${out}"; then
                    printf '  FAIL  [%s] %s\n%s\n' "${QEMU_CPU}" "${cmd}" "$(grep -v 'TCG doesn' <<<"${out}" | head -5)"
                    rc=1
                else
                    printf '  warn  [%s] %s (non-ISA error: %s)\n' "${QEMU_CPU}" "${cmd}" \
                        "$(grep -v 'TCG doesn' <<<"${out}" | head -1)"
                fi
            fi
        done
    fi
    rm -rf "${rootfs}"
    return "${rc}"
}

[[ $# -gt 0 ]] || die "usage: $0 IMAGE [IMAGE...]"
failed=0
for image in "$@"; do
    verify_one "${image}" || failed=1
done
if [[ "${failed}" != 0 ]]; then
    die "x86-64-v2 verification failed"
fi
log "all images verified for x86-64-v2"
