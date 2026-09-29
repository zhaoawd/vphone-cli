#!/usr/bin/env python3
"""Build offline comparison fixtures from a pinned PCC IPSW and Python oracle.

Run with the project .venv. The historical Python patchers are exported into a
temporary directory, never restored to the production scripts directory.
"""

import argparse
import hashlib
import importlib.metadata
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
REFERENCE_REVISION = "08eb9d260f6494549220c3109eafd18da9fa75f4"
PCC_SHA256 = "399b664dd623358c3de118ffc114e42dcd51c9309e751d43bc949b98f4e31349"
COMPONENTS = {
    "ibss": "Firmware/dfu/iBSS.vresearch101.RELEASE.im4p",
    "ibec": "Firmware/dfu/iBEC.vresearch101.RELEASE.im4p",
    "llb": "Firmware/all_flash/LLB.vresearch101.RELEASE.im4p",
    "txm": "Firmware/txm.iphoneos.research.im4p",
    "kernelcache": "kernelcache.research.vphone600",
}


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def export_reference_sources(destination):
    paths = subprocess.check_output(
        ["git", "ls-tree", "-r", "--name-only", REFERENCE_REVISION, "scripts"],
        cwd=ROOT, text=True,
    ).splitlines()
    sources = {}
    for name in paths:
        if not name.endswith(".py"):
            continue
        relative = Path(name).relative_to("scripts")
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        data = subprocess.check_output(["git", "show", f"{REFERENCE_REVISION}:{name}"], cwd=ROOT)
        target.write_bytes(data)
        sources[name] = hashlib.sha256(data).hexdigest()
    return sources


def run_reference(source, fixture, component):
    sys.path.insert(0, str(source))
    import export_patch_reference as regular
    import export_patch_reference_all as variants

    output = str(fixture / "reference_patches")
    if component == "avpbooter":
        # Record the actual legacy entrypoint's writes. Its old export helper
        # used a different AVP anchor, so it is not the oracle for this input.
        from fw_patch import patch_avpbooter

        class RecordedBytes(bytearray):
            def __init__(self, data):
                super().__init__(data)
                self.records = []

            def __setitem__(self, key, value):
                if not isinstance(key, slice) or key.step is not None or key.start is None:
                    raise ValueError("Unexpected legacy AVP write")
                if key.stop - key.start != len(value):
                    raise ValueError("Legacy AVP write resized the input")
                self.records.append((key.start, bytes(value), "Legacy AVPBooter DGST bypass"))
                super().__setitem__(key, value)

        data = RecordedBytes((fixture / "raw_payloads/avpbooter.bin").read_bytes())
        if not patch_avpbooter(data) or not data.records:
            raise RuntimeError("Legacy AVPBooter patch did not match")
        (fixture / "reference_patches/avpbooter.json").write_text(
            json.dumps(regular.patches_to_json(data.records, "avpbooter"), indent=2) + "\n"
        )
    elif component == "iboot":
        from patchers.iboot import IBootPatcher

        # Match fw_patch.py's explicit labels, not the legacy export helper's
        # uppercase constructor defaults.
        for mode, label in (("ibss", "Loaded iBSS"), ("ibec", "Loaded iBEC"), ("llb", "Loaded LLB")):
            data = bytearray((fixture / f"raw_payloads/{mode}.bin").read_bytes())
            patcher = IBootPatcher(data, mode=mode, label=label, verbose=True)
            records = regular.patches_to_json(patcher.find_all(), mode)
            (fixture / f"reference_patches/{mode}.json").write_text(json.dumps(records, indent=2) + "\n")
    else:
        functions = {
            "txm": regular.export_txm,
            "kernel": regular.export_kernel,
            "txm_dev": variants.export_txm_dev,
            "ibss_jb": variants.export_iboot_jb,
            "kernel_jb": variants.export_kernel_jb,
        }
        functions[component](str(fixture), output)


def prepare(ipsw, avp, output):
    from pyimg4 import IM4P

    if output.exists() or output.is_symlink():
        raise ValueError(f"Refusing to overwrite fixture directory: {output}")
    if digest(ipsw) != PCC_SHA256:
        raise ValueError("This reference baseline requires PCC 26.1 / 23B85 with the pinned SHA-256")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".fixtures-", dir=output.parent) as temp:
        work = Path(temp)
        stage = work / "fixture"
        (stage / "raw_payloads").mkdir(parents=True)
        (stage / "reference_patches").mkdir()
        with zipfile.ZipFile(ipsw) as archive:
            manifest_data = archive.read("BuildManifest.plist")
            manifest = plistlib.loads(manifest_data)
            if (manifest.get("ProductVersion"), manifest.get("ProductBuildVersion")) != ("26.1", "23B85"):
                raise ValueError("Unexpected PCC manifest")
            (stage / "BuildManifest.plist").write_bytes(manifest_data)
            for name, member in COMPONENTS.items():
                data = archive.read(member)
                target = stage / member
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
                payload = IM4P(data).payload
                if payload.compression:
                    payload.decompress()
                (stage / f"raw_payloads/{name}.bin").write_bytes(payload.data)
        shutil.copyfile(avp, stage / "AVPBooter.vresearch1.bin")
        shutil.copyfile(avp, stage / "raw_payloads/avpbooter.bin")
        source = work / "python-reference"
        sources = export_reference_sources(source)
        for component in ("avpbooter", "iboot", "txm", "kernel", "txm_dev", "ibss_jb", "kernel_jb"):
            print(f"Generating Python reference: {component}", flush=True)
            subprocess.run(
                [sys.executable, str(Path(__file__).resolve()), "--worker", str(source), str(stage), component],
                check=True, timeout=1800,
            )
        from run_tests import FIRMWARE_FILES
        for name in FIRMWARE_FILES:
            path = stage / name
            if not path.is_file() or not path.stat().st_size:
                raise RuntimeError(f"Missing generated fixture: {name}")
            if path.suffix == ".json":
                records = json.loads(path.read_text())
                if not records or (isinstance(records, dict) and not all(records.values())):
                    raise RuntimeError(f"Empty Python reference: {name}")
        provenance = {
            "reference_revision": REFERENCE_REVISION,
            "reference_entrypoints": {"avpbooter": "fw_patch.patch_avpbooter", "iboot_labels": ["Loaded iBSS", "Loaded iBEC", "Loaded LLB"]},
            "reference_sources_sha256": sources,
            "pcc_ipsw": {"path": str(ipsw), "sha256": PCC_SHA256},
            "avpbooter": {"path": str(avp), "sha256": digest(avp)},
            "version": manifest["ProductVersion"], "build": manifest["ProductBuildVersion"],
            "packages": {name: importlib.metadata.version(name) for name in ("pyimg4", "capstone", "keystone-engine")},
            "files": {name: {"sha256": digest(stage / name), "bytes": (stage / name).stat().st_size} for name in FIRMWARE_FILES},
        }
        (stage / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
        # Output is a new, exclusive directory; never merge partial reference data.
        output.mkdir()
        try:
            for path in stage.iterdir():
                path.rename(output / path.name)
        except BaseException:
            shutil.rmtree(output)
            raise
    print(f"Prepared fixtures: {output}", flush=True)


def main():
    if len(sys.argv) == 5 and sys.argv[1] == "--worker":
        run_reference(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4])
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pcc-ipsw", type=Path, required=True)
    parser.add_argument("--avpbooter", type=Path, default=Path("/System/Library/Frameworks/Virtualization.framework/Versions/A/Resources/AVPBooter.vresearch1.bin"))
    parser.add_argument("--output", type=Path, default=ROOT / "ipsws/patch_refactor_input")
    args = parser.parse_args()
    prepare(args.pcc_ipsw.resolve(), args.avpbooter.resolve(), args.output.absolute())


if __name__ == "__main__":
    main()
