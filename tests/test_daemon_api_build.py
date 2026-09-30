import copy
import importlib.util
import json
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
