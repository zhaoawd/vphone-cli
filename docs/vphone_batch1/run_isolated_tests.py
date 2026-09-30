#!/usr/bin/env python3
"""Run ONLY the two new helper files and their tests, without the full VM app."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import sys

PACKAGE = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="vphone-batch1-isolated-") as temporary:
    root = Path(temporary)
    sources = root / "Sources/VPhoneCore"
    tests = root / "Tests/VPhoneCoreTests"
    sources.mkdir(parents=True)
    tests.mkdir(parents=True)
    for filename in ("VPhoneNVRAMStorage.swift", "VPhoneCloneCopy.swift"):
        shutil.copy2(PACKAGE / "files/sources/VPhoneCore" / filename, sources / filename)
    for filename in ("NVRAMStorageTests.swift", "CloneCopyTests.swift"):
        shutil.copy2(PACKAGE / "files/tests/VPhoneCoreTests" / filename, tests / filename)
    (root / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "VPhoneBatch1Isolated", targets: [
    .target(name: "VPhoneCore"),
    .testTarget(name: "VPhoneCoreTests", dependencies: ["VPhoneCore"])
])
''')
    print("ISOLATED SUBSET ONLY: not make test, not APFS/Virtualization or VM acceptance.", flush=True)
    try:
        result = subprocess.run(["swift", "test", "--jobs", "2"], cwd=root, check=False)
    except FileNotFoundError:
        print("Swift is not installed.", file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(result.returncode)
