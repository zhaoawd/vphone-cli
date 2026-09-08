#!/usr/bin/env python3
"""Opt-in macOS validation using disposable APFS and native AEA images.

Run directly, outside a sandbox that blocks DiskImages services. Only the ipsw
key lookup is replaced: locally encrypted AEA images do not have Apple's FCS key.
This is intentionally not part of firmware-free unittest discovery.
"""

import argparse
import base64
import hashlib
import os
from pathlib import Path
import plistlib
import secrets
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def digest(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--firmware-source", type=Path,
                        help="Decrypt/copy a real SystemOS source into a disposable cache")
    args = parser.parse_args()
    if args.firmware_source:
        with tempfile.TemporaryDirectory(prefix="vphone-systemos-firmware-") as temp:
            output = Path(temp) / "SystemOS.dmg"
            subprocess.run([sys.executable, str(ROOT / "scripts/cache_systemos.py"),
                            str(args.firmware_source.resolve()), str(output)], check=True)
            with output.open("rb") as stream:
                sha256 = hashlib.file_digest(stream, "sha256").hexdigest()
            info = plistlib.loads(subprocess.check_output(["hdiutil", "imageinfo", "-plist", str(output)]))
            print(f"PASS: real SystemOS source; bytes={output.stat().st_size}; sha256={sha256}")
            print(info["partitions"])
        return
    with tempfile.TemporaryDirectory(prefix="vphone-a2-native-") as tmp:
        base = Path(tmp)
        image = base / "apfs.dmg"
        subprocess.run(["hdiutil", "create", "-size", "32m", "-fs", "APFS",
                        "-volname", "VPhoneA2", str(image)], check=True)
        info = plistlib.loads(subprocess.check_output(["hdiutil", "imageinfo", "-plist", str(image)]))
        layout = info["partitions"]
        partition = next(p for p in layout["partitions"] if p.get("partition-hint") == "Apple_APFS")
        block = layout["block-size"]
        raw = base / "decrypted.dmg.aea"
        raw.write_bytes(image.read_bytes()[partition["partition-start"] * block:
                                          (partition["partition-start"] + partition["partition-length"]) * block])
        expected = digest(raw)
        env = os.environ.copy()
        env["A2_NATIVE_KEY"] = "base64:" + base64.b64encode(secrets.token_bytes(32)).decode()
        key_tool = base / "ipsw"
        key_tool.write_text(f"#!{sys.executable}\nimport os\nprint(os.environ['A2_NATIVE_KEY'])\n")
        key_tool.chmod(0o755)
        env["PATH"] = f"{base}:{env['PATH']}"

        def cache(source, destination, success=True):
            result = subprocess.run([sys.executable, str(ROOT / "scripts/cache_systemos.py"),
                                     str(source), str(destination)], env=env, capture_output=True, text=True)
            assert (result.returncode == 0) == success, result.stdout + result.stderr
            if not success:
                assert not destination.exists()
            assert not list(base.glob(".systemos-*"))

        output = base / "cache.dmg"
        cache(raw, output)
        assert digest(output) == expected
        stamp = output.stat().st_mtime_ns
        cache(raw, output)
        assert output.stat().st_mtime_ns == stamp
        print("PASS: decrypted .aea filename; byte-exact copy; cache reuse")

        output.write_bytes(b"partial cache")
        result = subprocess.run([sys.executable, str(ROOT / "scripts/cache_systemos.py"),
                                 str(raw), str(output)], capture_output=True, text=True)
        assert result.returncode != 0
        assert output.read_bytes() == b"partial cache"
        output.unlink()  # Explicitly discard this disposable, known-invalid fixture.
        cache(raw, output)
        assert digest(output) == expected
        print("PASS: unrecognized cache preserved on tool failure; explicit removal permits rebuild")

        encrypted = base / "encrypted.dmg.aea"
        result = subprocess.run(["aea", "encrypt", "-profile", "1", "-i", str(raw),
                                 "-o", str(encrypted), "-key-value", env["A2_NATIVE_KEY"]],
                                capture_output=True)
        assert result.returncode == 0, "Native AEA encryption failed"
        assert encrypted.read_bytes()[:4] == b"AEA1"
        decrypted = base / "decrypted-cache.dmg"
        cache(encrypted, decrypted)
        assert digest(decrypted) == expected
        print("PASS: native AEA decrypt; byte-exact output (test key lookup)")

        for name, data in (("truncated-apfs", raw.read_bytes()[:raw.stat().st_size // 2]),
                           ("invalid-aligned", b"bad!" * 1024),
                           ("empty", b""), ("truncated-aea", encrypted.read_bytes()[:64])):
            source = base / f"{name}.aea"
            source.write_bytes(data)
            cache(source, base / f"{name}-cache.dmg", success=False)
            print(f"PASS: {name} rejected without published cache")
        assert digest(raw) == expected
        print("PASS: source unchanged; all native checks completed")


if __name__ == "__main__":
    main()
