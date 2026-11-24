#!/usr/bin/python3 -I
"""Scan every layer of every image in a release payload for x86-64 ELF objects
that require more than x86-64-v2 (same rules as check-isa.py: the GNU
ISA_1_NEEDED note and Go GOAMD64=v3/v4; optional glibc-hwcaps v3/v4 variants
are ignored).

  check-payload-isa.py [--auth AUTH.json] [--jobs N] IMAGES.txt

IMAGES.txt has one "<name> <pullspec>" per line (what
`oc adm release info --pullspecs` lists). Layers are streamed and never written
to disk; a layer shared by several images is read once. A hit is only reported
for an image if no upper layer of that image deletes or replaces the file.

Exit status: 0 clean, 1 offending objects found, 2 a layer or image could not
be read (the result would be incomplete).
"""

import argparse
import base64
import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

_spec = importlib.util.spec_from_file_location(
    "check_isa", os.path.join(os.path.dirname(os.path.abspath(__file__)), "check-isa.py"))
isa = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(isa)

ACCEPT = ",".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


class _NoAuthRedirect(urllib.request.HTTPRedirectHandler):
    # Blob downloads redirect to object storage, which rejects the registry token.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None:
            new.remove_header("Authorization")
        return new


OPENER = urllib.request.build_opener(_NoAuthRedirect)


class Registry:
    def __init__(self, auth_file):
        self.creds = {}
        if auth_file and os.path.isfile(auth_file):
            with open(auth_file) as f:
                for host, entry in (json.load(f).get("auths") or {}).items():
                    if entry.get("auth"):
                        self.creds[host.split("/")[0]] = entry["auth"]
        self.tokens = {}
        self.lock = threading.Lock()

    def _token(self, host, repo):
        key = (host, repo)
        with self.lock:
            if key in self.tokens:
                return self.tokens[key]
        try:
            OPENER.open(urllib.request.Request(f"https://{host}/v2/"), timeout=60)
            tok = None  # registry without auth
        except urllib.error.HTTPError as e:
            if e.code != 401:
                raise
            challenge = e.headers.get("WWW-Authenticate", "")
            params = dict(re.findall(r'(\w+)="([^"]*)"', challenge))
            if not challenge.lower().startswith("bearer") or "realm" not in params:
                raise RuntimeError(f"{host}: unsupported auth challenge {challenge!r}")
            url = params["realm"] + "?" + urllib.parse.urlencode(
                {k: v for k, v in (("service", params.get("service")),
                                   ("scope", f"repository:{repo}:pull")) if v})
            headers = {}
            if host in self.creds:
                headers["Authorization"] = "Basic " + self.creds[host]
            with OPENER.open(urllib.request.Request(url, headers=headers), timeout=60) as r:
                body = json.load(r)
            tok = body.get("token") or body.get("access_token")
        with self.lock:
            self.tokens[key] = tok
        return tok

    def open(self, host, repo, path, accept=None, timeout=300):
        last = None
        for attempt in range(5):
            try:
                headers = {"Accept": accept} if accept else {}
                tok = self._token(host, repo)
                if tok:
                    headers["Authorization"] = "Bearer " + tok
                return OPENER.open(urllib.request.Request(
                    f"https://{host}/v2/{repo}/{path}", headers=headers), timeout=timeout)
            except Exception as e:  # noqa: BLE001 - retried, then reported
                last = e
                time.sleep(2 ** attempt)
        raise RuntimeError(f"{host}/{repo}/{path}: {last}")

    def manifest(self, ref):
        host, repo, ref_part = split_ref(ref)
        with self.open(host, repo, "manifests/" + ref_part, ACCEPT) as r:
            m = json.load(r)
        if "manifests" in m:
            amd64 = [x for x in m["manifests"]
                     if x.get("platform", {}).get("architecture") == "amd64"
                     and x.get("platform", {}).get("os", "linux") == "linux"]
            if not amd64:
                raise RuntimeError(f"{ref}: no linux/amd64 manifest")
            with self.open(host, repo, "manifests/" + amd64[0]["digest"], ACCEPT) as r:
                m = json.load(r)
        return host, repo, m


def split_ref(ref):
    host, rest = ref.split("/", 1)
    if "@" in rest:
        repo, ref_part = rest.split("@", 1)
    else:
        repo, ref_part = rest.rsplit(":", 1)
    return host, repo, ref_part


def norm(path):
    while path.startswith("./"):
        path = path[2:]
    return path.lstrip("/")


def scan_layer(reg, host, repo, digest, media_type):
    """Return hits, file paths and whiteouts of one layer."""
    resp = reg.open(host, repo, "blobs/" + digest, timeout=1800)
    proc = None
    try:
        if "zstd" in media_type:
            proc = subprocess.Popen(["zstd", "-dc"], stdin=resp, stdout=subprocess.PIPE)
            stream, mode = proc.stdout, "r|"
        else:
            stream, mode = resp, "r|*"
        hits, files, deleted, opaque = [], set(), set(), []
        elf = 0
        with tarfile.open(fileobj=stream, mode=mode) as tf:
            for m in tf:
                path = norm(m.name)
                base = os.path.basename(path)
                if base == ".wh..wh..opq":
                    opaque.append(os.path.dirname(path))
                    continue
                if base.startswith(".wh."):
                    deleted.add(os.path.join(os.path.dirname(path), base[4:]))
                    continue
                files.add(path)
                if not m.isreg() or m.size < 64:
                    continue
                f = tf.extractfile(m)
                if f.read(4) != isa.ELF_MAGIC:
                    continue
                data = isa.ELF_MAGIC + f.read()
                needed = isa.isa_needed(io.BytesIO(data))
                if needed is None:
                    continue
                elf += 1
                if isa.optional_hwcaps(path):
                    continue
                if needed & (isa.ISA_V3 | isa.ISA_V4):
                    hits.append((path, "gnu-property: " + isa.describe(needed)))
                    continue
                level = isa.go_level(data)
                if level:
                    hits.append((path, f"go-buildinfo: GOAMD64={level}"))
    finally:
        resp.close()
        if proc:
            proc.wait()
    if proc and proc.returncode:
        raise RuntimeError(f"zstd failed on {digest}")
    return {"elf": elf, "hits": hits, "files": files, "deleted": deleted, "opaque": opaque}


def removed_above(path, upper_layers):
    for layer in upper_layers:
        if path in layer["files"] or path in layer["deleted"]:
            return True
        if any(path.startswith(d + "/") for d in (*layer["deleted"], *layer["opaque"]) if d):
            return True
    return False


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("images", help='file with "<name> <pullspec>" lines')
    ap.add_argument("--auth", help="containers auth.json for private registries")
    ap.add_argument("--jobs", type=int, default=4, help="layers scanned in parallel (default 4)")
    ap.add_argument("--max-report", type=int, default=50)
    args = ap.parse_args()

    with open(args.images) as f:
        images = [l.split() for l in f if l.strip()]
    reg = Registry(args.auth)
    errors = []

    def resolve(item):
        name, ref = item
        try:
            host, repo, m = reg.manifest(ref)
            return name, [(l["digest"], l["mediaType"], l.get("size", 0), host, repo) for l in m["layers"]]
        except Exception as e:  # noqa: BLE001
            errors.append(f"{name}: {e}")
            return name, None

    image_layers, layers = {}, {}
    with ThreadPoolExecutor(8) as ex:
        for name, ls in ex.map(resolve, images):
            if ls is None:
                continue
            image_layers[name] = [l[0] for l in ls]
            for digest, mt, size, host, repo in ls:
                layers.setdefault(digest, (host, repo, mt, size))
    total = sum(v[3] for v in layers.values())
    print(f"{len(images)} images, {len(layers)} unique layers ({total / 1e9:.1f} GB compressed)", flush=True)

    results, done, lock = {}, [0, 0], threading.Lock()

    def work(digest):
        host, repo, mt, size = layers[digest]
        res = None
        for attempt in range(3):
            try:
                res = scan_layer(reg, host, repo, digest, mt)
                break
            except Exception as e:  # noqa: BLE001
                res = e
                time.sleep(5 * (attempt + 1))
        with lock:
            if isinstance(res, Exception):
                errors.append(f"layer {digest}: {res}")
            else:
                results[digest] = res
            done[0] += 1
            done[1] += size
            if done[0] % 25 == 0 or done[0] == len(layers):
                print(f"  {done[0]}/{len(layers)} layers, {done[1] / 1e9:.1f}/{total / 1e9:.1f} GB", flush=True)

    with ThreadPoolExecutor(max(1, args.jobs)) as ex:
        list(ex.map(work, sorted(layers, key=lambda d: -layers[d][3])))

    offenders, elf_total = [], 0
    for digest, res in results.items():
        elf_total += res["elf"]
    for name, digests in sorted(image_layers.items()):
        for i, digest in enumerate(digests):
            res = results.get(digest)
            if not res:
                continue
            upper = [results[d] for d in digests[i + 1:] if d in results]
            for path, why in res["hits"]:
                if not removed_above(path, upper):
                    offenders.append((name, path, why))

    print(f"scanned {elf_total} x86-64 ELF objects in {len(results)} layers of {len(image_layers)} images")
    for e in errors:
        print(f"ERROR: {e}")
    if offenders:
        print(f"FAIL: {len(offenders)} object(s) require more than x86-64-v2:")
        for name, path, why in offenders[:args.max_report]:
            print(f"  {name}: /{path}  [{why}]")
        if len(offenders) > args.max_report:
            print(f"  ... and {len(offenders) - args.max_report} more")
        return 1
    if errors:
        print("INCOMPLETE: some images or layers could not be scanned")
        return 2
    print("OK: no payload image contains an object that requires more than x86-64-v2")
    return 0


if __name__ == "__main__":
    sys.exit(main())
