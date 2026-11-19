"""Prints the hash of everything the gpu-graphics image is built from: remote/modules/** (module scripts, lib/) and
images/gpu-graphics/** (this folder: Dockerfile, install-modules.sh). Recorded with the image's digest in bin/lib.sh
(RUNPOD_IMAGE_GRAPHICS_SOURCE); tests/run.sh fails when they differ, so a changed module never runs from a stale image.

usage: python -I images/gpu-graphics/modules-hash.py [<repository root>]
"""
import hashlib
import os
import sys

root = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
h = hashlib.sha256()
for top in ("remote/modules", "images/gpu-graphics"):
    base = os.path.join(root, top)
    files = []
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = sorted(d for d in dirnames if d != "__pycache__")
        files += [os.path.join(dirpath, f) for f in filenames if not f.endswith(".pyc")]
    for path in sorted(files, key=lambda p: os.path.relpath(p, root).replace(os.sep, "/")):
        rel = os.path.relpath(path, root).replace(os.sep, "/")
        with open(path, "rb") as f:
            data = f.read().replace(b"\r\n", b"\n")   # the same hash on a Windows checkout
        h.update(rel.encode() + b"\0" + hashlib.sha256(data).digest())
print(h.hexdigest()[:16])
