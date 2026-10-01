"""Launchpad bundle checks and B1 source boundaries (read-only, embedded toolchain only)."""
import importlib.util
from pathlib import Path
import plistlib
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('check_launchpad_bundle', ROOT / 'scripts/check_launchpad_bundle.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

LAUNCHPAD_SOURCES = (ROOT / 'sources/VPhoneLaunchpad', ROOT / 'sources/VPhoneLaunchpadKit')


def launchpad_swift():
    return {path: path.read_text(encoding='utf-8')
            for directory in LAUNCHPAD_SOURCES for path in sorted(directory.rglob('*.swift'))}


class LaunchpadBundleCheckTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / 'vphone-launchpad.app'
        self.info = plistlib.loads((ROOT / 'sources/VPhoneLaunchpad-Info.plist').read_bytes())
        for relative in ('Contents/MacOS/vphone-launchpad', 'Contents/Resources/AppIcon.icns',
                         'Contents/Resources/embedded-toolchain.json',
                         f'{module.HELPER}/Contents/MacOS/vphone-cli', f'{module.HELPER}/Contents/MacOS/vphone-vm',
                         f'{module.HELPER}/Contents/Resources/ja.lproj/Other.strings'):
            path = self.app / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'fixture')
            path.chmod(0o755)
        for language in module.LANGUAGES:
            for table in ('Localizable.strings', 'InfoPlist.strings'):
                path = self.app / f'Contents/Resources/{language}.lproj/{table}'
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b'"k" = "v";')
        self.manifest = {'schema': module.MANIFEST_SCHEMA, 'version': 1, 'gitHash': 'abc1234',
                         'vphoneCLI': {'cdhash': 'aa'}, 'vphoneVM': {'cdhash': 'bb'}}

    def test_info_plist_template_passes(self):
        module.check_info(self.info)
        self.assertEqual(self.info['CFBundleIdentifier'], 'com.vphone.cli.launchpad')

    def test_upstream_identifier_is_rejected(self):
        self.info['CFBundleIdentifier'] = 'com.vphone.launchpad'
        with self.assertRaisesRegex(ValueError, 'CFBundleIdentifier'):
            module.check_info(self.info)

    def test_extra_language_in_info_plist_is_rejected(self):
        self.info['CFBundleLocalizations'] = ['en', 'ja', 'zh-Hans']
        with self.assertRaisesRegex(ValueError, 'CFBundleLocalizations'):
            module.check_info(self.info)

    def test_helper_keys_are_rejected(self):
        self.info['SMPrivilegedExecutables'] = {'com.vphone.cli.helper': 'anchor apple'}
        with self.assertRaisesRegex(ValueError, 'deferred'):
            module.check_info(self.info)

    def test_complete_layout_passes(self):
        module.check_layout(self.app)
        module.check_localizations(self.app)

    def test_missing_embedded_toolchain(self):
        (self.app / module.HELPER / 'Contents/MacOS/vphone-vm').unlink()
        with self.assertRaisesRegex(ValueError, 'Missing'):
            module.check_layout(self.app)

    def test_symbolic_link_toolchain(self):
        helper = self.app / module.HELPER
        helper.rename(Path(self.temp.name) / 'elsewhere.app')
        helper.symlink_to(Path(self.temp.name) / 'elsewhere.app')
        with self.assertRaisesRegex(ValueError, 'Symbolic link'):
            module.check_layout(self.app)

    def test_privileged_helper_directory_is_rejected(self):
        path = self.app / 'Contents/Library/LaunchServices/com.vphone.cli.helper'
        path.parent.mkdir(parents=True)
        path.write_bytes(b'helper')
        with self.assertRaisesRegex(ValueError, 'deferred'):
            module.check_layout(self.app)

    def test_extra_localization_is_rejected(self):
        (self.app / 'Contents/Resources/ja.lproj').mkdir()
        with self.assertRaisesRegex(ValueError, 'Localizations'):
            module.check_localizations(self.app)

    def test_missing_infoplist_strings_is_rejected(self):
        (self.app / 'Contents/Resources/zh-Hans.lproj/InfoPlist.strings').unlink()
        with self.assertRaisesRegex(ValueError, 'InfoPlist.strings'):
            module.check_localizations(self.app)

    def test_manifest_matches_nested_and_reference(self):
        actual = {'vphone-cli': 'aa', 'vphone-vm': 'bb'}
        module.check_manifest(self.manifest, actual, reference=dict(actual))
        with self.assertRaisesRegex(ValueError, 'vphone-vm cdhash'):
            module.check_manifest(self.manifest, {'vphone-cli': 'aa', 'vphone-vm': 'cc'})
        with self.assertRaisesRegex(ValueError, 'differs from reference'):
            module.check_manifest(self.manifest, actual, reference={'vphone-cli': 'aa', 'vphone-vm': 'dd'})
        self.manifest['schema'] = 'other'
        with self.assertRaisesRegex(ValueError, 'schema'):
            module.check_manifest(self.manifest, actual)


class LaunchpadB1BoundaryTests(unittest.TestCase):
    """B1 is read-only and runs only the embedded toolchain (T26 design 4, 5.2, 11.1)."""

    FORBIDDEN = {
        r'VPhoneVMLockProbe\.': 'lock probe',
        r'isRunLockHeld\(': 'run lock probe',
        r'\bflock\(': 'flock',
        r'VPhoneVMLock\(': 'VM lock',
        r'lsof': 'lsof',
        r'"create-status"': 'create-status',
        r'"doctor"': 'doctor',
        r'"launch"|"stop"|"new"|"create"|"delete"|"rename"|"clone"|"config"|"export"|"import"': 'VM-changing command',
        r'"cfw"|"helper"|"core-bundle"|"install-bundle"|"register"': 'privileged or install command',
        r'--sudo-password|--root-popup': 'privileged option',
        r'VPhoneHelper|SMAppService|SMJobBless|ServiceManagement|EPExecutionPolicy': 'helper or execution policy',
        r'control\.sock|vphone\.sock|NWListener|bind\(': 'control socket',
        r'posix_spawn': 'detached spawn',
        r'ProcessInfo\.processInfo\.environment|getenv\(': 'environment lookup',
        r'VPhoneHostControl': 'host control',
    }

    def test_sources_stay_within_b1(self):
        sources = launchpad_swift()
        self.assertTrue(sources)
        for path, text in sources.items():
            code = re.sub(r'//.*', '', text)  # comments may name what is avoided
            for pattern, what in self.FORBIDDEN.items():
                self.assertIsNone(re.search(pattern, code), f'{what} in {path.relative_to(ROOT)}')

    def test_only_vm_list_is_run(self):
        runs = []
        for path, text in launchpad_swift().items():
            runs += re.findall(r'\.run\(\s*\[([^\]]*)\]', text)
        self.assertEqual([re.findall(r'"([^"]+)"', arguments)[:3] for arguments in runs], [['vm', 'list', '--json']])

    def test_executable_comes_only_from_the_embedded_app(self):
        toolchain = (ROOT / 'sources/VPhoneLaunchpadKit/VPhoneLaunchpadToolchain.swift').read_text()
        self.assertIn('verify(appBundle: Bundle.main.bundleURL)', toolchain)
        self.assertIn('static let helperPath = "Contents/Helpers/vphone-cli.app"', toolchain)
        command_line = (ROOT / 'sources/VPhoneLaunchpadKit/VPhoneLaunchpadCommandLine.swift').read_text()
        public_inits = re.findall(r'public init\(([^)]*)\)', command_line.split('// MARK: - vphone-cli')[1])
        self.assertEqual(public_inits, ['toolchain: VPhoneLaunchpadToolchain, history: VPhoneLaunchpadCommandHistory'])

    def test_build_and_ci_do_not_include_launchpad(self):
        makefile = (ROOT / 'Makefile').read_text()
        self.assertRegex(makefile, r'\nbuild: bundle\n')
        self.assertRegex(makefile, r'\nlaunchpad: bundle\n')
        for workflow in (ROOT / '.github/workflows').glob('*.yml'):
            self.assertNotIn('launchpad', workflow.read_text(), workflow.name)
        self.assertNotIn('launchpad', (ROOT / 'scripts/build.sh').read_text())


if __name__ == '__main__':
    unittest.main()
