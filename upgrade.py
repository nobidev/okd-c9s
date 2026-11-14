#!/usr/bin/env python3
"""Upgrade a running OKD cluster on x86-64-v2 hardware to an okd-c9s release.

Walks one minor at a time, e.g. 4.19 -> 4.20 -> 4.21 -> 4.22, using the
releases built by this repository (versions/<minor>.env). For every hop it:

  1. runs pre-flight checks (cluster operators, machine config pools, nodes,
     Upgradeable condition, admin gates, removed-API usage, target release);
  2. takes an etcd backup on a control-plane node (unless --skip-backup);
  3. starts `oc adm upgrade --allow-explicit-upgrade --force --to-image=<digest>`;
  4. waits for the ClusterVersion to complete and for every machine config
     pool to roll out, then checks that the nodes run SCOS 9.

Requirements: python3 >= 3.6 and `oc` logged in as cluster-admin
(KUBECONFIG is honoured). The workstation must be able to read the release
images (`oc image info`), and the cluster must be able to pull them (public
packages or a ghcr.io entry in the global pull secret, see docs/upgrade.md).

Examples:
  ./upgrade.py 4.22 --dry-run            # show the plan and run the checks only
  ./upgrade.py 4.20                      # one hop, asks for confirmation
  ./upgrade.py 4.22 --yes --ack ack-4.19-kube-1.33-api-removals-in-4.20
"""

import argparse
import datetime
import json
import os
import re
import shlex
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.abspath(__file__))
SUPPORTED_SOURCE_419 = "4.19.0-okd-scos.19"
POLL_SECONDS = int(os.environ.get("OKD_C9S_POLL_SECONDS", "30"))

LOG = None


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
def now():
    return datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def log(msg, level="INFO"):
    line = "%s [%s] %s" % (now(), level, msg)
    print(line, flush=True)
    if LOG:
        LOG.write(line + "\n")
        LOG.flush()


def die(msg):
    log(msg, "ERROR")
    sys.exit(1)


def oc(*args, check=True, timeout=600):
    """Run oc and return stdout. Raises RuntimeError on failure if check."""
    cmd = ["oc"] + list(args)
    try:
        proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              universal_newlines=True, timeout=timeout)
    except FileNotFoundError:
        die("`oc` not found on PATH")
    except subprocess.TimeoutExpired:
        raise RuntimeError("timed out: %s" % " ".join(shlex.quote(c) for c in cmd))
    if check and proc.returncode != 0:
        raise RuntimeError("%s failed (%d): %s" % (" ".join(shlex.quote(c) for c in cmd),
                                                  proc.returncode, proc.stderr.strip()))
    return proc.stdout if check else (proc.returncode, proc.stdout, proc.stderr)


def oc_json(*args, timeout=120):
    return json.loads(oc(*(list(args) + ["-o", "json"]), timeout=timeout))


def oc_json_retry(*args, attempts=40):
    """Like oc_json, but tolerate API hiccups (the API server restarts during upgrades)."""
    for i in range(attempts):
        try:
            return oc_json(*args)
        except (RuntimeError, ValueError) as e:
            if i == attempts - 1:
                raise
            log("API not reachable (%s), retrying" % str(e).splitlines()[0][:160], "WARN")
            time.sleep(POLL_SECONDS)


def cond(obj, ctype):
    for c in obj.get("status", {}).get("conditions", []) or []:
        if c.get("type") == ctype:
            return c
    return {}


def minor_of(version):
    m = re.match(r"^(\d+)\.(\d+)\.", version)
    if not m:
        die("cannot parse version %r" % version)
    return "%s.%s" % (m.group(1), m.group(2))


def minor_key(minor):
    major, mnr = minor.split(".")
    return (int(major), int(mnr))


def read_env(path):
    env = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k] = v
    return env


def confirm(question, assume_yes):
    if assume_yes:
        return True
    try:
        answer = input("%s [y/N] " % question)
    except EOFError:
        return False
    return answer.strip().lower() in ("y", "yes")


# ---------------------------------------------------------------------------
# release catalogue (from versions/)
# ---------------------------------------------------------------------------
def load_catalogue(registry_override, overrides):
    common = read_env(os.path.join(ROOT, "versions", "common.env"))
    registry = registry_override or os.environ.get("REGISTRY") or common["REGISTRY"]
    suffix = common.get("RELEASE_SUFFIX", "c9s")
    cat = {}
    for name in os.listdir(os.path.join(ROOT, "versions")):
        m = re.match(r"^(\d+\.\d+)\.env$", name)
        if not m:
            continue
        env = read_env(os.path.join(ROOT, "versions", name))
        release_name = "%s-%s" % (env["OKD_VERSION"], suffix)
        cat[m.group(1)] = {
            "name": release_name,
            "image": "%s/release:%s" % (registry, release_name),
        }
    for item in overrides or []:
        minor, _, image = item.partition("=")
        if minor not in cat or not image:
            die("bad --release-image %r (want MINOR=IMAGE, MINOR one of %s)"
                % (item, ", ".join(sorted(cat, key=minor_key))))
        cat[minor]["image"] = image
    return cat


def resolve_release(entry):
    """Return the digest pull spec of a release and check its name."""
    image = entry["image"]
    info = oc_json("adm", "release", "info", image)
    version = info.get("metadata", {}).get("version", "")
    if version != entry["name"]:
        die("%s is release %r, expected %r" % (image, version, entry["name"]))
    digest = info.get("digest")
    if not digest:
        die("cannot determine the digest of %s" % image)
    repo = image.split("@")[0]
    if ":" in repo.rsplit("/", 1)[-1]:
        repo = repo.rsplit(":", 1)[0]
    return "%s@%s" % (repo, digest)


# ---------------------------------------------------------------------------
# cluster state
# ---------------------------------------------------------------------------
def cluster_version():
    return oc_json_retry("get", "clusterversion", "version")


def current_version(cv):
    """Version the cluster is fully on (last Completed history entry)."""
    for h in cv.get("status", {}).get("history", []) or []:
        if h.get("state") == "Completed":
            return h.get("version")
    return cv.get("status", {}).get("desired", {}).get("version")


def upgrade_in_progress(cv):
    hist = cv.get("status", {}).get("history", []) or []
    return bool(hist) and hist[0].get("state") != "Completed"


def check_cluster_operators(strict=True):
    problems = []
    for co in oc_json_retry("get", "clusteroperators").get("items", []):
        name = co["metadata"]["name"]
        if cond(co, "Available").get("status") != "True":
            problems.append("%s not Available: %s" % (name, cond(co, "Available").get("message", "")))
        if cond(co, "Degraded").get("status") == "True":
            problems.append("%s Degraded: %s" % (name, cond(co, "Degraded").get("message", "")))
        if strict and cond(co, "Progressing").get("status") == "True":
            problems.append("%s Progressing: %s" % (name, cond(co, "Progressing").get("message", "")))
    return problems


def mcp_status():
    """Return (all_done, problems, summary) for the machine config pools."""
    problems, summary, done = [], [], True
    for p in oc_json_retry("get", "machineconfigpools").get("items", []):
        name = p["metadata"]["name"]
        st = p.get("status", {})
        total = st.get("machineCount", 0)
        updated = st.get("updatedMachineCount", 0)
        degraded = st.get("degradedMachineCount", 0)
        if p.get("spec", {}).get("paused"):
            problems.append("pool %s is paused" % name)
        if cond(p, "Degraded").get("status") == "True" or degraded:
            problems.append("pool %s degraded: %s" % (name, cond(p, "Degraded").get("message", "")))
        if cond(p, "Updated").get("status") != "True" or updated != total:
            done = False
        summary.append("%s %d/%d" % (name, updated, total))
    return done, problems, ", ".join(summary)


def node_problems():
    problems = []
    for n in oc_json_retry("get", "nodes").get("items", []):
        if cond(n, "Ready").get("status") != "True":
            problems.append("node %s not Ready" % n["metadata"]["name"])
    return problems


def node_os_images():
    return {n["metadata"]["name"]: n["status"].get("nodeInfo", {}).get("osImage", "")
            for n in oc_json_retry("get", "nodes").get("items", [])}


def unacked_admin_gates():
    rc, out, _ = oc("get", "configmap", "admin-gates", "-n", "openshift-config-managed",
                    "-o", "json", check=False)
    if rc != 0:
        return {}
    gates = json.loads(out).get("data", {}) or {}
    rc, out, _ = oc("get", "configmap", "admin-acks", "-n", "openshift-config",
                    "-o", "json", check=False)
    acks = (json.loads(out).get("data", {}) or {}) if rc == 0 else {}
    return {k: v for k, v in gates.items() if acks.get(k) != "true"}


def removed_api_usage(target_minor):
    """APIs removed in the target's Kubernetes release that still get requests.

    OpenShift/OKD 4.x ships Kubernetes 1.(x+13), e.g. 4.20 -> 1.33."""
    kube = "1.%d" % (int(target_minor.split(".")[1]) + 13)
    rc, out, _ = oc("get", "apirequestcounts", "-o", "json", check=False, timeout=300)
    if rc != 0:
        return []
    hits = []
    for item in json.loads(out).get("items", []):
        st = item.get("status", {})
        removed = st.get("removedInRelease")
        if removed == kube and st.get("requestCount", 0) > 0:
            hits.append("%s (removed in Kubernetes %s, %d requests in 24h)"
                        % (item["metadata"]["name"], removed, st.get("requestCount", 0)))
    return hits


# ---------------------------------------------------------------------------
# steps
# ---------------------------------------------------------------------------
def preflight(target_minor, args):
    """Return the admin gates to acknowledge; exit (or return None on dry run) on problems."""
    log("pre-flight checks for %s" % target_minor)
    fatal, to_ack = [], []
    cv = cluster_version()
    if upgrade_in_progress(cv):
        fatal.append("an upgrade is already in progress (%s)" % cv["status"]["history"][0].get("version"))
    for ctype, bad in (("Available", "False"), ("Failing", "True")):
        c = cond(cv, ctype)
        if c.get("status") == bad:
            fatal.append("ClusterVersion %s=%s: %s" % (ctype, bad, c.get("message", "")))
    fatal += check_cluster_operators()
    done, pool_problems, summary = mcp_status()
    fatal += pool_problems
    if not done:
        fatal.append("machine config pools are still updating (%s)" % summary)
    fatal += node_problems()

    upgradeable = cond(cv, "Upgradeable")
    if upgradeable.get("status") == "False":
        msg = "Upgradeable=False: %s" % upgradeable.get("message", "")
        if args.ignore_upgradeable:
            log(msg + " (ignored: --ignore-upgradeable)", "WARN")
        else:
            fatal.append(msg + " (resolve it, or pass --ignore-upgradeable after reviewing)")

    gates = unacked_admin_gates()
    for key, text in sorted(gates.items()):
        if key in args.ack:
            log("admin gate %s will be acknowledged (--ack): %s" % (key, text), "WARN")
            to_ack.append(key)
        else:
            fatal.append("admin gate not acknowledged: %s\n      %s\n      review it, then pass --ack %s"
                         % (key, text, key))

    for hit in removed_api_usage(target_minor):
        log("removed API still in use: %s" % hit, "WARN")

    if fatal:
        for f in fatal:
            log(f, "ERROR")
        if args.dry_run:
            log("dry run: the problems above would stop the upgrade", "WARN")
            return None
        die("pre-flight checks failed")
    log("pre-flight checks passed")
    return to_ack


def acknowledge(gates):
    for key in gates:
        log("acknowledging admin gate %s" % key)
        oc("patch", "configmap", "admin-acks", "-n", "openshift-config", "--type=merge",
           "-p", json.dumps({"data": {key: "true"}}))


def wait_settled(args):
    """Give operators and pools time to settle (e.g. right after a previous hop)."""
    deadline = time.time() + args.settle_timeout * 60
    while True:
        cv = cluster_version()
        progressing = [p for p in check_cluster_operators(strict=True)
                       if " Progressing: " in p]
        done, _, summary = mcp_status()
        if not upgrade_in_progress(cv) and not progressing and done:
            return
        if time.time() > deadline:
            log("cluster still settling after %d min (%s)"
                % (args.settle_timeout, "; ".join(progressing) or summary), "WARN")
            return
        log("waiting for the cluster to settle: %s" % ("; ".join(progressing) or "pools " + summary))
        time.sleep(POLL_SECONDS)


def etcd_backup(args, label):
    if args.skip_backup:
        log("etcd backup skipped (--skip-backup)", "WARN")
        return
    nodes = oc_json("get", "nodes", "-l", "node-role.kubernetes.io/master").get("items", [])
    if not nodes:
        nodes = oc_json("get", "nodes", "-l", "node-role.kubernetes.io/control-plane").get("items", [])
    if not nodes:
        die("no control-plane node found for the etcd backup")
    node = nodes[0]["metadata"]["name"]
    path = "/home/core/assets/backup-%s-before-%s" % (
        datetime.datetime.now().strftime("%Y%m%d-%H%M%S"), label)
    log("etcd backup on %s -> %s" % (node, path))
    if args.dry_run:
        return
    rc, out, err = oc("debug", "--quiet", "node/%s" % node, "--", "chroot", "/host",
                      "/usr/local/bin/cluster-backup.sh", path, check=False, timeout=1800)
    if LOG:
        LOG.write(out + err)
    if rc != 0:
        die("etcd backup failed (exit %d); see the log. Use --skip-backup to proceed without one." % rc)
    log("etcd backup done on %s:%s -- copy it off the cluster" % (node, path))


def start_upgrade(pullspec, args):
    cmd = ["adm", "upgrade", "--allow-explicit-upgrade", "--force", "--to-image=%s" % pullspec]
    log("oc " + " ".join(cmd))
    if args.dry_run:
        return
    rc, out, err = oc(*cmd, check=False)
    if rc != 0 and "--allow-upgrade-with-warnings" in (out + err):
        log("retrying with --allow-upgrade-with-warnings (pre-flight already reviewed)", "WARN")
        rc, out, err = oc(*(cmd + ["--allow-upgrade-with-warnings"]), check=False)
    log((out + err).strip())
    if rc != 0:
        die("oc adm upgrade failed")


def wait_for_cvo(target_name, args):
    deadline = time.time() + args.cvo_timeout * 60
    last_msg, failing_since = None, None
    while True:
        cv = cluster_version()
        hist = cv.get("status", {}).get("history", []) or [{}]
        top = hist[0]
        if top.get("version") == target_name and top.get("state") == "Completed":
            log("ClusterVersion completed: %s" % target_name)
            return
        prog = cond(cv, "Progressing").get("message", "")
        if prog != last_msg:
            log("CVO: %s" % prog)
            last_msg = prog
        failing = cond(cv, "Failing")
        if failing.get("status") == "True":
            failing_since = failing_since or time.time()
            reason = failing.get("reason", "")
            log("CVO Failing (%s): %s" % (reason, failing.get("message", "")), "WARN")
            if reason in ("RetrievePayload", "ImageVerificationFailed"):
                die("the cluster cannot fetch the release payload; check that nodes can pull "
                    "from the registry (pull secret / public packages) and retry")
        else:
            failing_since = None
        if time.time() > deadline:
            die("timed out after %d min waiting for the ClusterVersion; the upgrade keeps "
                "running, inspect with `oc adm upgrade` and re-run this script" % args.cvo_timeout)
        time.sleep(POLL_SECONDS)


def wait_for_pools(args):
    # The MCO renders the new configs while the CVO finishes; give it a moment
    # so the pools report the new target before we look at them.
    time.sleep(2 * POLL_SECONDS)
    deadline = time.time() + args.mcp_timeout * 60
    last = None
    while True:
        done, problems, summary = mcp_status()
        if summary != last:
            log("machine config pools: %s" % summary)
            last = summary
        for p in problems:
            log(p, "WARN")
        if done and not problems:
            return
        if time.time() > deadline:
            die("timed out after %d min waiting for the machine config pools" % args.mcp_timeout)
        time.sleep(POLL_SECONDS)


def postflight():
    problems = check_cluster_operators(strict=False) + node_problems()
    for p in problems:
        log(p, "WARN")
    images = node_os_images()
    wrong = {n: i for n, i in images.items() if "CoreOS 9" not in i}
    for n, i in sorted(wrong.items()):
        log("node %s runs %r, expected SCOS 9" % (n, i), "WARN")
    if problems or wrong:
        die("post-upgrade checks found problems; fix them before the next hop")
    log("all %d nodes run %s" % (len(images), sorted(set(images.values()))[0] if images else "?"))


# ---------------------------------------------------------------------------
def main():
    global LOG
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("target", help="target OKD minor, e.g. 4.22")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the plan and run the checks, change nothing")
    ap.add_argument("-y", "--yes", action="store_true", help="do not ask for confirmation")
    ap.add_argument("--ack", action="append", default=[], metavar="GATE",
                    help="acknowledge this admin gate (repeatable); review it first")
    ap.add_argument("--ignore-upgradeable", action="store_true",
                    help="proceed although ClusterVersion reports Upgradeable=False")
    ap.add_argument("--skip-backup", action="store_true", help="do not take etcd backups")
    ap.add_argument("--allow-old-419", action="store_true",
                    help="start from a 4.19 build older than %s" % SUPPORTED_SOURCE_419)
    ap.add_argument("--registry", help="registry prefix of the releases "
                    "(default: REGISTRY from versions/common.env)")
    ap.add_argument("--release-image", action="append", metavar="MINOR=IMAGE",
                    help="use this release image for MINOR (repeatable)")
    ap.add_argument("--cvo-timeout", type=int, default=180, metavar="MIN",
                    help="minutes to wait for the ClusterVersion per hop (default 180)")
    ap.add_argument("--mcp-timeout", type=int, default=360, metavar="MIN",
                    help="minutes to wait for node roll-out per hop (default 360)")
    ap.add_argument("--settle-timeout", type=int, default=30, metavar="MIN",
                    help="minutes to wait for operators/pools to settle before a hop (default 30)")
    ap.add_argument("--log-file", default="upgrade-%s.log" % datetime.datetime.now().strftime("%Y%m%d-%H%M%S"),
                    help="log file (default: ./upgrade-<timestamp>.log)")
    args = ap.parse_args()

    LOG = open(args.log_file, "a")
    log("okd-c9s upgrade to %s (log: %s)" % (args.target, os.path.abspath(args.log_file)))

    catalogue = load_catalogue(args.registry, args.release_image)
    if args.target not in catalogue:
        die("unsupported target %s; available: %s" % (args.target, ", ".join(sorted(catalogue, key=minor_key))))

    oc("whoami")
    cv = cluster_version()
    current = current_version(cv)
    cur_minor = minor_of(current)
    log("cluster version: %s" % current)

    if cur_minor not in catalogue and minor_key(cur_minor) < minor_key(min(catalogue, key=minor_key)):
        if cur_minor != "4.19":
            die("the cluster must be on OKD 4.19 first (it is on %s)" % current)
        if current != SUPPORTED_SOURCE_419 and not args.allow_old_419:
            die("upgrade to %s first (upstream, signed, still SCOS 9), or pass --allow-old-419"
                % SUPPORTED_SOURCE_419)
    elif cur_minor in catalogue and current != catalogue[cur_minor]["name"]:
        if not current.endswith("-c9s"):
            die("the cluster runs %s, which is not an okd-c9s release; upstream OKD %s+ "
                "cannot run on x86-64-v2 hardware" % (current, min(catalogue, key=minor_key)))
        log("cluster is on an older okd-c9s build of %s; it will move to %s"
            % (cur_minor, catalogue[cur_minor]["name"]), "WARN")

    path = [m for m in sorted(catalogue, key=minor_key)
            if minor_key(cur_minor) < minor_key(m) <= minor_key(args.target)]
    if cur_minor in catalogue and current != catalogue[cur_minor]["name"]:
        path.insert(0, cur_minor)
    if not path:
        log("nothing to do: already on %s" % current)
        return

    plan = []
    for m in path:
        pullspec = resolve_release(catalogue[m])
        plan.append((m, catalogue[m]["name"], pullspec))
    log("upgrade plan:")
    log("  %s (current)" % current)
    for m, name, pullspec in plan:
        log("  -> %s  %s" % (name, pullspec))

    if cv.get("spec", {}).get("channel"):
        log("ClusterVersion follows channel %r; it will be cleared so the cluster does not "
            "recommend upstream SCOS 10 releases" % cv["spec"]["channel"], "WARN")
        if not args.dry_run:
            if not confirm("Clear the update channel?", args.yes):
                die("aborted")
            oc("patch", "clusterversion", "version", "--type=merge", "-p", '{"spec":{"channel":""}}')

    for m, name, pullspec in plan:
        log("========== %s -> %s ==========" % (current_version(cluster_version()), name))
        if args.dry_run:
            if m != plan[0][0]:
                log("dry run: this hop is checked against the current cluster state, "
                    "not the state after the previous hop", "WARN")
            to_ack = preflight(m, args)
            etcd_backup(args, name)
            start_upgrade(pullspec, args)
            if to_ack is None:
                log("dry run stops here: later hops depend on this one", "WARN")
                break
            continue
        wait_settled(args)
        to_ack = preflight(m, args)
        if not confirm("Upgrade to %s now?" % name, args.yes):
            die("aborted by user")
        acknowledge(to_ack)
        etcd_backup(args, name)
        start_upgrade(pullspec, args)
        wait_for_cvo(name, args)
        wait_for_pools(args)
        postflight()
        log("hop to %s finished" % name)

    log("done" if not args.dry_run else "dry run finished, nothing was changed")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        log("interrupted; an upgrade that was already started keeps running in the cluster", "WARN")
        sys.exit(130)
    except RuntimeError as e:
        die(str(e))
