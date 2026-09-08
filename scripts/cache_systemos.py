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


class InvalidImage(ValueError):
    """Recognized metadata proves that the image is unusable."""


def run_tool(command, secrets=()):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        stdout, stderr = process.communicate()
    except BaseException:
        process.kill()
        process.communicate()
        raise
    result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
    if result.returncode:
        detail = result.stderr.decode(errors="replace").strip()
        for secret in secrets:
            detail = detail.replace(secret, "<redacted>")
        # Never include argv: AEA receives the key as a command-line argument.
        raise RuntimeError(f"{Path(command[0]).name} exited {result.returncode}: {detail}")
    return result


def validate_image(image):
    if not image.is_file() or image.stat().st_size == 0:
        raise InvalidImage(f"Missing or empty disk image: {image}")
    result = run_tool(["hdiutil", "imageinfo", "-plist", str(image)])
    info = plistlib.loads(result.stdout)
    if info.get("Properties", {}).get("Encrypted", False):
        raise InvalidImage(f"Disk image is still encrypted: {image}")
    layout = info["partitions"]
    block_size = layout["block-size"]
    total = info["Size Information"]["Total Bytes"]
    if block_size <= 0 or total <= 0:
        raise InvalidImage(f"Invalid disk image size: {image}")
    recognized = False
    for partition in layout["partitions"]:
        start, length = partition["partition-start"], partition["partition-length"]
        if start < 0 or length < 0 or (start + length) * block_size > total:
            raise InvalidImage(f"Disk image partition exceeds image size: {image}")
        filesystems = partition.get("partition-filesystems", {})
        if (length > 0 and partition.get("partition-hint") in ("Apple_APFS", "Apple_HFS")
                and any(name in filesystems for name in ("APFS", "HFS+", "HFSX", "HFS"))):
            recognized = True
    # hdiutil accepts arbitrary sector-aligned bytes as CRawDiskImage. Its exit
    # status alone therefore cannot distinguish an image from invalid input.
    if not recognized:
        raise InvalidImage(f"No recognized APFS/HFS partition in disk image: {image}")


def cache_systemos(source, cache):
    if cache.is_symlink() or (cache.exists() and not cache.is_file()):
        raise ValueError(f"Cache must be a regular file, not a symlink or directory: {cache}")
    if cache.exists():
        try:
            validate_image(cache)
        except InvalidImage as error:
            print(f"Rebuilding invalid SystemOS cache: {error}", flush=True)
        else:
            print(f"Using SystemOS cache with recognized filesystem metadata (source identity not checked): {cache}", flush=True)
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
            key = run_tool(["ipsw", "fw", "aea", "--key", str(source)]).stdout.decode().strip()
            if not key:
                raise ValueError("ipsw returned an empty AEA key")
            # Avoid printing either the key or a CalledProcessError containing it.
            run_tool(["aea", "decrypt", "-i", str(source), "-o", str(staged),
                      "-key-value", key], secrets=(key,))
        else:
            # hdiutil uses the extension when selecting a decoder: a decrypted
            # APFS image still named *.aea must first be staged under *.dmg.
            print("Copying decrypted SystemOS into temporary cache...", flush=True)
            run_tool(["cp", str(source), str(staged)])
        validate_image(staged)
        os.replace(staged, cache)
    print(f"SystemOS cache ready: {cache}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("cache", type=Path)
    args = parser.parse_args()

    def interrupted(signum, _frame):
        raise RuntimeError(f"Interrupted by signal {signum}")

    signal.signal(signal.SIGTERM, interrupted)
    try:
        cache_systemos(args.source.absolute(), args.cache.absolute())
    except subprocess.CalledProcessError as error:
        print(f"SystemOS cache failed: {Path(error.cmd[0]).name} exited {error.returncode}",
              file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, plistlib.InvalidFileException, KeyboardInterrupt) as error:
        print(f"SystemOS cache failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
