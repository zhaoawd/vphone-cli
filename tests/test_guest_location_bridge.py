"""Exercise real classic ownership handlers and their app-side state file."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class GuestLocationBridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='location-bridge-build-')
        cls.addClassCleanup(cls.temp.cleanup)
        cls.binary = Path(cls.temp.name) / 'bridge'
        run = subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-fobjc-arc',
                              '-framework', 'Foundation', str(ROOT / 'tests/fixtures/guest_location_bridge.m'),
                              '-o', str(cls.binary)], capture_output=True, text=True, timeout=60)
        if run.returncode: raise RuntimeError(run.stderr)

    def run_case(self, case):
        with tempfile.TemporaryDirectory(prefix='location-bridge-data-') as folder:
            run = subprocess.run([str(self.binary), folder, case], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stderr)

    def test_v2_writes_complete_points_and_preserves_owner_sequence_and_stop(self):
        self.run_case('v2')

    def test_native_layout_does_not_publish_application_override(self):
        self.run_case('native')

    def test_actual_reader_rejects_expired_invalid_and_boolean_points(self):
        self.run_case('reader')

    def test_live_publisher_renews_state_without_advancing_delivery_and_clear_stops_it(self):
        self.run_case('refresh')


if __name__ == '__main__': unittest.main()
