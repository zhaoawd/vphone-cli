#!/usr/bin/env python3
"""Apply the hash-pinned Capstone detail overlay without replacing other edits."""

import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def prepare_capstone(repository, overlay):
    manifest = json.loads((overlay / "manifest.json").read_text())
    patch = overlay / "arm64-detail.patch"
    digest = lambda data: hashlib.sha256(data).hexdigest()
    if digest(patch.read_bytes()) != manifest["patch_sha256"]:
        raise RuntimeError("Capstone overlay patch hash mismatch")
    source = repository / manifest["file"]
    actual = digest(source.read_bytes())
    if actual == manifest["patched_sha256"]:
        print("Capstone detail overlay: already applied")
        return
    if actual != manifest["base_sha256"]:
        raise RuntimeError("Capstone source differs from pinned base and overlay; preserving local edits")
    subprocess.run(["git", "apply", "--check", str(patch.resolve())], cwd=repository, check=True)
    subprocess.run(["git", "apply", str(patch.resolve())], cwd=repository, check=True)
    if digest(source.read_bytes()) != manifest["patched_sha256"]:
        raise RuntimeError("Capstone overlay result hash mismatch")
    print("Capstone detail overlay: applied")


if __name__ == "__main__":
    prepare_capstone(ROOT / "vendor/libcapstone-spm", ROOT / "dependencies/capstone-overlays")
