import copy
import importlib.util
import json
from pathlib import Path
import plistlib
import sys
import unittest
from unittest.mock import patch
import tempfile
import shutil

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

    @staticmethod
    def project(kind='exactVersion', version='1.0.0', location='https://example.invalid/repo'):
        return ('C1 /* XCRemoteSwiftPackageReference "example" */ = {\n'
                '\t\t\tisa = XCRemoteSwiftPackageReference;\n'
                f'\t\t\trepositoryURL = "{location}";\n'
                '\t\t\trequirement = {\n'
                f'\t\t\t\tkind = {kind};\n'
                f'\t\t\t\t{"version" if kind == "exactVersion" else "minimumVersion"} = {version};\n'
                '\t\t\t};\n\t\t};\n')

    def test_project_requirement_must_be_exact_resolved_version(self):
        module.check_project_requirements(self.project(), self.pins)
        cases = {
            'range': self.project(kind='upToNextMajorVersion'),
            'version': self.project(version='1.0.1'),
            'unpinned': self.project(location='https://example.invalid/other'),
            'empty': '',
        }
        for label, text in cases.items():
            with self.subTest(label=label), self.assertRaises(ValueError):
                module.check_project_requirements(text, self.pins)

    def test_repository_daemon_graph_pins_iclikit_0_7_7(self):
        # T08: upstream 2.2.3 (a969cd5d) daemon lockfile; the project keeps an
        # exact requirement where upstream uses upToNextMajorVersion.
        pins = json.loads(module.LOCK.read_text())['pins']
        module.check_pins(pins, json.loads(module.EXPECTED.read_text())['pins'])
        module.check_project_requirements(module.XCODE_PROJECT.read_text(), pins)
        icli = next(pin for pin in pins if pin['identity'] == 'icli')
        self.assertEqual(icli['state'], {'revision': '9e9a6ca940ac4142771eb34cf7e052e35a7b7987', 'version': '0.7.7'})

    def test_launchd_plist_restarts_quickly_and_keeps_proxy_log(self):
        # Upstream 2e2ed0a8: proxy exit reasons reach a file, launchd restarts
        # the proxy after one second, and boot-time throttling does not apply.
        plist = plistlib.loads((module.PROJECT / 'Configuration/vphoned.plist').read_bytes())
        self.assertEqual(plist, {
            'Label': 'com.vphone.vphoned', 'ProgramArguments': ['/usr/bin/vphoned'],
            'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 1, 'ProcessType': 'Interactive',
            'StandardOutPath': '/var/log/vphoned.log', 'StandardErrorPath': '/var/log/vphoned.log',
        })

    def test_parallel_api_identity_matches_environment_manifest(self):
        profile = json.loads((ROOT / 'scripts/guest_environment.json').read_text())['profiles']['v2']['api_daemon']
        plist = plistlib.loads((module.PROJECT / 'Configuration/vphoned-api.plist').read_bytes())
        self.assertEqual(plist['Label'], profile['label'])
        self.assertEqual(plist['ProgramArguments'], [profile['program']])
        self.assertEqual(plist['EnvironmentVariables']['VPHONED_VCAM'], profile['vcam'])
        self.assertEqual(plist['StandardOutPath'], profile['log'])
        self.assertEqual(plist['StandardErrorPath'], profile['log'])
        self.assertTrue(plist['KeepAlive'])
        self.assertEqual(plist['ThrottleInterval'], 1)
        native = (module.PROJECT / 'Native/vphoned_native.m').read_text()
        proxy = (module.PROJECT / 'Native/vphoned_proxy.c').read_text()
        api = (module.PROJECT / 'Daemon/GuestAPI.swift').read_text()
        for key in ('cache', 'marker', 'pending'):
            self.assertIn('"' + profile[key] + '"', native)
        self.assertIn('"' + profile['pending'] + '"', proxy)
        for key in ('cache', 'marker'):
            self.assertIn('"' + profile[key] + '"', api)
        self.assertNotEqual(profile['cache'], '/var/root/Library/Caches/vphoned')

    def test_candidate_records_parallel_plist_and_rejects_changed_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            stage = Path(tmp)
            (stage / 'vphoned').write_bytes(b'candidate')
            (stage / 'vphoned').chmod(0o755)
            for source, name in (('vphoned-api.plist', 'vphoned-api.plist'),
                                 ('VPhoneDaemon.entitlements', 'vphoned.entitlements.plist')):
                shutil.copyfile(module.PROJECT / 'Configuration' / source, stage / name)
            policy = (stage / 'vphoned.entitlements.plist').read_bytes()
            def output(*args):
                return {'/usr/bin/lipo': 'arm64', '/usr/bin/xcrun': ' platform IOS\n minos 15.0\n',
                        '/usr/bin/nm': '_malloc', '/usr/bin/otool': 'candidate:\n /usr/lib/libSystem.B.dylib (x)'}[args[0]]
            with patch.object(module, 'output', side_effect=output), \
                    patch.object(module.subprocess, 'check_output', return_value=policy):
                result = module.inspect_candidate(stage, 'ldid', self.pins)
                self.assertIn('vphoned-api.plist', result['files_sha256'])
                self.assertNotIn('vphoned.plist', result['files_sha256'])
                (stage / 'vphoned-api.plist').write_bytes(plistlib.dumps({'Label': 'classic'}))
                with self.assertRaisesRegex(ValueError, 'launchd plist'):
                    module.inspect_candidate(stage, 'ldid', self.pins)
