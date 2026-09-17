"""Tests for the D3 real-disk parity inventory and preflight checks."""

import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "research/d3_cfw_parity.py"
SPEC = importlib.util.spec_from_file_location("d3_cfw_parity", MODULE_PATH)
PARITY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PARITY)


class D3CFWParityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="d3-parity-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def make_pair(self, variant, current_manifest=b"cloud"):
        for side in PARITY.PAIR_SIDES:
            vm = self.root / f"vm-{variant}-{side}"
            restore = vm / "iPhone17,3_26.1_23B85_Restore"
            restore.mkdir(parents=True)
            (vm / "Disk.img").write_bytes(b"disk")
            (vm / "config.plist").write_bytes(b"config")
            (restore / "BuildManifest.plist").write_bytes(
                current_manifest if side == "current" else b"cloud")
            (restore / "iPhone-BuildManifest.plist").write_bytes(b"iphone")

    def test_preflight_records_matching_pairs(self):
        for variant in PARITY.VARIANTS:
            self.make_pair(variant)
        closed = subprocess.CompletedProcess([], 1, b"", b"")
        with mock.patch.object(PARITY.subprocess, "run", return_value=closed), \
             mock.patch.object(PARITY, "command", return_value=b""):
            result = PARITY.preflight(self.root, 0)
        self.assertEqual(set(result["pairs"]), set(PARITY.VARIANTS))
        for pair in result["pairs"].values():
            self.assertEqual(pair["legacy"]["manifests"], pair["current"]["manifests"])

    def test_preflight_rejects_changed_manifest(self):
        for variant in PARITY.VARIANTS:
            self.make_pair(variant, current_manifest=b"changed" if variant == "jb" else b"cloud")
        closed = subprocess.CompletedProcess([], 1, b"", b"")
        with mock.patch.object(PARITY.subprocess, "run", return_value=closed), \
             mock.patch.object(PARITY, "command", return_value=b""):
            with self.assertRaisesRegex(ValueError, "jb: paired manifests differs"):
                PARITY.preflight(self.root, 0)

    def test_preflight_rejects_open_disk(self):
        for variant in PARITY.VARIANTS:
            self.make_pair(variant)
        opened = subprocess.CompletedProcess([], 0, b"process", b"")
        with mock.patch.object(PARITY.subprocess, "run", return_value=opened), \
             mock.patch.object(PARITY, "command", return_value=b""):
            with self.assertRaisesRegex(ValueError, "Disk.img is open"):
                PARITY.preflight(self.root, 0)

    def test_compare_classifies_signature_only_difference(self):
        common = {
            "type": "file", "mode": 0o755, "bytes": 100,
            "signature_region": [80, 100], "without_signature_sha256": "same",
        }
        legacy = {role: {} for role in PARITY.ROLES}
        current = {role: {} for role in PARITY.ROLES}
        legacy["System"]["usr/bin/tool"] = {**common, "sha256": "old"}
        current["System"]["usr/bin/tool"] = {**common, "sha256": "new"}
        result = PARITY.compare(legacy, current)
        self.assertEqual(result["differences"][0]["classification"], "signature_only")

    def test_cli_refuses_to_overwrite_preflight_output(self):
        output = self.root / "result.json"
        output.write_text(json.dumps({"existing": True}))
        proc = subprocess.run(
            ["python3", str(MODULE_PATH), "preflight", str(self.root),
             "--minimum-free-gib", "0", "--output", str(output)],
            capture_output=True, text=True)
        self.assertNotEqual(proc.returncode, 0)
        self.assertEqual(json.loads(output.read_text()), {"existing": True})


if __name__ == "__main__":
    unittest.main()
