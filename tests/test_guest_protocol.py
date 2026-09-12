"""Run production guest framing over real sockets with interrupted short I/O."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class GuestProtocolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="guest-protocol-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.binary = Path(cls.temp.name) / "guest-protocol"
        build = subprocess.run(
            ["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-framework", "Foundation",
             str(ROOT / "tests/fixtures/guest_protocol_harness.m"), "-o", str(cls.binary)],
            capture_output=True, text=True, timeout=60)
        if build.returncode:
            raise RuntimeError(build.stderr)

    def run_case(self, name):
        result = subprocess.run([str(self.binary), name], capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_interrupted_short_reads_and_writes(self):
        self.run_case("interrupted")

    def test_outgoing_oversize_rejected(self):
        self.run_case("oversize")

    def test_four_mib_boundary_and_invalid_lengths(self):
        self.run_case("boundary")

    def test_concurrent_responses_keep_payloads_and_ids_together(self):
        self.run_case("concurrent")
