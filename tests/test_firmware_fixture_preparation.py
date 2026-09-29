import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("firmware_fixtures", ROOT / "scripts/prepare_firmware_fixtures.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FirmwareFixturePreparationTests(unittest.TestCase):
    def test_existing_fixtures_are_never_overwritten(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output = root / "fixtures"
            output.mkdir()
            marker = output / "reference.json"
            marker.write_text("original reference")
            with self.assertRaisesRegex(ValueError, "Refusing to overwrite"):
                module.prepare(root / "missing.ipsw", root / "missing.bin", output)
            self.assertEqual(marker.read_text(), "original reference")

    def test_wrong_firmware_digest_cannot_create_a_reference(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            ipsw = root / "wrong.ipsw"
            ipsw.write_bytes(b"different firmware")
            output = root / "fixtures"
            with self.assertRaisesRegex(ValueError, "pinned SHA-256"):
                module.prepare(ipsw, root / "missing.bin", output)
            self.assertFalse(output.exists())
            self.assertEqual(ipsw.read_bytes(), b"different firmware")

    def test_dangling_output_symlink_is_not_followed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output = root / "fixtures"
            output.symlink_to(root / "absent")
            with self.assertRaisesRegex(ValueError, "Refusing to overwrite"):
                module.prepare(root / "missing.ipsw", root / "missing.bin", output)
            self.assertTrue(output.is_symlink())
            self.assertFalse((root / "absent").exists())
