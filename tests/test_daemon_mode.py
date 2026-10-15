"""Execute production daemon mode selection without an iOS process."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

@unittest.skipUnless(shutil.which('swiftc'), 'Swift compiler required')
class DaemonModeTests(unittest.TestCase):
    def test_default_camera_disabled_and_api_only_modes(self):
        source = ROOT / 'sources/VPhoneDaemon/Daemon/GuestDaemonMode.swift'
        probe = '''
let cases: [([String: String], Bool, Bool)] = [
    ([:], false, true),
    (["VPHONE_DISABLE_CAMERA": "1"], false, false),
    (["VPHONED_VCAM": "off"], false, false),
    (["VPHONED_VCAM": "off", "VPHONE_DISABLE_CAMERA": "0"], false, false),
    (["VPHONED_VCAM": "on"], false, true),
    (["VPHONE_API_ONLY": "1"], true, false),
    (["VPHONE_API_ONLY": "1", "VPHONE_DISABLE_CAMERA": "0"], true, false),
    (["VPHONE_API_ONLY": "0", "VPHONE_DISABLE_CAMERA": "0"], false, true)]
for (env, only, camera) in cases {
    let mode = GuestDaemonMode(environment: env)
    precondition(mode.apiOnly == only)
    precondition(mode.cameraEnabled == camera)
}
print("daemon mode matrix passed")
'''
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'main.swift').write_text(probe)
            result = subprocess.run(['swiftc', str(source), str(root / 'main.swift'), '-o', str(root / 'probe')], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(root / 'probe')], capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('matrix passed', result.stdout)
