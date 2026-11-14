#!/usr/bin/python3 -I
"""Convert a coreos-assembler build meta.json into CoreOS stream metadata.

The output follows the stream metadata format consumed by openshift-install
(`data/data/coreos/*.json`), the MCO (`coreos-bootimages` ConfigMap) and
machine-os-images (`coreos-stream.json`). Only the artifacts that the
SCOS 9 pipeline publishes for x86_64 are emitted (metal + qemu).

  gen-stream-json.py --meta meta.json --base-url URL --stream c9s > stream.json

URL is the directory that contains the build artifacts, e.g.
https://rhcos.mirror.openshift.com/art/storage/prod/streams/c9s/builds/<id>/x86_64
"""

import argparse
import datetime
import json
import sys

ARCH = "x86_64"


def disk(meta, image, base_url):
    img = meta["images"][image]
    return {
        "location": f"{base_url.rstrip('/')}/{img['path']}",
        "sha256": img["sha256"],
        "uncompressed-sha256": img.get("uncompressed-sha256"),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--meta", required=True, help="cosa meta.json of the build")
    ap.add_argument("--base-url", required=True, help="URL of the build's artifact directory")
    ap.add_argument("--stream", required=True, help="stream name, e.g. c9s")
    args = ap.parse_args()

    with open(args.meta) as f:
        meta = json.load(f)
    if meta.get("coreos-assembler.basearch", ARCH) != ARCH:
        sys.exit(f"error: meta.json is not for {ARCH}")
    release = meta["buildid"]
    images = meta["images"]
    required = ("live-iso", "live-kernel", "live-initramfs", "live-rootfs", "metal")
    missing = [i for i in required if i not in images]
    if missing:
        sys.exit(f"error: build {release} lacks artifacts: {', '.join(missing)}")

    metal_formats = {
        "iso": {"disk": disk(meta, "live-iso", args.base_url)},
        "pxe": {
            "kernel": disk(meta, "live-kernel", args.base_url),
            "initramfs": disk(meta, "live-initramfs", args.base_url),
            "rootfs": disk(meta, "live-rootfs", args.base_url),
        },
    }
    metal_ext = images["metal"]["path"].split(f".{ARCH}.", 1)[1]  # e.g. raw.gz
    metal_formats[metal_ext] = {"disk": disk(meta, "metal", args.base_url)}
    if "metal4k" in images:
        metal_formats["4k." + metal_ext] = {"disk": disk(meta, "metal4k", args.base_url)}

    artifacts = {"metal": {"release": release, "formats": metal_formats}}
    if "qemu" in images:
        qemu_ext = images["qemu"]["path"].split(f".{ARCH}.", 1)[1]  # e.g. qcow2.gz
        artifacts["qemu"] = {"release": release,
                             "formats": {qemu_ext: {"disk": disk(meta, "qemu", args.base_url)}}}

    stream = {
        "stream": args.stream,
        "metadata": {
            "last-modified": datetime.datetime.now(datetime.timezone.utc)
            .strftime("%Y-%m-%dT%H:%M:%SZ"),
            "generator": "okd-c9s gen-stream-json.py",
        },
        "architectures": {ARCH: {"artifacts": artifacts}},
    }
    json.dump(stream, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
