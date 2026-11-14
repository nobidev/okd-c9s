#!/usr/bin/python3 -I
"""Render the `coreos-bootimages` ConfigMap shipped by the installer image.

Mirrors the manifest openshift/installer generates (hack/build-coreos-manifest.go)
for OKD: `stream` holds the default stream and `streams` maps stream names to
stream metadata (OKD only has the default "" entry). `releaseVersion` keeps the
"0.0.1-snapshot" placeholder that `oc adm release new` substitutes.

  gen-bootimages-cm.py stream.json > coreos-bootimages.yaml
"""

import json
import sys


def block(text, indent):
    pad = " " * indent
    return "\n".join(pad + line for line in text.splitlines())


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with open(sys.argv[1]) as f:
        stream = json.load(f)
    stream_json = json.dumps(stream, indent=2)
    streams_json = json.dumps({"": stream}, indent=2)
    print(f"""apiVersion: v1
data:
  releaseVersion: 0.0.1-snapshot
  stream: |-
{block(stream_json, 4)}
  streams: |-
{block(streams_json, 4)}
kind: ConfigMap
metadata:
  annotations:
    include.release.openshift.io/ibm-cloud-managed: "true"
    include.release.openshift.io/self-managed-high-availability: "true"
    include.release.openshift.io/single-node-developer: "true"
  name: coreos-bootimages
  namespace: openshift-machine-config-operator""")


if __name__ == "__main__":
    main()
