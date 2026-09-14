"""Validate production camera receipts using disposable publish/observe files."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class GuestCameraReceiptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="guest-vcam-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.binary = Path(cls.temp.name) / "guest-vcam"
        result = subprocess.run(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc",
                                 "-framework", "Foundation", str(ROOT / "tests/fixtures/guest_vcam_harness.m"),
                                 "-o", str(cls.binary)], capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise RuntimeError(result.stderr)

    def run_case(self, name):
        with tempfile.TemporaryDirectory(prefix="vcam-snapshot-") as directory:
            result = subprocess.run([str(self.binary), name, directory], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_same_generation_can_consume_an_earlier_frame(self):
        self.run_case("valid")

    def test_publisher_restart_rejects_retained_observation(self):
        self.run_case("restart")

    def test_observation_cannot_exceed_published_index(self):
        self.run_case("future-index")

    def test_previous_generation_cannot_satisfy_receipt(self):
        self.run_case("old-generation")

    def test_truncated_observe_file_is_not_a_receipt(self):
        self.run_case("truncated")

    def test_reused_generation_requires_the_new_presentation(self):
        self.run_case("reused-generation")

    def test_legacy_observer_cannot_satisfy_v3_receipt(self):
        self.run_case("legacy-observer")
