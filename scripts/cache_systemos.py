#!/usr/bin/env python3
"""Validate and atomically cache an encrypted or decrypted SystemOS image."""

import argparse
from pathlib import Path
import plistlib
import signal
import subprocess
import tempfile
import os
import sys


def validate_image(image):
    if not image.is_file() or image.stat().st_size == 0:
        raise ValueError(f"Missing or empty disk image: {image}")
    result = subprocess.run(["hdiutil", "imageinfo", "-plist", str(image)],
                            capture_output=True, check=True)
    info = plistlib.loads(result.stdout)
    if info.get("Properties", {}).get("Encrypted", False):
        raise ValueError(f"Disk image is still encrypted: {image}")
    layout = info["partitions"]
    block_size = layout["block-size"]
    total = info["Size Information"]["Total Bytes"]
    if block_size <= 0 or total <= 0:
        raise ValueError(f"Invalid disk image size: {image}")
    recognized = False
    for partition in layout["partitions"]:
        start, length = partition["partition-start"], partition["partition-length"]
        if start < 0 or length < 0 or (start + length) * block_size > total:
            raise ValueError(f"Disk image partition exceeds image size: {image}")
        filesystems = partition.get("partition-filesystems", {})
        if (length > 0 and partition.get("partition-hint") in ("Apple_APFS", "Apple_HFS")
                and any(name in filesystems for name in ("APFS", "HFS+", "HFSX", "HFS"))):
            recognized = True
    # hdiutil accepts arbitrary sector-aligned bytes as CRawDiskImage. Its exit
    # status alone therefore cannot distinguish an image from invalid input.
    if not recognized:
        raise ValueError(f"No recognized APFS/HFS partition in disk image: {image}")


def cache_systemos(source, cache):
    if cache.is_symlink() or (cache.exists() and not cache.is_file()):
        raise ValueError(f"Cache must be a regular file, not a symlink or directory: {cache}")
    if cache.exists():
        try:
            validate_image(cache)
        except (ValueError, KeyError, TypeError, subprocess.CalledProcessError):
            print(f"Rebuilding invalid SystemOS cache: {cache}", flush=True)
        else:
            print(f"Using validated SystemOS cache: {cache}", flush=True)
            return
    if not source.is_file():
        raise ValueError(f"Missing SystemOS input: {source}")
    with source.open("rb") as stream:
        encrypted = stream.read(4) == b"AEA1"
    cache.parent.mkdir(parents=True, exist_ok=True)
    # The staging directory is on the destination filesystem. A failed command
    # cannot publish a partial file under the reusable cache name.
    with tempfile.TemporaryDirectory(prefix=".systemos-", dir=cache.parent) as temp:
        staged = Path(temp) / "SystemOS.dmg"
        if encrypted:
            print("Decrypting AEA SystemOS into temporary cache...", flush=True)
            key = subprocess.run(["ipsw", "fw", "aea", "--key", str(source)],
                                 capture_output=True, text=True, check=True).stdout.strip()
            if not key:
                raise ValueError("ipsw returned an empty AEA key")
            # Avoid printing either the key or a CalledProcessError containing it.
            subprocess.run(["aea", "decrypt", "-i", str(source), "-o", str(staged),
                            "-key-value", key], capture_output=True, check=True)
        else:
            # hdiutil uses the extension when selecting a decoder: a decrypted
            # APFS image still named *.aea must first be staged under *.dmg.
            print("Copying decrypted SystemOS into temporary cache...", flush=True)
            subprocess.run(["cp", str(source), str(staged)], check=True)
        validate_image(staged)
        os.replace(staged, cache)
    print(f"SystemOS cache ready: {cache}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("cache", type=Path)
    args = parser.parse_args()

    def interrupted(signum, _frame):
        raise InterruptedError(f"Interrupted by signal {signum}")

    signal.signal(signal.SIGTERM, interrupted)
    try:
        cache_systemos(args.source.absolute(), args.cache.absolute())
    except subprocess.CalledProcessError as error:
        print(f"SystemOS cache failed: {Path(error.cmd[0]).name} exited {error.returncode}",
              file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, TypeError, KeyboardInterrupt) as error:
        print(f"SystemOS cache failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
