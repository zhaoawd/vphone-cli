import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("prepare_vendor", ROOT / "scripts/prepare_vendor.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CapstoneOverlayTests(unittest.TestCase):
    def test_clean_checkout_and_repeat_preserve_exact_local_implementation(self):
        original = subprocess.check_output([
            "git", "-C", str(ROOT / "vendor/libcapstone-spm"), "show",
            "ea98aa0a31693d7ea2930c4372f9b5858b0bc7a3:Sources/Capstone/Instruction.swift",
        ])
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            source = repository / "Sources/Capstone/Instruction.swift"
            source.parent.mkdir(parents=True)
            source.write_bytes(original)
            module.prepare_capstone(repository, ROOT / "dependencies/capstone-overlays")
            manifest = json.loads((ROOT / "dependencies/capstone-overlays/manifest.json").read_text())
            self.assertEqual(module.hashlib.sha256(source.read_bytes()).hexdigest(), manifest["patched_sha256"])
            module.prepare_capstone(repository, ROOT / "dependencies/capstone-overlays")

    def test_unrecognized_edits_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            source = repository / "Sources/Capstone/Instruction.swift"
            source.parent.mkdir(parents=True)
            source.write_bytes(b"unrelated local edits\n")
            with self.assertRaisesRegex(RuntimeError, "preserving local edits"):
                module.prepare_capstone(repository, ROOT / "dependencies/capstone-overlays")
            self.assertEqual(source.read_bytes(), b"unrelated local edits\n")

    def test_tampered_patch_is_rejected_before_source_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            overlay = Path(directory)
            (overlay / "manifest.json").write_bytes((ROOT / "dependencies/capstone-overlays/manifest.json").read_bytes())
            (overlay / "arm64-detail.patch").write_bytes(b"changed patch\n")
            with self.assertRaisesRegex(RuntimeError, "patch hash mismatch"):
                module.prepare_capstone(overlay / "missing-repository", overlay)
