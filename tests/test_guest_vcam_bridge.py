"""Exercise classic publication through the actual v2 frame consumer."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class GuestCameraBridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='vcam-bridge-')
        cls.addClassCleanup(cls.temp.cleanup)
        root = Path(cls.temp.name)
        viewfinder = (ROOT / 'sources/VPhoneGuestComponents/VCamCaptured/VCamViewfinderHooks.inc').read_text()
        layout = re.search(r'typedef struct vcc_latest_frame_s \{.*?\} vcc_latest_frame_t;', viewfinder, re.S).group()
        (root / 'consumer_types.h').write_text(layout)
        cls.binary = root / 'bridge'
        run = subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-fobjc-arc',
                              '-framework', 'Foundation', '-I', str(root),
                              str(ROOT / 'tests/fixtures/guest_vcam_bridge.m'), '-o', str(cls.binary)],
                             capture_output=True, text=True, timeout=60)
        if run.returncode:
            raise RuntimeError(run.stderr)

    def run_case(self, case):
        with tempfile.TemporaryDirectory(prefix='vcam-bridge-data-') as tmp:
            run = subprocess.run([str(self.binary), tmp, case], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stderr)

    def test_production_publisher_to_v2_consumer_pixels_and_receipt(self):
        self.run_case('valid')

    def test_failed_allocation_never_acknowledges_a_frame(self):
        self.run_case('allocation')

    def test_torn_frame_never_acknowledges_a_frame(self):
        self.run_case('torn')

    def test_explicit_v2_layout_uses_consumer_paths_and_unknown_layout_is_refused(self):
        self.run_case('paths')


if __name__ == '__main__':
    unittest.main()
