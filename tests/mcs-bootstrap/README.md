# Machine-config-server bootstrap fixtures

Minimal inputs for `machine-config-server bootstrap`, used by
`scripts/check-bootimage.sh` to ask a real upstream MCS which Ignition spec it
serves for the `Accept` header a boot image's Ignition sends.

* `bs/machine-pools/master.yaml` — the bootstrap server only serves the
  `master` (and `arbiter`) pool; the `Accept` handling is pool independent.
* `bs/machine-configs/rendered-master-test.yaml` — an empty spec 3.5.0 config.
* `bs/controller-config/machine-config-controller.yaml` — empty ControllerConfig.
* `kubeconfig` — dummy; the bootstrap server only embeds it in the served config.
