# Upgrading an OKD 4.19 cluster on x86-64-v2 hardware

Upstream OKD 4.20+ cannot run on x86-64-v2 CPUs, so a 4.19 cluster on such
hardware has to move through the rebuilt releases of this repository:

```
4.19.0-okd-scos.19  (upstream, SCOS 9)
  -> 4.20.0-okd-scos.17-c9s.1
  -> 4.21.0-okd-scos.11-c9s.1
  -> 4.22.0-okd-scos.10-c9s.1
```

Clusters already on an earlier `-c9s` release (e.g. `4.20.0-okd-scos.17-c9s`)
move to the `-c9s.1` build of the same minor first (`./upgrade.py 4.20` does
that hop): the earlier boot image cannot add nodes on 4.20/4.21. On bare metal:

* Hosts that already failed to join (console in the emergency shell,
  `ignition-fetch` logs "400" / the MCS logs "unsupported Ignition version in
  Accept header ... version=3.6.0") keep the old OS on disk. After the hop,
  provision them again: delete their Machine (`oc -n openshift-machine-api
  annotate machine <m> machine.openshift.io/delete-machine=true` and scale the
  MachineSet down, or `oc delete machine <m>` to let it be recreated), wait
  until the BareMetalHost is `available`, then scale up.
* Power off hosts that were inspected or deprovisioned before the hop (fast
  track keeps them on the old deploy ISO), or re-inspect them
  (`oc annotate bmh <h> inspect.metal3.io=`), before scaling up.
* Check on the new node: `journalctl -b -u ignition-fetch.service` shows
  `version=3.5.0` and HTTP 200.

One minor at a time: skipping a minor skips API/storage migrations and is
not supported by OKD. Every hop is a regular `ClusterVersion` upgrade; the
nodes stay on SCOS 9 and are rebased by the MCO to the new node image.

> **Test the path on a lab cluster first.** OKD 4.20–4.22 on SCOS 9 is not a
> combination upstream tests (see [design.md](design.md#known-limitations-and-risks)).
> There is no downgrade: the only way back is an etcd restore.

## Automated: `upgrade.py`

[`upgrade.py`](../upgrade.py) (python3 + `oc`, run as cluster-admin) performs
every step below, hop by hop, up to the requested minor:

```bash
./upgrade.py 4.22 --dry-run          # plan + pre-flight checks only, changes nothing
./upgrade.py 4.22                    # asks before each hop
./upgrade.py 4.22 --yes --ack <gate-key>   # unattended, acknowledging a reviewed admin gate
```

For each hop it waits for the cluster to settle, checks cluster operators,
machine config pools, nodes, `Upgradeable`, admin gates (stops on any gate not
passed with `--ack`) and removed-API usage for the target Kubernetes version,
verifies that the target image really is the expected `-c9s.N` release, takes an
etcd backup on a control-plane node, starts the upgrade by digest, waits for the
ClusterVersion and the machine config pools, and checks that every node runs
SCOS 9. Everything is logged to `upgrade-<timestamp>.log`. It can be re-run at
any point: it starts from whatever version the cluster is on. `./upgrade.py -h`
lists the options (`--skip-backup`, `--registry`, `--release-image`, timeouts).

Step 0 (pull access, staying on 4.19.0-okd-scos.19 first) still applies; the
script clears the update channel itself.

## 0. Before the first hop

1. Be on the newest 4.19 build, `4.19.0-okd-scos.19` (an upstream, signed
   release that still runs SCOS 9). It is the release upstream 4.20.0-okd-scos.17
   lists as a valid source.
2. Stop the cluster from following upstream recommendations (they point at
   SCOS 10 releases):

   ```bash
   oc patch clusterversion version --type merge -p '{"spec":{"channel":""}}'
   ```

3. Make the images pullable by every node: either make the
   `ghcr.io/nobidev/okd-c9s/*` packages public, or merge a `ghcr.io` entry into
   the global pull secret:

   ```bash
   oc get secret/pull-secret -n openshift-config \
     -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > pull-secret.json
   # add "ghcr.io": {"auth": "<base64 user:token>"} under .auths, then:
   oc set data secret/pull-secret -n openshift-config \
     --from-file=.dockerconfigjson=pull-secret.json
   ```

   Disconnected clusters: mirror each release with
   `oc adm release mirror --from=<release@digest> --to=<registry>/okd-c9s`
   and apply the printed `ImageDigestMirrorSet`.

## 1. For every hop (manual equivalent of `upgrade.py`)

```bash
TARGET=ghcr.io/nobidev/okd-c9s/release:4.20.0-okd-scos.17-c9s.1   # then 4.21…, 4.22…

# a) Health: everything Available, nothing Degraded, all pools updated
oc get clusterversion
oc get clusteroperators
oc get machineconfigpools

# b) Gates that `--force` would silently skip
oc adm upgrade                                   # Upgradeable=False reasons
oc -n openshift-config-managed get cm admin-gates -o yaml
#    acknowledge only gates you have checked, e.g. removed APIs:
oc get apirequestcounts -o jsonpath='{range .items[?(@.status.removedInRelease!="")]}{.status.removedInRelease}{"\t"}{.metadata.name}{"\n"}{end}'
oc -n openshift-config patch cm admin-acks --type merge -p '{"data":{"<gate-key>":"true"}}'

# c) etcd backup (keep it off-cluster)
oc debug node/<control-plane-node> -- chroot /host \
  /usr/local/bin/cluster-backup.sh /home/core/assets/backup

# d) Upgrade by digest. The release is not signed by OKD and not in the
#    upgrade graph, hence --allow-explicit-upgrade and --force.
DIGEST=$(oc image info "$TARGET" -o json | jq -r .digest)
oc adm upgrade --allow-explicit-upgrade --force \
  --to-image="${TARGET%:*}@${DIGEST}"

# e) Watch until the version is Completed and every pool is updated
oc adm upgrade
oc get clusterversion -w
oc get machineconfigpools -w
oc get nodes -o wide          # OS-IMAGE: CentOS Stream CoreOS 9.0
```

The CI job summary of a publishing run also prints the release digest
(`build/<minor>/release.env` locally).

`--force` skips signature verification **and** the CVO's precondition checks,
which is why step (b) has to be done by hand.

## 2. After each hop

```bash
oc get clusteroperators                      # all Available=True, Degraded=False
oc debug node/<node> -- chroot /host sh -c 'cat /etc/os-release; rpm-ostree status'
oc -n openshift-machine-config-operator get cm coreos-bootimages \
  -o jsonpath='{.data.stream}' | jq -r .stream   # c9s
```

New machines (scale-up, replacements) must boot from SCOS 9 media; see
[install.md](install.md#3-boot-images).

## If something goes wrong

* A pod crash-looping with `Fatal glibc error: CPU does not support x86-64-v3`
  or `This program can only be run on ... v3 microarchitecture` means a payload
  image is still EL10 or built for v3: run
  `make verify-payload verify-payload-isa RELEASE_IMAGE=<release>` and
  add the component to the rebuild list.
* A stuck node update: `oc -n openshift-machine-config-operator logs
  ds/machine-config-daemon -c machine-config-daemon --since=1h` on the node's pod.
* Recovery from a failed control plane is an etcd restore from the backup taken
  in step (c) (OKD docs: "Restoring to a previous cluster state").
