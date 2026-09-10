#!/usr/bin/env python3
"""Fetch/stage the fixed 26.1 C3 non-less boot-chain acceptance inputs.

This does not run the patcher, build a complete restore image, mount disks, or
access existing VMs. Run `fetch`, then `stage NEW_RUN_NAME`; fetch is exclusive
and never replaces an existing stock directory (including an incomplete one).
"""
import argparse
import base64
import datetime
import hashlib
import io
import json
import pathlib
import plistlib
import re
import shutil
import subprocess
import urllib.request
import zipfile
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "research/artifacts/c3-full-pipeline-2026-09-10"
CATALOG = ROOT / "sources/VPhoneCore/VPhoneFirmwareCatalog.swift"
BOOTER = pathlib.Path("/System/Library/Frameworks/Virtualization.framework/Versions/A/Resources/AVPBooter.vresearch1.bin")
TXM = "Firmware/txm.iphoneos.research.im4p"
CLOUD_MEMBERS = [
    "Firmware/dfu/iBSS.vresearch101.RELEASE.im4p",
    "Firmware/dfu/iBEC.vresearch101.RELEASE.im4p",
    "Firmware/all_flash/LLB.vresearch101.RELEASE.im4p",
    "Firmware/all_flash/DeviceTree.vphone600ap.im4p",
    "kernelcache.research.vphone600",
    "BuildManifest.plist",
    "SystemVersion.plist",
]
VARIANTS = ("regular", "dev", "jb", "exp")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    with path.open("x") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")


class RemoteZIP(io.RawIOBase):
    def __init__(self, url):
        self.url, self.pos = url, 0
        request = urllib.request.Request(url, method="HEAD", headers={"Accept-Encoding": "identity"})
        with urllib.request.urlopen(request, timeout=60) as response:
            self.size = int(response.headers["Content-Length"])
            self.etag = response.headers.get("ETag")
        if self.size <= 0:
            raise ValueError("Empty archive")

    def seekable(self):
        return True

    def readable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, offset, whence=0):
        if whence not in (0, 1, 2):
            raise ValueError("Invalid whence")
        position = (0, self.pos, self.size)[whence] + offset
        if position < 0:
            raise ValueError("Negative seek")
        self.pos = position
        return position

    def read(self, size=-1):
        size = min(self.size - self.pos, size if size >= 0 else self.size)
        if size <= 0:
            return b""
        start, end = self.pos, self.pos + size - 1
        headers = {"Range": f"bytes={start}-{end}", "Accept-Encoding": "identity"}
        if self.etag and not self.etag.startswith("W/"):
            headers["If-Match"] = self.etag
        request = urllib.request.Request(self.url, headers=headers)
        with urllib.request.urlopen(request, timeout=120) as response:
            expected = f"bytes {start}-{end}/{self.size}"
            if response.status != 206 or response.headers.get("Content-Range") != expected:
                raise ValueError(f"Invalid Range response: {response.status} {response.headers.get('Content-Range')}")
            if self.etag and response.headers.get("ETag") not in (None, self.etag):
                raise ValueError("Archive ETag changed")
            data = response.read(size + 1)
        if len(data) != size:
            raise ValueError(f"Range length mismatch: {len(data)} != {size}")
        self.pos += size
        return data


def extract(archive, member, destination, url):
    matches = [info for info in archive.infolist() if info.filename == member]
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one ZIP member: {member}")
    info = matches[0]
    data = archive.read(info)  # zipfile also checks the member CRC.
    if len(data) != info.file_size or zlib.crc32(data) != info.CRC:
        raise ValueError(f"ZIP integrity mismatch: {member}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("xb") as stream:
        stream.write(data)
    print(f"Fetched {member}: {len(data)} bytes", flush=True)
    return {"url": url, "member": member, "crc32": f"{info.CRC:08x}",
            "compressed_bytes": info.compress_size, "bytes": len(data),
            "sha256": sha(data), "path": str(destination.relative_to(OUTPUT))}


def verify_version(path):
    value = plistlib.loads(path.read_bytes())
    actual = (value.get("ProductVersion"), value.get("ProductBuildVersion"))
    if actual != ("26.1", "23B85"):
        raise ValueError(f"Unexpected firmware identity in {path}: {actual}")


def fetch():
    catalog = CATALOG.read_text()
    cloud = re.search(r'static let cloud261 = "([^"]+)"', catalog)
    iphone = re.search(r'iosName: "iOS 26\.1", iosURL: "([^"]+)", cloudosName: "cloudOS 26\.1", cloudosURL: cloud261', catalog)
    if not cloud or not iphone:
        raise ValueError("Fixed 26.1 pairing is missing from catalog")
    urls = {"cloudos": cloud[1], "iphone": iphone[1]}
    if not urls["iphone"].endswith("/iPhone17,3_26.1_23B85_Restore.ipsw"):
        raise ValueError("Unexpected iPhone archive")
    for url in urls.values():
        if not url.startswith("https://updates.cdn-apple.com/"):
            raise ValueError("Unexpected source domain")
    if not BOOTER.is_file():
        raise FileNotFoundError(BOOTER)
    stock = OUTPUT / "stock"
    stock.mkdir(parents=True, exist_ok=False)
    records = []
    cloud_has_txm = False
    for source, url in urls.items():
        with RemoteZIP(url) as remote, zipfile.ZipFile(remote) as archive:
            members = CLOUD_MEMBERS.copy() if source == "cloudos" else ["BuildManifest.plist", TXM]
            if source == "cloudos":
                cloud_has_txm = TXM in archive.namelist()
                if cloud_has_txm:
                    members.append(TXM)
            for member in members:
                records.append(extract(archive, member, stock / source / member, url))
        verify_version(stock / source / "BuildManifest.plist")
    verify_version(stock / "cloudos/SystemVersion.plist")
    booter_data = BOOTER.read_bytes()
    with (stock / BOOTER.name).open("xb") as stream:
        stream.write(booter_data)
    records.append({"source_path": str(BOOTER), "bytes": len(booter_data),
                    "sha256": sha(booter_data), "path": f"stock/{BOOTER.name}"})
    txm_source = "cloudos" if cloud_has_txm else "iphone"
    txm_equal = (sha((stock / "cloudos" / TXM).read_bytes()) == sha((stock / "iphone" / TXM).read_bytes())) if cloud_has_txm else None
    write_json(stock / "sources.json", {
        "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "scope": "26.1/23B85 pair; non-less boot-chain pipeline only; no full restore-image validity claim",
        "catalog_sha256": sha(CATALOG.read_bytes()), "urls": urls,
        "host_sw_vers": subprocess.check_output(["/usr/bin/sw_vers"], text=True),
        "txm_source": txm_source, "cloudos_txm_present": cloud_has_txm,
        "cloudos_iphone_txm_sha256_equal": txm_equal, "files": records,
    })


def stage(name):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", name):
        raise ValueError("Run name must use 1–64 letters, digits, underscores or hyphens")
    stock = OUTPUT / "stock"
    if stock.resolve() != stock or (OUTPUT / "runs").resolve() != OUTPUT / "runs":
        raise ValueError("Stock and runs paths must not contain symlinks")
    provenance = json.loads((stock / "sources.json").read_text())
    for record in provenance["files"]:
        source = OUTPUT / record["path"]
        if not source.resolve().is_relative_to(stock.resolve()):
            raise ValueError("Source path escaped stock directory")
        data = source.read_bytes()
        if len(data) != record["bytes"] or sha(data) != record["sha256"]:
            raise ValueError(f"Stock input changed: {source}")
    if provenance["txm_source"] not in ("cloudos", "iphone"):
        raise ValueError("Invalid TXM source")
    run = OUTPUT / "runs" / name
    run.mkdir(parents=True, exist_ok=False)
    for variant in VARIANTS:
        vm = run / variant / "vm"
        restore = vm / "iPhone17,3_26.1_23B85_Restore"
        restore.mkdir(parents=True)
        for member in CLOUD_MEMBERS:
            destination = restore / member
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(stock / "cloudos" / member, destination)
        shutil.copyfile(stock / "iphone/BuildManifest.plist", restore / "iPhone-BuildManifest.plist")
        shutil.copyfile(stock / provenance["txm_source"] / TXM, restore / TXM)
        shutil.copyfile(stock / BOOTER.name, vm / BOOTER.name)
    write_json(run / "staging.json", {"variants": VARIANTS, "sources_sha256": sha((stock / "sources.json").read_bytes()),
                                    "txm_source": provenance["txm_source"], "patcher_executed": False})
    print(run)



def payload(path, allow_raw=False):
    import pyimg4
    data = path.read_bytes()
    try:
        container = pyimg4.IM4P(data)
    except Exception:
        if allow_raw and b"IM4P" not in data[:16]:
            return data
        raise
    if container.payload.compression != pyimg4.Compression.NONE:
        container.payload.decompress()
    return bytes(container.payload.output().data)


def verify(name):
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", name):
        raise ValueError("Invalid run name")
    stock, run = OUTPUT / "stock", OUTPUT / "runs" / name
    if stock.resolve() != stock or run.resolve() != run:
        raise ValueError("Verification paths must not contain symlinks")
    output = run / "verification.json"
    if output.exists():
        raise FileExistsError(output)
    sources_data = (stock / "sources.json").read_bytes()
    sources = json.loads(sources_data)
    staging = json.loads((run / "staging.json").read_text())
    if staging["sources_sha256"] != sha(sources_data):
        raise ValueError("Provenance changed after staging")
    for record in sources["files"]:
        path = OUTPUT / record["path"]
        if not path.resolve().is_relative_to(stock.resolve()):
            raise ValueError("Source escaped stock directory")
        data = path.read_bytes()
        if len(data) != record["bytes"] or sha(data) != record["sha256"]:
            raise ValueError(f"Stock input changed: {path}")
    if sources["txm_source"] not in ("cloudos", "iphone"):
        raise ValueError("Invalid TXM source")
    mapping = {
        "AVPBooter": (stock / BOOTER.name, BOOTER.name),
        "iBSS": (stock / "cloudos" / CLOUD_MEMBERS[0], CLOUD_MEMBERS[0]),
        "iBEC": (stock / "cloudos" / CLOUD_MEMBERS[1], CLOUD_MEMBERS[1]),
        "LLB": (stock / "cloudos" / CLOUD_MEMBERS[2], CLOUD_MEMBERS[2]),
        "DeviceTree": (stock / "cloudos" / CLOUD_MEMBERS[3], CLOUD_MEMBERS[3]),
        "kernelcache": (stock / "cloudos" / CLOUD_MEMBERS[4], CLOUD_MEMBERS[4]),
        "TXM": (stock / sources["txm_source"] / TXM, TXM),
    }
    result = {"scope": sources["scope"], "verification_scope": "Six binary components: complete record replay. DeviceTree: hashes only; requires separate serialized-tree parity.", "sources_sha256": sha(sources_data), "variants": {}}
    for variant in VARIANTS:
        report_path = run / variant / "report.json"
        subprocess.run([str(ROOT / ".venv/bin/python3"), str(ROOT / "scripts/check_patch_report.py"), str(report_path)], check=True, cwd=ROOT)
        report_data = report_path.read_bytes()
        report = json.loads(report_data)
        if report["variant"] != variant:
            raise ValueError("Report variant mismatch")
        vm = run / variant / "vm"
        restore = vm / "iPhone17,3_26.1_23B85_Restore"
        buffers = {key: bytearray(payload(value[0], key == "AVPBooter")) for key, value in mapping.items()}
        counts = dict.fromkeys(mapping, 0)
        seen = set()
        for component in report["components"]:
            key = component["component"]
            if key not in buffers:
                raise ValueError(f"Unexpected report component: {key}")
            seen.add(key)
            if key == "DeviceTree":
                counts[key] += len(component["records"])
                continue
            buffer = buffers[key]
            for record in component["records"]:
                offset = record["fileOffset"]
                before = base64.b64decode(record["originalBytes"], validate=True)
                after = base64.b64decode(record["patchedBytes"], validate=True)
                if type(offset) is not int or offset < 0 or offset + len(before) > len(buffer):
                    raise ValueError(f"Invalid record range: {variant}/{key}")
                if len(before) != len(after) or bytes(buffer[offset:offset + len(before)]) != before:
                    raise ValueError(f"Original bytes mismatch: {variant}/{key}/{record['patchID']} at {offset}")
                buffer[offset:offset + len(before)] = after
                counts[key] += 1
        if seen != set(mapping):
            raise ValueError(f"Missing report components: {set(mapping) - seen}")
        checks = {}
        for key, (_, relative) in mapping.items():
            final_path = (vm if key == "AVPBooter" else restore) / relative
            final = payload(final_path, key == "AVPBooter")
            if key != "DeviceTree" and bytes(buffers[key]) != final:
                raise ValueError(f"Final payload differs from record replay: {variant}/{key}")
            checks[key] = {"records": counts[key], "payload_bytes": len(final), "payload_sha256": sha(final), "file_sha256": sha(final_path.read_bytes()), "verification": "requires separate serialized-tree parity" if key == "DeviceTree" else "complete record replay passed"}
        unchanged = {}
        for source, relative in [(stock / "cloudos/BuildManifest.plist", "BuildManifest.plist"),
                                 (stock / "iphone/BuildManifest.plist", "iPhone-BuildManifest.plist"),
                                 (stock / "cloudos/SystemVersion.plist", "SystemVersion.plist")]:
            if source.read_bytes() != (restore / relative).read_bytes():
                raise ValueError(f"Unpatched input changed: {variant}/{relative}")
            unchanged[relative] = sha(source.read_bytes())
        result["variants"][variant] = {"report_sha256": sha(report_data), "components": checks, "unchanged_inputs": unchanged, "binary_replay_passed": True, "devicetree_parity_verified": False}
    write_json(output, result)
    print(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("fetch", help="Download exact ZIP members into new stock directory")
    commands.add_parser("stage", help="Stage stock into a new isolated run").add_argument("run_name")
    commands.add_parser("verify", help="Verify six binary record replays; record DT hashes for separate parity").add_argument("run_name")
    args = parser.parse_args()
    # Reject redirected artifact roots so the fixed output cannot target a VM.
    if OUTPUT.resolve() != OUTPUT:
        raise ValueError("Output path must not contain symlinks")
    if args.action == "fetch":
        fetch()
    elif args.action == "stage":
        stage(args.run_name)
    else:
        verify(args.run_name)


if __name__ == "__main__":
    main()
