# okd-c9s: rebuild OKD for x86-64-v2 (pre-Haswell) CPUs.
#
# All settings live in versions.env; any of them can be overridden on the
# command line or in the environment, e.g. `make node REGISTRY=quay.io/me/okd`.
# Build targets need podman with privileges (see README.md / CI workflow).

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# Settings that the scripts honour when set in the environment.
export REGISTRY OKD_VERSION UPSTREAM_RELEASE_IMAGE RELEASE_SUFFIX RELEASE_NAME \
       OC_IMAGE PODMAN BUILD_DIR FORCE SCOS_USE_LOCKFILE WITH_CRED_PROVIDERS \
       REGISTRY_AUTH_FILE QEMU_CPU

S := scripts

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: submodules
submodules: ## Initialise the pinned upstream submodules
	git submodule update --init --recursive

.PHONY: info
info: ## Print the resolved image names
	@source $(S)/lib.sh; for v in OKD_VERSION RELEASE_NAME UPSTREAM_RELEASE_IMAGE BASE_IMAGE NODE_IMAGE \
	  EXTENSIONS_IMAGE DTK_IMAGE MOS_IMAGE INSTALLER_IMAGE INSTALLER_ARTIFACTS_IMAGE RELEASE_IMAGE; do \
	  printf '%-26s %s\n' "$$v" "$${!v}"; done

# ---------------------------------------------------------------------------
# Images
# ---------------------------------------------------------------------------
.PHONY: bootimages base node extensions dtk machine-os-images installer images
bootimages: ## SCOS 9 boot image stream metadata -> build/bootimages/stream.json
	$(S)/fetch-bootimages.sh
base: ## SCOS 9 base bootable container (coreos/rhel-coreos-config, c9s)
	$(S)/build-base.sh
node: base ## OKD node image "stream-coreos" (openshift/os + patches/os)
	$(S)/build-node.sh
extensions: node ## "stream-coreos-extensions" (kernel-rt, usbguard, kata, ...)
	$(S)/build-extensions.sh
dtk: node ## "driver-toolkit" matching the node kernel
	$(S)/build-dtk.sh
machine-os-images: ## "machine-os-images" carrying the SCOS 9 live ISO
	$(S)/build-machine-os-images.sh
installer: ## "installer"/"installer-artifacts" with SCOS 9 coreos-bootimages
	$(S)/build-installer.sh
images: node extensions dtk machine-os-images installer ## Build every replaced component

# ---------------------------------------------------------------------------
# Verification / publishing
# ---------------------------------------------------------------------------
.PHONY: verify push release verify-payload
verify: ## ISA scan + qemu (Nehalem) execution test of the rebuilt images
	@source $(S)/lib.sh; $(S)/verify-image.sh "$$NODE_IMAGE" "$$DTK_IMAGE" "$$MOS_IMAGE"
push: ## Push the rebuilt images, record digests in build/digests.env
	$(S)/push-images.sh
release: ## Assemble and push the release payload (needs `make push`)
	$(S)/build-release.sh
verify-payload: ## Check that no payload image is still EL10-based
	$(S)/verify-payload.sh

.PHONY: all
all: images verify push release verify-payload ## Full pipeline

# ---------------------------------------------------------------------------
# Maintenance
# ---------------------------------------------------------------------------
.PHONY: rpms-lock print-upstream-commits check clean
rpms-lock: ## Re-pin rpms/okd-el9.lock to the newest el9 node RPMs
	@source $(S)/lib.sh; python3 -I $(S)/rpms-lock.py generate "$$OKD_EL9_RPM_REPO" \
	  cri-o cri-tools conmon-rs openshift-clients openshift-kubelet > rpms/okd-el9.lock.tmp
	mv rpms/okd-el9.lock.tmp rpms/okd-el9.lock
	@cat rpms/okd-el9.lock

print-upstream-commits: ## Show the source commits of the upstream components we rebuild
	@source $(S)/lib.sh; oc_cmd adm release info --commits "$$UPSTREAM_RELEASE_IMAGE" \
	  | grep -E '^\s*(stream-coreos|stream-coreos-extensions|driver-toolkit|machine-os-images|installer) '

check: ## Lint scripts and check that patches apply
	shellcheck -x $(S)/*.sh
	python3 -m py_compile $(S)/*.py
	@source $(S)/lib.sh; BUILD_DIR=$$(mktemp -d); for c in os rhel-coreos-config driver-toolkit machine-os-images; do \
	  prepare_src "$$c"; done; rm -rf "$$BUILD_DIR"

clean: ## Remove build/ (keeps downloaded caches unless CLEAN_CACHE=1)
	@if [[ "$${CLEAN_CACHE:-0}" == 1 ]]; then rm -rf build; else \
	  find build -mindepth 1 -maxdepth 1 ! -name cache -exec rm -rf {} + 2>/dev/null || true; fi
