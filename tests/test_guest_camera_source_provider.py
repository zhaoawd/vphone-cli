"""Replay the actual backing getter seam without writing a shared-cache page."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class GuestCameraSourceProviderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='camera-provider-build-')
        cls.addClassCleanup(cls.temp.cleanup)
        cls.binary = Path(cls.temp.name) / 'provider'
        subprocess.run(['xcrun', '--sdk', 'macosx', 'clang', '-fobjc-arc', '-Wall', '-Wextra', '-Werror',
                        '-framework', 'Foundation', str(ROOT / 'tests/fixtures/guest_camera_source_provider.m'),
                        '-o', str(cls.binary)], check=True, capture_output=True, timeout=60)

    def test_native_enumeration_includes_one_current_synthetic_backing(self):
        for case in ['nil', 'empty', 'native', 'stale', 'missing-provider']:
            with self.subTest(case=case):
                result = subprocess.run([str(self.binary), case], capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__': unittest.main()
