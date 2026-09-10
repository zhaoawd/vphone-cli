#!/usr/bin/env python3
"""Verify new less AEA contents and its original root hash on an isolated copy.

Requires privileges for image mounts. Never mounts the delivery AEA or source VM.
Creates content-verification exclusively; retains logs/metadata, removes its own
decrypted copy only after successful detach. Does not change expected root hash.
"""
import decimal
import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess

import pyimg4
from c3_less_pipeline_acceptance import ROOT, OUT, SOURCE, safe, digest


def main():
    if os.geteuid() != 0:
        raise PermissionError("Run with privileges for image mounts")
    work = safe(OUT, "content-verification")
    work.mkdir(exist_ok=False)
    restore = OUT / "vm" / SOURCE.name
    manifest = plistlib.loads(safe(restore, "BuildManifest.plist").read_bytes())["BuildIdentities"][0]["Manifest"]
    source = safe(restore, manifest["OS"]["Info"]["Path"])
    expected = safe(restore, manifest["SystemVolume"]["Info"]["Path"])
    source_before = digest(source)
    expected_before = digest(expected)
    log = (work / "commands.log").open("x")

    def run(args):
        log.write(json.dumps(args) + "\n"); log.flush()
        result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        log.write(result.stderr.decode(errors="replace")); log.flush()
        if result.returncode:
            raise RuntimeError(f"Command exited {result.returncode}: {args}")
        return result.stdout

    image = None; device = None; detached = False
    try:
        metadata = safe(restore, manifest["Ap,SystemVolumeCanonicalMetadata"]["Info"]["Path"])
        container = pyimg4.IM4P(metadata.read_bytes())
        if container.fourcc != "msys": raise ValueError("Expected msys")
        aar = work / "metadata.aar"; aar.write_bytes(container.payload.data)
        extracted = work / "metadata"; extracted.mkdir()
        run(["/usr/bin/aa", "extract", "-i", str(aar), "-d", str(extracted)])
        mtree = extracted / "mtree.txt"
        lines = mtree.read_text().splitlines()
        section = lines.index("# ./private/var")
        timestamp = None
        for line in lines[section + 1:]:
            if line.startswith("# ./"): break
            if line.startswith("var "):
                match = re.search(r"\btime=([0-9]+(?:\.[0-9]+)?)", line)
                if match: timestamp = int(decimal.Decimal(match[1]) * 1_000_000_000)
        if timestamp is None: raise ValueError("Missing canonical private/var time")
        remap = work / "remap.plist"
        remap.write_bytes(plistlib.dumps({"MODIFICATION": timestamp}))
        root_hash = pyimg4.IM4P(expected.read_bytes())
        if root_hash.fourcc != "isys": raise ValueError("Expected isys")
        tc = pyimg4.IM4P(safe(restore, manifest["StaticTrustCache"]["Info"]["Path"]).read_bytes())
        if tc.fourcc != "trst": raise ValueError("Expected trst")
        decrypted = work / "decrypted"; decrypted.mkdir()
        run(["/opt/homebrew/bin/ipsw", "fw", "aea", "-o", str(decrypted), str(source)])
        images = list(decrypted.glob("*.dmg"))
        if len(images) != 1: raise ValueError("Expected exactly one decrypted image")
        image = images[0]
        attach = plistlib.loads(run(["/usr/bin/hdiutil", "attach", "-plist", "-nobrowse", "-readwrite", str(image)]))
        entities = attach["system-entities"]
        device = next((e["dev-entry"] for e in entities if e.get("dev-entry")), None)
        volumes = [e for e in entities if e.get("mount-point")]
        if len(volumes) != 1: raise ValueError("Expected one mounted verification volume")
        volume = volumes[0]; device = volume["dev-entry"]
        mount = pathlib.Path(volume["mount-point"])
        run(["/sbin/mount", "-u", "-w", device, str(mount)])
        content = []
        for name in ["usr/bin/vphoned", "usr/libexec/launchd_cache_loader", "usr/libexec/mobileactivationd",
                     "System/Cryptexes/OS/System/Library/Caches/com.apple.dyld", "System/Library/Caches/com.apple.dyld"]:
            path = mount / name
            if not path.exists(): raise ValueError(f"Missing content: {name}")
            entry = dict(path=name, symlink=path.is_symlink())
            if path.is_symlink(): entry["target"] = os.readlink(path)
            elif path.is_file(): entry["sha256"] = digest(path)[2]
            content.append(entry)
        dyld = mount / "System/Library/Caches/com.apple.dyld"
        if not dyld.is_symlink() or os.readlink(dyld) != "../../../System/Cryptexes/OS/System/Library/Caches/com.apple.dyld":
            raise ValueError("Unexpected dyld symlink")
        for name in ["private/var/MobileAsset/PreinstalledAssets", "private/var/MobileAsset/PreinstalledAssetsV2",
                     "private/var/staged_system_apps", ".fseventsd"]:
            path = mount / name
            if path.is_symlink(): raise ValueError(f"Unexpected canonicalization symlink: {name}")
            if path.exists(): shutil.rmtree(path)
        run(["/usr/sbin/diskutil", "unmount", str(mount)])
        seal = ROOT / "research/artifacts/c3-less-2026-09-09/tools/apfs_sealvolume_26.1"
        # No -u digest.db and no -a: independently recompute against original root hash.
        output = run([str(seal), "-R", str(remap), "-P", "-I", str(expected), device])
        (work / "seal-verify.log").write_bytes(output)
        run(["/usr/bin/hdiutil", "detach", device]); detached = True
        if digest(source) != source_before or digest(expected) != expected_before:
            raise ValueError("Delivery artifact changed during verification")
        (work / "result.json").write_text(json.dumps(dict(contents=content, original_root_hash_verified=True,
            digest_db_imported=False, expected_root_hash_sha256=expected_before[2],
            aea_sha256=source_before[2], remap_modification=timestamp), indent=2) + "\n")
    finally:
        if device and not detached:
            try:
                run(["/usr/bin/hdiutil", "detach", device]); detached = True
            except Exception as error:
                log.write(f"Detach failed; preserving decrypted image: {error}\n")
        if image and detached: image.unlink()
        log.close()


if __name__ == "__main__":
    main()
