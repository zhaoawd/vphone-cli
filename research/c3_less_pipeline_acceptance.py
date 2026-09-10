#!/usr/bin/env python3
"""Stage one isolated 26.1 less pipeline run; never mounts or patches images.

Run with `prepare`. Existing output is rejected, including partial runs. Large
inputs are APFS clones validated against the original ZIP member size and CRC;
their recorded SHA-256 is local, not a server-provided cryptographic digest.
"""
import argparse
import base64
import hashlib
import json
import pathlib
import plistlib
import subprocess
import sys
import zipfile
import zlib

import c3_full_pipeline_acceptance as common

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "research/artifacts/c3-less-pipeline-2026-09-10"
STOCK = ROOT / "research/artifacts/c3-full-pipeline-2026-09-10/stock"
SOURCE = ROOT / "vm-2607/iPhone17,3_26.1_23B85_Restore"
IPHONE_COMPONENTS = {"OS", "StaticTrustCache", "Ap,SystemVolumeCanonicalMetadata", "SystemVolume"}
CLOUD_COMPONENTS = {
    "LLB", "iBSS", "iBEC", "iBoot", "Ap,RestoreSecurePageTableMonitor",
    "Ap,RestoreTrustedExecutionMonitor", "Ap,SecurePageTableMonitor",
    "Ap,TrustedExecutionMonitor", "DeviceTree", "RestoreDeviceTree", "SEP",
    "RestoreSEP", "KernelCache", "RestoreKernelCache", "RecoveryMode",
    "RestoreRamDisk", "RestoreTrustCache",
}


def digest(path):
    h = hashlib.sha256(); crc = 0; size = 0
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            h.update(block); crc = zlib.crc32(block, crc); size += len(block)
    return size, crc, h.hexdigest()


def safe(root, member):
    relative = pathlib.PurePosixPath(member)
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError(f"Unsafe member: {member}")
    path = root / member
    if path.resolve() != path.absolute():
        raise ValueError(f"Symlink in path: {path}")
    return path


def verify():
    """Read-only checks of firmware and source files; writes only the result JSON."""
    report_path = safe(OUT, "pipeline.report.json")
    subprocess.run([sys.executable, str(ROOT / "scripts/check_patch_report.py"),
                    str(report_path)], check=True, cwd=ROOT)
    report = json.loads(report_path.read_text())
    if report["variant"] != "less":
        raise ValueError("Unexpected variant")
    components = {c["component"].lower(): c for c in report["components"]}
    if len(components) != len(report["components"]) or set(components) != {"ibec", "llb", "devicetree", "filesystem", "manifest"}:
        raise ValueError("Unexpected less component coverage")
    fs, mh = components["filesystem"]["records"], components["manifest"]["records"]
    if len(fs) != 1 or len(mh) != 1:
        raise ValueError("Unexpected artifact record count")
    decode = lambda record, key: base64.b64decode(record[key], validate=True)
    restore = OUT / "vm" / SOURCE.name
    initial = safe(OUT, "hybrid/BuildManifest.plist").read_bytes()
    final = safe(restore, "BuildManifest.plist").read_bytes()
    if (decode(fs[0], "originalBytes") != initial
            or decode(fs[0], "patchedBytes") != decode(mh[0], "originalBytes")
            or decode(mh[0], "patchedBytes") != final):
        raise ValueError("Filesystem/Manifest byte continuity failed")
    staging = json.loads((OUT / "staging.json").read_text())
    if hashlib.sha256(initial).hexdigest() != staging["hybrid_manifest_sha256"]:
        raise ValueError("Initial hybrid manifest changed")
    source_checks = []
    for entry in staging["files"]:
        if entry["reused_from"] is not None:
            path = safe(ROOT, entry["reused_from"])
            size, crc, sha = digest(path)
            if (size, f"{crc:08x}", sha) != (entry["bytes"], entry["zip_crc32"], entry["local_sha256"]):
                raise ValueError(f"Source changed: {path}")
            source_checks.append(entry["reused_from"])
    # Less leaves these original containers unchanged, including unpatched iBoot.
    changed = {"Firmware/dfu/iBEC.vresearch101.RELEASE.im4p",
               "Firmware/all_flash/LLB.vresearch101.RELEASE.im4p",
               "Firmware/all_flash/DeviceTree.vphone600ap.im4p"}
    repackaged = {"Firmware/dfu/iBSS.vresearch101.RELEASE.im4p",
                  "Firmware/txm.iphoneos.research.im4p", "kernelcache.research.vphone600"}
    container_checks = []
    for entry in staging["files"]:
        path = safe(OUT, entry["output"])
        if path.is_relative_to(restore) and str(path.relative_to(restore)) in changed:
            continue
        if path.is_relative_to(restore) and str(path.relative_to(restore)) in repackaged:
            # The production loop saves even empty-factory components. Its loader
            # decodes LZFSE and emits an uncompressed IM4P; verify every payload byte.
            import pyimg4
            if entry["reused_from"] is None:
                raise ValueError("Repackaged component needs retained original input")
            original = safe(ROOT, entry["reused_from"])
            before = pyimg4.IM4P(original.read_bytes()); after = pyimg4.IM4P(path.read_bytes())
            compressions = [str(before.payload.compression), str(after.payload.compression)]
            for container in (before, after):
                if container.payload.compression != pyimg4.Compression.NONE:
                    container.payload.decompress()
            if (before.payload.data != after.payload.data or before.fourcc != after.fourcc
                    or before.description != after.description):
                raise ValueError(f"Empty-factory component payload or identity changed: {path}")
            container_checks.append(dict(path=str(path.relative_to(restore)),
                original_container_sha256=entry["local_sha256"], final_container_sha256=digest(path)[2],
                compression_before_after=compressions, payload_bytes_equal=True,
                payload_sha256=hashlib.sha256(before.payload.data).hexdigest()))
            continue
        if digest(path)[2] != entry["local_sha256"]:
            raise ValueError(f"Unpatched input changed: {path}")
    booter = safe(OUT, "vm/AVPBooter.vresearch1.bin")
    if digest(booter)[2] != staging["booter"]["sha256"]:
        raise ValueError("Less AVPBooter changed")
    retagged = {"RestoreKernelCache", "RestoreDeviceTree", "RestoreSEP", "RestoreLogo",
        "RestoreTrustCache", "RestoreDCP", "Ap,RestoreDCP2", "RestoreTMU", "RestoreCIO",
        "Ap,DCP2", "Ap,RestoreSecureM3Firmware", "Ap,RestoreSecurePageTableMonitor",
        "Ap,RestoreTrustedExecutionMonitor", "Ap,RestorecL4"}

    def tlv(data, offset):
        tag = data[offset]; length = data[offset + 1]; start = offset + 2
        if length & 128:
            count = length & 127
            if not 1 <= count <= 8: raise ValueError("Invalid DER length")
            length = int.from_bytes(data[start:start + count], "big"); start += count
        if start + length > len(data): raise ValueError("Truncated DER")
        return tag, start, start + length

    manifest = plistlib.loads(final)["BuildIdentities"][0]["Manifest"]
    hashes = []
    for name, entry in manifest.items():
        path = safe(restore, entry["Info"]["Path"])
        h = hashlib.sha384()
        if name in retagged:
            data = bytearray(path.read_bytes())
            tag, start, end = tlv(data, 0)
            if tag != 0x30 or end != len(data): raise ValueError("Expected IM4P sequence")
            tag, begin, end = tlv(data, start)
            if tag != 0x16 or data[begin:end] != b"IM4P": raise ValueError("Expected IM4P magic")
            tag, begin, end = tlv(data, end)
            replacement = entry["Info"]["Img4PayloadType"].encode("ascii")
            if tag != 0x16 or end - begin != 4 or len(replacement) != 4:
                raise ValueError("Expected four-byte IM4P payload type")
            data[begin:end] = replacement; h.update(data)
        else:
            with path.open("rb") as stream:
                for block in iter(lambda: stream.read(8 * 1024 * 1024), b""): h.update(block)
        if h.digest() != entry["Digest"]:
            raise ValueError(f"Manifest digest mismatch: {name}")
        hashes.append(dict(component=name, path=entry["Info"]["Path"], bytes=path.stat().st_size,
                           sha384=h.hexdigest(), retagged_for_digest=name in retagged))
    common.write_json(OUT / "verification.json", dict(manifest_hashes=hashes,
        source_files_unchanged=source_checks, artifact_record_byte_continuity=True,
        empty_factory_container_checks=container_checks,
        verification_scope="Read-only component hashes and structured pipeline continuity; no AEA content or seal validation"))
    print("PASS: full less report, artifact byte continuity, all manifest digests and retained sources")


def prepare():
    if OUT.exists() or OUT.resolve() != OUT or SOURCE.resolve() != SOURCE:
        raise ValueError("Output exists or staging/source path contains a symlink")
    provenance = json.loads((STOCK / "sources.json").read_text())
    urls = provenance["urls"]
    if any(not u.startswith("https://updates.cdn-apple.com/") for u in urls.values()):
        raise ValueError("Unexpected source host")
    OUT.mkdir(parents=True, exist_ok=False)
    vm = OUT / "vm"; restore = vm / SOURCE.name
    restore.mkdir(parents=True)
    records = []
    archives = {}; remotes = []
    try:
        for source in ("iphone", "cloudos"):
            remote = common.RemoteZIP(urls[source]); remotes.append(remote)
            archives[source] = zipfile.ZipFile(remote)

        def stage(source, member, destination):
            archive = archives[source]
            matches = [x for x in archive.infolist() if x.filename == member]
            if len(matches) != 1:
                raise ValueError(f"Nonunique or missing member: {source}:{member}")
            info = matches[0]
            destination = safe(OUT, str(destination.relative_to(OUT)))
            destination.parent.mkdir(parents=True, exist_ok=True)
            candidates = [safe(STOCK / source, member), safe(SOURCE, member)]
            reused = None
            for candidate in candidates:
                if candidate.is_file() and candidate.stat().st_size == info.file_size:
                    size, crc, sha = digest(candidate)
                    if crc == info.CRC:
                        subprocess.run(["/bin/cp", "-c", str(candidate), str(destination)], check=True)
                        if digest(destination) != (size, crc, sha):
                            raise ValueError("Clone integrity mismatch")
                        reused = str(candidate.relative_to(ROOT)); break
            if reused is None:
                if info.file_size > 512 * 1024 * 1024:
                    raise ValueError(f"Large local input does not match original ZIP; refusing download: {member}")
                data = archive.read(info)
                with destination.open("xb") as stream:
                    stream.write(data)
            size, crc, sha = digest(destination)
            if size != info.file_size or crc != info.CRC:
                raise ValueError(f"ZIP member integrity mismatch: {member}")
            records.append(dict(source=source, url=urls[source], member=member,
                bytes=size, zip_crc32=f"{crc:08x}", local_sha256=sha,
                reused_from=reused, output=str(destination.relative_to(OUT)),
                evidence="original ZIP central-directory length and CRC32; SHA256 computed locally"))

        for source in ("iphone", "cloudos"):
            for name in ("BuildManifest.plist", "Restore.plist"):
                stage(source, name, OUT / "original" / source / name)
            p = plistlib.loads((OUT / "original" / source / "BuildManifest.plist").read_bytes())
            if (p["ProductVersion"], p["ProductBuildVersion"]) != ("26.1", "23B85"):
                raise ValueError("Unexpected fixed firmware pair")

        # Generate the production hybrid using pristine source plists in a separate directory.
        hybrid = OUT / "hybrid"; hybrid.mkdir()
        for name in ("BuildManifest.plist", "Restore.plist"):
            (hybrid / name).write_bytes((OUT / "original/iphone" / name).read_bytes())
        subprocess.run([sys.executable, str(ROOT / "scripts/fw_manifest.py"),
                        str(hybrid), str(OUT / "original/cloudos")], check=True)
        manifest = plistlib.loads((hybrid / "BuildManifest.plist").read_bytes())
        components = manifest["BuildIdentities"][0]["Manifest"]
        if set(components) != IPHONE_COMPONENTS | CLOUD_COMPONENTS:
            raise ValueError("Production component mapping changed; review source ownership")
        ownership = {}
        for name, component in components.items():
            source = "iphone" if name in IPHONE_COMPONENTS else "cloudos"
            member = component["Info"]["Path"]
            if member in ownership and ownership[member] != source:
                raise ValueError("Conflicting component sources")
            ownership[member] = source
        iphone = plistlib.loads((OUT / "original/iphone/BuildManifest.plist").read_bytes())
        for name in ("Cryptex1,AppOS", "Cryptex1,SystemOS"):
            ownership[iphone["BuildIdentities"][0]["Manifest"][name]["Info"]["Path"]] = "iphone"
        for member, source in ownership.items():
            stage(source, member, restore / member)
        for name in ("BuildManifest.plist", "Restore.plist"):
            (restore / name).write_bytes((hybrid / name).read_bytes())
        (restore / "iPhone-BuildManifest.plist").write_bytes((OUT / "original/iphone/BuildManifest.plist").read_bytes())
        stage("cloudos", "SystemVersion.plist", restore / "SystemVersion.plist")
        booter = STOCK / "AVPBooter.vresearch1.bin"
        expected = next(r for r in provenance["files"] if r["path"] == "stock/AVPBooter.vresearch1.bin")
        if digest(booter)[2] != expected["sha256"]:
            raise ValueError("AVPBooter stock changed")
        (vm / booter.name).write_bytes(booter.read_bytes())
        common.write_json(OUT / "staging.json", dict(files=records, booter=expected,
            source_vm_modified=False, patcher_executed=False,
            source_mapping={name: "iphone" if name in IPHONE_COMPONENTS else "cloudos" for name in components},
            hybrid_manifest_sha256=digest(restore / "BuildManifest.plist")[2]))
        print(vm)
    finally:
        for archive in archives.values(): archive.close()
        for remote in remotes: remote.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["prepare", "verify"])
    args = parser.parse_args()
    prepare() if args.command == "prepare" else verify()
