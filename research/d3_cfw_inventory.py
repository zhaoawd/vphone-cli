#!/usr/bin/env python3
"""Read-only inventory of an offline VM's installed CFW files."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


FILES = (
    "usr/libexec/seputil",
    "usr/libexec/seputil.bak",
    "usr/libexec/launchd_cache_loader",
    "usr/libexec/launchd_cache_loader.bak",
    "usr/libexec/mobileactivationd",
    "usr/libexec/mobileactivationd.bak",
    "usr/bin/vphoned",
    "System/Library/LaunchDaemons/vphoned.plist",
)
DIRECTORIES = (
    "System/Cryptexes/OS",
    "System/Cryptexes/App",
    "System/Library/LaunchDaemons",
    "cores",
)


def command(*args):
    return subprocess.check_output(args)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def inspect_mount(root, capture_dir=None):
    files = {}
    for relative in FILES:
        path = root / relative
        files[relative] = (
            {"bytes": path.stat().st_size, "sha256": sha256(path)}
            if path.is_file() else None
        )
        if capture_dir is not None and path.is_file():
            target = capture_dir / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
    directories = {}
    for relative in DIRECTORIES:
        path = root / relative
        directories[relative] = sorted(child.name for child in path.iterdir()) if path.is_dir() else None
    return {"files": files, "directories": directories}


def inventory(vm, capture_dir=None):
    vm = vm.resolve(strict=True)
    disk = vm / "Disk.img"
    if not disk.is_file() or disk.is_symlink() or (vm / ".firmware-transaction").exists():
        raise ValueError("VM disk missing, linked, or has a pending firmware transaction")
    fd = os.open(vm, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if subprocess.run(["lsof", "-nP", str(disk)], capture_output=True).returncode == 0:
            raise ValueError("VM disk is open")
        attached = plistlib.loads(command("hdiutil", "attach", "-readonly", "-nomount", "-plist",
                                           "-imagekey", "diskimage-class=CRawDiskImage", str(disk)))
        physical = [entry["dev-entry"] for entry in attached["system-entities"]
                    if entry.get("content-hint") == "GUID_partition_scheme"]
        if len(physical) != 1:
            raise ValueError(f"expected one physical disk, got {physical}")
        base = physical[0]
        try:
            info = plistlib.loads(command("diskutil", "info", "-plist", base + "s1"))
            container = info["APFSContainerReference"]
            volumes = plistlib.loads(command("diskutil", "apfs", "list", "-plist", container))["Containers"][0]["Volumes"]
            systems = [volume["DeviceIdentifier"] for volume in volumes if "System" in volume.get("Roles", [])]
            if len(systems) != 1:
                raise ValueError(f"expected one System volume, got {systems}")
            system = systems[0]
            with tempfile.TemporaryDirectory(prefix="vphone-d3-inventory-") as mountpoint:
                subprocess.run(["diskutil", "mount", "readOnly", "-mountPoint", mountpoint, system], check=True,
                               stdout=subprocess.DEVNULL)
                try:
                    result = inspect_mount(Path(mountpoint), capture_dir)
                finally:
                    subprocess.run(["diskutil", "unmount", system], check=True, stdout=subprocess.DEVNULL)
            return result
        finally:
            subprocess.run(["hdiutil", "detach", base], check=True, stdout=subprocess.DEVNULL)
    finally:
        os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("vm", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--capture-dir", type=Path)
    args = parser.parse_args()
    if args.output.exists() or args.output.is_symlink():
        parser.error("output exists")
    if args.capture_dir is not None:
        args.capture_dir.mkdir(parents=True, exist_ok=False)
    result = inventory(args.vm, args.capture_dir)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"wrote {args.output}")


if __name__ == "__main__":
    main()
