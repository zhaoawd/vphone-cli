"""Packaging rejects payloads that could replace classic control or publish a second camera."""
from pathlib import Path
import hashlib
import json
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import check_guest_api as guest

class GuestAPICohortTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.image = self.root / 'vphoned'
        self.image.write_bytes(b'fixture\0' + guest.CACHE.encode() + b'\0')
        self.image.chmod(0o755)
        self.job = plistlib.loads((ROOT / 'sources/VPhoneDaemon/Configuration/vphoned.plist').read_bytes())
        self.policy = plistlib.loads((ROOT / 'sources/VPhoneDaemon/Configuration/VPhoneDaemon.entitlements').read_bytes())
        self.pins = json.loads((ROOT / 'dependencies/daemon-api-pins.json').read_text())['pins']
        self.write()
        for name, replacement in [('validate_marker', lambda *_: None), ('validate_metadata', lambda *_: None), ('output', lambda *_: '' )]:
            mock = patch.object(guest, name, replacement)
            mock.start(); self.addCleanup(mock.stop)
        mock = patch.object(guest.subprocess, 'check_output', return_value=plistlib.dumps(self.policy))
        mock.start(); self.addCleanup(mock.stop)

    def write(self):
        (self.root / 'vphoned.plist').write_bytes(plistlib.dumps(self.job))
        (self.root / 'vphoned.entitlements.plist').write_bytes(plistlib.dumps(self.policy))
        self.manifest = {'files_sha256': {name: hashlib.sha256((self.root / name).read_bytes()).hexdigest() for name in guest.API_FILES}, 'pins': self.pins}
        (self.root / 'manifest.json').write_text(json.dumps(self.manifest))

    def test_default_api_keeps_bootstrap_startup_and_disables_camera(self):
        report = guest.inspect_api(self.root)
        self.assertTrue(report['bootstrap_startup_enabled'])
        self.assertFalse(report['camera_publisher_enabled'])
        self.assertNotEqual(report['cache'], '/var/root/Library/Caches/vphoned')

    def test_classic_identity_and_camera_modes_are_rejected(self):
        for key, value in [('Label', 'com.vphone.vphoned'), ('ProgramArguments', ['/usr/bin/vphoned']), ('EnvironmentVariables', {}), ('EnvironmentVariables', {'VPHONE_API_ONLY': '1'} )]:
            with self.subTest(key=key, value=value):
                original = self.job[key]; self.job[key] = value; self.write()
                with self.assertRaisesRegex(ValueError, 'own label/path'):
                    guest.inspect_api(self.root)
                self.job[key] = original

    def test_old_cache_payload_is_rejected(self):
        self.image.write_bytes(b'/var/root/Library/Caches/vphoned\0'); self.write()
        with self.assertRaisesRegex(ValueError, 'separate cache'):
            guest.inspect_api(self.root)

    def test_unsigned_metadata_is_checked_after_integrity_guards(self):
        with patch.object(guest, 'validate_metadata', side_effect=ValueError('wrong signature')):
            with self.assertRaisesRegex(ValueError, 'wrong signature'):
                guest.inspect_api(self.root)

    def test_tampered_payload_and_dependency_are_rejected(self):
        self.image.write_bytes(b'tampered')
        with self.assertRaisesRegex(ValueError, 'build manifest'):
            guest.inspect_api(self.root)
        self.write(); self.manifest['pins'] = []
        (self.root / 'manifest.json').write_text(json.dumps(self.manifest))
        with self.assertRaisesRegex(ValueError, 'fixed dependency'):
            guest.inspect_api(self.root)

    def test_required_root_hide_entitlement_is_rejected_when_missing(self):
        self.policy.pop('com.apple.private.xpc.service-configure'); self.write()
        with self.assertRaisesRegex(ValueError, 'service-configure'):
            guest.inspect_api(self.root)

    def test_launchd_merge_preserves_classic_and_includes_independent_api(self):
        import subprocess
        import os
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); jobs = root / 'jobs'; jobs.mkdir()
            target = root / 'launchd.plist'
            existing = {'LaunchDaemons': {'existing': {'Label': 'existing'}}}
            target.write_bytes(plistlib.dumps(existing))
            classic = {'Label': 'com.vphone.vphoned', 'ProgramArguments': ['/usr/bin/vphoned']}
            (jobs / 'vphoned.plist').write_bytes(plistlib.dumps(classic))
            (jobs / 'vphoned-api.plist').write_bytes(plistlib.dumps(self.job))
            result = subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/patchers/cfw.py'), 'inject-daemons', str(target), str(jobs)], env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            entries = plistlib.loads(target.read_bytes())['LaunchDaemons']
            self.assertEqual(entries['existing'], {'Label': 'existing'})
            self.assertEqual(entries['/System/Library/LaunchDaemons/vphoned.plist'], classic)
            self.assertEqual(entries['/System/Library/LaunchDaemons/vphoned-api.plist'], self.job)
