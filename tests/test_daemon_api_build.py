import copy
import importlib.util
from pathlib import Path
import plistlib
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('daemon_api_build', ROOT / 'scripts/check_daemon_api.py')
module = importlib.util.module_from_spec(spec)
sys.path.insert(0, str(ROOT / 'scripts'))
try:
    spec.loader.exec_module(module)
finally:
    sys.path.pop(0)


class DaemonAPIBuildTests(unittest.TestCase):
    def setUp(self):
        self.pins = [{'identity': 'example', 'kind': 'remoteSourceControl', 'location': 'https://example.invalid/repo',
                      'state': {'revision': 'a' * 40, 'version': '1.0.0'}}]

    def test_exact_pins_are_accepted(self):
        module.check_pins(self.pins, copy.deepcopy(self.pins))

    def test_changed_revision_version_location_and_extra_package_are_rejected(self):
        for field in ('revision', 'version', 'location', 'kind', 'extra'):
            with self.subTest(field=field):
                changed = copy.deepcopy(self.pins)
                if field in ('location', 'kind'):
                    changed[0][field] += '-other'
                elif field == 'extra':
                    changed.append({'identity': 'other', 'kind': 'remoteSourceControl', 'location': 'other', 'state': {'revision': 'b' * 40}})
                else:
                    changed[0]['state'][field] += 'b'
                with self.assertRaises(ValueError):
                    module.check_pins(changed, self.pins)

    def test_duplicate_pins_are_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            module.check_pins(self.pins + self.pins, self.pins)

    def test_launchd_plist_restarts_quickly_and_keeps_proxy_log(self):
        # Upstream 2e2ed0a8: proxy exit reasons reach a file, launchd restarts
        # the proxy after one second, and boot-time throttling does not apply.
        plist = plistlib.loads((module.PROJECT / 'Configuration/vphoned.plist').read_bytes())
        self.assertEqual(plist, {
            'Label': 'com.vphone.vphoned', 'ProgramArguments': ['/usr/bin/vphoned'],
            'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 1, 'ProcessType': 'Interactive',
            'StandardOutPath': '/var/log/vphoned.log', 'StandardErrorPath': '/var/log/vphoned.log',
        })
