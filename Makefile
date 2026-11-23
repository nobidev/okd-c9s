# okd-c9s: rebuild OKD for x86-64-v2 (pre-Haswell) CPUs.
#
# Settings live in versions/common.env and versions/<minor>.env; OKD_MINOR
# selects the minor (default: DEFAULT_OKD_MINOR in versions/common.env).
# Anything can be overridden on the command line or in the environment, e.g.
#   make images OKD_MINOR=4.20 REGISTRY=quay.io/me/okd
# Build targets need podman with privileges (see README.md / CI workflow).

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

# Settings that the scripts honour when set in the environment.
export OKD_MINOR REGISTRY OKD_VERSION UPSTREAM_RELEASE_IMAGE RELEASE_SUFFIX RELEASE_NAME \
       OC_IMAGE PODMAN BUILD_DIR FORCE SCOS_USE_LOCKFILE SCOS_BUILD_VERSION WITH_CRED_PROVIDERS \
       REGISTRY_AUTH_FILE QEMU_CPU

S := scripts
MINORS := $(sort $(patsubst versions/%.env,%,$(filter-out versions/common.env,$(wildcard versions/*.env))))

.PHONY: help
help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: submodules minors info
submodules: ## Initialise the pinned upstream submodules
	git submodule update --init --recursive

minors: ## List the OKD minors this repository can build
	@echo $(MINORS)

info: ## Print the resolved settings and image names for OKD_MINOR
	@source $(S)/lib.sh; for v in OKD_MINOR OKD_VERSION RELEASE_NAME UPSTREAM_RELEASE_IMAGE BASE_IMAGE RELEASE_IMAGE; do \
	  printf '%-26s %s\n' "$$v" "$${!v}"; done; \
	  for c in "$${REPLACED_COMPONENTS[@]}"; do printf '%-26s %s\n' "$$c" "$$(component_image "$$c")"; done

# ---------------------------------------------------------------------------
# Images
# ---------------------------------------------------------------------------
.PHONY: bootimages base node extensions dtk machine-os-images installer images
bootimages: ## SCOS 9 boot image stream metadata -> build/bootimages/<build>/stream.json
	$(S)/fetch-bootimages.sh
base: ## SCOS 9 base bootable container (coreos/rhel-coreos-config, c9s)
	$(S)/build-base.sh
node: base ## Node image "stream-coreos" (upstream/<minor>/os + patches/<minor>/os)
	$(S)/build-node.sh
extensions: node ## "stream-coreos-extensions" (kernel-rt, usbguard, kata, ...)
	$(S)/build-extensions.sh
dtk: node ## "driver-toolkit" matching the node kernel
	$(S)/build-dtk.sh
machine-os-images: ## "machine-os-images" carrying the SCOS 9 live ISO
	$(S)/build-machine-os-images.sh
installer: ## Installer images (BOOTIMAGES_COMPONENTS) with SCOS 9 coreos-bootimages
	$(S)/build-installer.sh
images: node extensions dtk machine-os-images installer ## Build every replaced component

# ---------------------------------------------------------------------------
# Verification / publishing
# ---------------------------------------------------------------------------
.PHONY: verify push release verify-payload
verify: ## ISA scan + qemu (Nehalem) execution test of the rebuilt images
	@source $(S)/lib.sh; $(S)/verify-image.sh "$$NODE_IMAGE" "$$DTK_IMAGE" "$$MOS_IMAGE"
push: ## Push the rebuilt images, record digests in build/<minor>/digests.env
	$(S)/push-images.sh
release: ## Assemble and push the release payload (needs `make push`)
	$(S)/build-release.sh
verify-payload: ## Check that no payload image is still EL10-based
	$(S)/verify-payload.sh

.PHONY: all
all: images verify push release verify-payload ## Full pipeline for OKD_MINOR

# ---------------------------------------------------------------------------
# Maintenance
# ---------------------------------------------------------------------------
.PHONY: rpms-lock print-upstream-commits check check-bootimages clean
rpms-lock: ## Re-pin rpms/okd-el9-<minor>.lock to the newest el9 node RPMs
	@source $(S)/lib.sh; python3 -I $(S)/rpms-lock.py generate "$$OKD_EL9_RPM_REPO" \
	  cri-o cri-tools conmon-rs openshift-clients openshift-kubelet > "$$RPM_LOCK.tmp"; \
	  mv "$$RPM_LOCK.tmp" "$$RPM_LOCK"; cat "$$RPM_LOCK"

print-upstream-commits: ## Show the source commits of the upstream components we rebuild
	@source $(S)/lib.sh; oc_cmd adm release info --commits "$$UPSTREAM_RELEASE_IMAGE" \
	  | grep -E '^\s*(stream-coreos|stream-coreos-extensions|driver-toolkit|machine-os-images|installer[a-z-]*) '

check: ## Lint scripts and check that every minor's patches apply
	shellcheck -x $(S)/*.sh
	python3 -m py_compile $(S)/*.py upgrade.py
	$(S)/check-patches.sh $(MINORS)

check-bootimages: ## Check each minor's boot image Ignition against its and its upgrade sources' MCS (needs network + podman)
	@for m in $(MINORS); do OKD_MINOR=$$m $(S)/check-bootimage.sh || exit 1; done

clean: ## Remove build/ (keeps downloaded caches unless CLEAN_CACHE=1)
	@if [[ "$${CLEAN_CACHE:-0}" == 1 ]]; then rm -rf build; else \
	  find build -mindepth 1 -maxdepth 1 ! -name cache -exec rm -rf {} + 2>/dev/null || true; fi
