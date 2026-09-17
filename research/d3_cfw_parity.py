#!/usr/bin/env python3
"""Inventory offline APFS install volumes and compare CFW output bytes."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import struct
import subprocess
import tempfile


ROLES = ("System", "xART", "Preboot")
VARIANTS = ("regular", "dev", "jb", "exp")
PAIR_SIDES = ("legacy", "current")


def command(*args):
    return subprocess.check_output(args)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def pair_input(vm):
    vm = vm.resolve(strict=True)
    disk = vm / "Disk.img"
    config = vm / "config.plist"
    if not disk.is_file() or disk.is_symlink():
        raise ValueError(f"{vm}: Disk.img missing or linked")
    if not config.is_file() or config.is_symlink():
        raise ValueError(f"{vm}: config.plist missing or linked")
    if (vm / ".firmware-transaction").exists():
        raise ValueError(f"{vm}: pending firmware transaction")
    sockets = sorted(path.relative_to(vm).as_posix() for path in vm.rglob("*") if path.is_socket())
    if sockets:
        raise ValueError(f"{vm}: sockets present: {sockets}")
    opened = subprocess.run(["lsof", "-nP", str(disk)], capture_output=True)
    if opened.returncode == 0:
        raise ValueError(f"{vm}: Disk.img is open")
    if opened.returncode not in (1,):
        raise ValueError(f"{vm}: lsof failed with status {opened.returncode}")
    restores = sorted(path for path in vm.iterdir()
                      if path.is_dir() and not path.is_symlink()
                      and path.name.startswith("iPhone") and path.name.endswith("_Restore"))
    if len(restores) != 1:
        raise ValueError(f"{vm}: expected one Restore directory, got {len(restores)}")
    restore = restores[0]
    manifests = {}
    for name in ("BuildManifest.plist", "iPhone-BuildManifest.plist"):
        path = restore / name
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"{vm}: {name} missing or linked")
        manifests[name] = {"bytes": path.stat().st_size, "sha256": sha256(path)}
    return {
        "vm": str(vm),
        "disk_bytes": disk.stat().st_size,
        "config": {"bytes": config.stat().st_size, "sha256": sha256(config)},
        "restore": restore.name,
        "manifests": manifests,
    }


def preflight(root, minimum_free_gib):
    root = root.resolve(strict=True)
    mounts = command("mount").decode(errors="replace").splitlines()
    marker = f" on {root}/"
    mounted = [line for line in mounts if marker in line]
    if mounted:
        raise ValueError(f"mounted filesystem beneath parity root: {mounted}")
    free = shutil.disk_usage(root).free
    minimum = int(minimum_free_gib * 1024 ** 3)
    if free < minimum:
        raise ValueError(f"free space {free} is below required {minimum} bytes")
    pairs = {}
    for variant in VARIANTS:
        sides = {side: pair_input(root / f"vm-{variant}-{side}") for side in PAIR_SIDES}
        legacy, current = sides["legacy"], sides["current"]
        for field in ("disk_bytes", "config", "restore", "manifests"):
            if legacy[field] != current[field]:
                raise ValueError(f"{variant}: paired {field} differs")
        pairs[variant] = sides
    return {
        "root": str(root),
        "minimum_free_bytes": minimum,
        "free_bytes": free,
        "pairs": pairs,
    }


def signature_region(path, length):
    with path.open("rb") as stream:
        header = stream.read(32)
        if len(header) != 32 or header[:4] != bytes.fromhex("cffaedfe"):
            return None
        command_count = struct.unpack_from("<I", header, 16)[0]
        command_bytes = struct.unpack_from("<I", header, 20)[0]
        if command_count > 4096 or command_bytes > 4 * 1024 * 1024:
            return None
        commands = stream.read(command_bytes)
    offset = 0
    for _ in range(command_count):
        if offset + 8 > len(commands):
            return None
        kind, size = struct.unpack_from("<II", commands, offset)
        if size < 8 or offset + size > len(commands):
            return None
        if kind == 0x1D and size >= 16:
            start, count = struct.unpack_from("<II", commands, offset + 8)
            return (start, start + count) if start + count <= length else None
        offset += size
    return None


def file_hashes(path, length):
    signed = hashlib.sha256()
    region = signature_region(path, length)
    unsigned = hashlib.sha256() if region is not None else None
    position = 0
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            signed.update(block)
            if unsigned is not None:
                start, end = region
                block_end = position + len(block)
                if position < start:
                    unsigned.update(block[:max(0, min(start, block_end) - position)])
                if block_end > end:
                    unsigned.update(block[max(0, end - position):])
            position += len(block)
    result = {"sha256": signed.hexdigest()}
    if unsigned is not None:
        result["without_signature_sha256"] = unsigned.hexdigest()
        result["signature_region"] = list(region)
    return result


def scan_tree(root):
    result = {}
    pending = [(root, "")]
    while pending:
        directory, prefix = pending.pop()
        with os.scandir(directory) as entries:
            children = sorted(entries, key=lambda entry: entry.name)
        for child in children:
            relative = f"{prefix}/{child.name}" if prefix else child.name
            path = Path(child.path)
            info = child.stat(follow_symlinks=False)
            mode = stat.S_IMODE(info.st_mode)
            if stat.S_ISDIR(info.st_mode):
                result[relative] = {"type": "directory", "mode": mode}
                pending.append((path, relative))
            elif stat.S_ISLNK(info.st_mode):
                result[relative] = {"type": "symlink", "target": os.readlink(path)}
            elif stat.S_ISREG(info.st_mode):
                result[relative] = {"type": "file", "mode": mode, "bytes": info.st_size,
                                    **file_hashes(path, info.st_size)}
            else:
                result[relative] = {"type": "special", "mode": mode}
    return result


def inventory(vm):
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
            devices = {}
            for role in ROLES:
                matches = [volume["DeviceIdentifier"] for volume in volumes if role in volume.get("Roles", [])]
                if len(matches) != 1:
                    raise ValueError(f"expected one {role} volume, got {matches}")
                devices[role] = matches[0]
            result = {}
            for role, device in devices.items():
                with tempfile.TemporaryDirectory(prefix=f"vphone-d3-{role.lower()}-") as mountpoint:
                    subprocess.run(["diskutil", "mount", "readOnly", "-mountPoint", mountpoint, device],
                                   check=True, stdout=subprocess.DEVNULL)
                    try:
                        result[role] = scan_tree(Path(mountpoint))
                    finally:
                        subprocess.run(["diskutil", "unmount", device], check=True,
                                       stdout=subprocess.DEVNULL)
            return result
        finally:
            subprocess.run(["hdiutil", "detach", base], check=True, stdout=subprocess.DEVNULL)
    finally:
        os.close(fd)


def compare(left, right):
    differences = []
    counts = {}
    for role in ROLES:
        ltree, rtree = left[role], right[role]
        counts[role] = {"legacy": len(ltree), "current": len(rtree)}
        for path in sorted(ltree.keys() | rtree.keys()):
            a, b = ltree.get(path), rtree.get(path)
            if a == b:
                continue
            signature_only = (a is not None and b is not None and a.get("type") == "file"
                              and b.get("type") == "file" and a.get("mode") == b.get("mode")
                              and a.get("bytes") == b.get("bytes")
                              and a.get("signature_region") == b.get("signature_region")
                              and a.get("without_signature_sha256") is not None
                              and a.get("without_signature_sha256") == b.get("without_signature_sha256"))
            differences.append({"role": role, "path": path,
                                "classification": "signature_only" if signature_only else "content_or_metadata",
                                "legacy": a, "current": b})
    return {"counts": counts, "differences": differences}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("preflight")
    check.add_argument("root", type=Path)
    check.add_argument("--minimum-free-gib", type=float, default=80)
    check.add_argument("--output", type=Path, required=True)
    scan = sub.add_parser("scan")
    scan.add_argument("vm", type=Path)
    scan.add_argument("--output", type=Path, required=True)
    diff = sub.add_parser("compare")
    diff.add_argument("legacy", type=Path)
    diff.add_argument("current", type=Path)
    diff.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists() or args.output.is_symlink():
        parser.error("output exists")
    if args.command == "preflight":
        result = preflight(args.root, args.minimum_free_gib)
    elif args.command == "scan":
        result = inventory(args.vm)
    else:
        result = compare(json.loads(args.legacy.read_text()), json.loads(args.current.read_text()))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(f"wrote {args.output}")


if __name__ == "__main__":
    main()
