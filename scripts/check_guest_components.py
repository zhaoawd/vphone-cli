#!/usr/bin/env python3
"""Check fixed-source guest component candidates; never install or activate them."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PINS = ROOT / "dependencies/guest-components-pins.json"
ARTIFACTS = {
    "camfix/libcamfix.dylib": "26.0",
    "locationfix/libvlocation.dylib": "26.0",
    "vcamcaptured/libvcamcaptured.dylib": "26.0",
    "launchhook/launchdhook-vphone.dylib": "26.0",
    "systemhook/SystemHook-vphone.dylib": "26.0",
    "gpu/libAppleParavirtCompilerPluginIOGPUFamily.dylib": "26.1",
}
RESOURCES = ("camfix/libcamfix.plist", "vcamcaptured/libvcamcaptured.plist", "gpu/README.md")


def digest(path):
    if path.is_symlink() or not path.is_file() or not path.stat().st_size:
        raise ValueError(f"Expected a nonempty regular file: {path}")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def check_sources(pins, root=ROOT):
    for entry in pins["files"]:
        if digest(root / entry["local"]) != entry.get("local_sha256", entry["upstream_sha256"]):
            raise ValueError(f"Guest component source differs from its recorded input: {entry['local']}")


def output(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def inspect(stage, pins):
    if stage.is_symlink() or not stage.is_dir():
        raise ValueError("Candidate stage must be a real directory")
    hashes = {}
    for name in (*ARTIFACTS, *RESOURCES):
        path = stage / name
        if path.parent.is_symlink():
            raise ValueError(f"Candidate parent is a symlink: {path.parent}")
        hashes[name] = digest(path)
    for name, minimum in ARTIFACTS.items():
        path = str(stage / name)
        if output("/usr/bin/lipo", "-archs", path).strip() != "arm64e":
            raise ValueError(f"Expected arm64e: {name}")
        metadata = output("/usr/bin/xcrun", "vtool", "-show-build", path)
        fields = [line.split() for line in metadata.splitlines()]
        if ["platform", "IOS"] not in fields or ["minos", minimum] not in fields:
            raise ValueError(f"Unexpected platform or deployment target: {name}")
        output("/usr/bin/codesign", "--verify", "--strict", path)
    return {
        "schema_version": 1, "role": "isolated-guest-components-candidate",
        "upstream_revision": pins["upstream_revision"], "architecture": "arm64e",
        "activated": False, "runtime_validated": False,
        "camera_header_bytes": 64, "compatible_with_classic_camera": False,
        "deployment_targets": ARTIFACTS, "files_sha256": hashes,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--stage", type=Path)
    parser.add_argument("--record", action="store_true")
    args = parser.parse_args()
    pins = json.loads(PINS.read_text())
    check_sources(pins)
    if args.stage:
        report = inspect(args.stage, pins)
        manifest = args.stage / "manifest.json"
        if manifest.is_symlink():
            raise ValueError("Manifest must not be a symlink")
        if args.record:
            manifest.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
        elif json.loads(manifest.read_text()) != report:
            raise ValueError("Guest component manifest mismatch")
    print("Guest component checks passed; candidate only, runtime not validated")


if __name__ == "__main__":
    main()
