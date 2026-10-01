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
    """B1-B5 boundaries: list, launch, stop, the offline edits and vm create through
    the embedded toolchain only (T26 design 4, 5.1-5.3, 9, 11.1)."""

    FORBIDDEN = {
        r'VPhoneVMLockProbe\.': 'lock probe',
        r'isRunLockHeld\(': 'run lock probe',
        r'\bflock\(': 'flock',
        r'VPhoneVMLock\(': 'VM lock',
        r'VPhoneBundleGuard|VPhoneBundleOps': 'bundle lock or bundle operation outside the CLI',
        r'lsof': 'lsof',
        r'"new"|"--dfu"': 'VM-changing command',
        r'"cfw"|"install-bundle"|"verify-bundle"|"register"|"install"': 'privileged or install command',
        # Launchpad handles no password and never asks for a terminal prompt.
        r'--sudo-password|--interactive': 'password or interactive option',
        r'VPhoneHelper|SMAppService|SMJobBless|ServiceManagement|EPExecutionPolicy': 'helper or execution policy',
        r'control\.sock|vphone\.sock|NWListener|bind\(': 'control socket',
        r'ProcessInfo\.processInfo\.environment|getenv\(': 'environment lookup',
        r'VPhoneHostControl': 'host control',
        r'SIGTERM': 'signal other than SIGINT',
    }
    # Only the child process type spawns detached children and sends signals.
    CHILD_PROCESS = ROOT / 'sources/VPhoneLaunchpadKit/VPhoneLaunchpadChildProcess.swift'
    CONFINED = {r'posix_spawn': 'detached spawn', r'\bkill\(': 'kill', r'\bkillpg\(': 'process group signal'}

    # B4: vm create, its resume and status, the firmware catalog and the only
    # privileged option (`--root-popup`, the system authentication dialog) appear
    # only in the create command file.
    CREATE_COMMANDS = (r'"create"|"create-status"|"fw"|"catalog"|--root-popup|"--resume"|"--restart-from"|'
                       r'"--accept-tool-change"|"--keep-artifacts"')
    CREATE_FILE = ROOT / 'sources/VPhoneLaunchpadKit/VPhoneLaunchpadCreateCommand.swift'
    CREATION = ROOT / 'sources/VPhoneLaunchpadKit/VPhoneLaunchpadCreation.swift'

    # B5: the read-only command names appear only in the command whitelist.
    READ_ONLY_COMMANDS = r'"doctor"|"helper"|"core-bundle"'
    WHITELIST = ROOT / 'sources/VPhoneLaunchpadKit/VPhoneLaunchpadReadOnlyCommand.swift'

    # B3: the offline edit commands, `--force` and file removal appear only in the
    # edit command file; file removal only in the cancelled-export cleanup.
    EDIT_COMMANDS = r'"config"|"rename"|"clone"|"delete"|"export"|"import"|"--force"'
    EDIT_FILE = ROOT / 'sources/VPhoneLaunchpadKit/VPhoneLaunchpadMachineEdit.swift'
    FILE_REMOVAL = r'removeItem\(|\bunlink\(|\brmdir\(|trashItem|(?<![.\w])remove\(|removefile\('
    # B3: rename and clone measure `<machine>/vphone.sock` against `sun_path`; the
    # path is only measured, never opened or bound.
    LOCATIONS = ROOT / 'sources/VPhoneLaunchpadKit/VPhoneLaunchpadMachineLocations.swift'
    SOCKET_LENGTH = '.appendingPathComponent("vphone.sock").path\n        return path.utf8CString.count <= ' \
                    'MemoryLayout.size(ofValue: sockaddr_un().sun_path)'

    def test_sources_stay_within_b1(self):
        sources = launchpad_swift()
        self.assertTrue(sources)
        for path, text in sources.items():
            code = re.sub(r'//.*', '', text)  # comments may name what is avoided
            if path == self.LOCATIONS:
                self.assertEqual(code.count(self.SOCKET_LENGTH), 1)
                code = code.replace(self.SOCKET_LENGTH, '')
            for pattern, what in self.FORBIDDEN.items():
                self.assertIsNone(re.search(pattern, code), f'{what} in {path.relative_to(ROOT)}')
            if path != self.WHITELIST:
                self.assertIsNone(re.search(self.READ_ONLY_COMMANDS, code),
                                  f'read-only command name outside the whitelist in {path.relative_to(ROOT)}')
            if path != self.CREATE_FILE:
                self.assertIsNone(re.search(self.CREATE_COMMANDS, code),
                                  f'create command or option outside the create command file in {path.relative_to(ROOT)}')
            if path != self.EDIT_FILE:
                self.assertIsNone(re.search(self.EDIT_COMMANDS, code),
                                  f'edit command name outside the edit command file in {path.relative_to(ROOT)}')
                self.assertIsNone(re.search(self.FILE_REMOVAL, code), f'file removal in {path.relative_to(ROOT)}')
            if path != self.CHILD_PROCESS:
                for pattern, what in self.CONFINED.items():
                    self.assertIsNone(re.search(pattern, code), f'{what} in {path.relative_to(ROOT)}')

    def test_b3_edit_file_builds_only_the_offline_edits(self):
        code = re.sub(r'//.*', '', self.EDIT_FILE.read_text(encoding='utf-8'))
        arrays = [re.findall(r'"([^"]*)"', body) for body in re.findall(r'\[("[^\]]*)\]', code)]
        built = sorted({tuple(a) for a in arrays if a and a[0] == 'vm'})
        self.assertEqual(built, [
            ('vm', 'clone'), ('vm', 'config'), ('vm', 'delete', '--force'), ('vm', 'export', '--out'),
            ('vm', 'import', '--library-root'), ('vm', 'rename'),
        ])
        # `--force` only skips the CLI's stdin prompt, and only for delete.
        self.assertEqual(re.findall(r'\[[^\]]*"--force"[^\]]*\]', code),
                         ['["vm", "delete", machine.name, "--force"]'])
        # Every machine command carries its library root.
        for verb in ('config', 'rename', 'clone', 'delete', 'export'):
            self.assertRegex(code, rf'\["vm", "{verb}"[^\]]*\] \+ machine\.libraryArguments')
        self.assertIn('["vm", "import", archive.path, "--library-root", libraryRoot]', code)
        # The value exists only through the factories.
        self.assertIn('private init(_ kind: Kind, _ arguments: [String])', code)

    def test_b3_only_a_cancelled_export_removes_a_file(self):
        code = re.sub(r'//.*', '', self.EDIT_FILE.read_text(encoding='utf-8'))
        self.assertEqual(re.findall(self.FILE_REMOVAL, code), ['unlink('])
        cleanup = code.split('public static func removeCancelled', 1)[1]
        self.assertRegex(cleanup, r'guard !existedBefore, lstat\(url\.path, &info\) == 0, info\.st_mode & S_IFMT == S_IFREG')
        library = (ROOT / 'sources/VPhoneLaunchpadKit/VPhoneLaunchpadMachineLibrary.swift').read_text()
        self.assertEqual(library.count('removeCancelled('), 1)
        self.assertRegex(library, r'if Task\.isCancelled \{\s*VPhoneLaunchpadExportOutput\.removeCancelled\(destination, existedBefore: existedBefore\)')

    def test_b5_whitelist_builds_only_read_only_commands(self):
        code = re.sub(r'//.*', '', self.WHITELIST.read_text(encoding='utf-8'))
        arrays = [re.findall(r'"([^"]*)"', body) for body in re.findall(r'\[("[^\]]*)\]', code)]
        built = sorted({tuple(a) for a in arrays if a and a[0] in ('doctor', 'helper', 'core-bundle')})
        self.assertEqual(built, [
            ('core-bundle', 'verify', '--version'),
            ('doctor', '--json', '--library-root'),
            ('helper', 'status'),
        ])

    def test_signals_reach_only_the_own_child(self):
        code = re.sub(r'//.*', '', self.CHILD_PROCESS.read_text())
        self.assertEqual(sorted(re.findall(r'\bkill\(([^)]*)\)', code)),
                         ['detachedPID, SIGINT', 'process.processIdentifier, SIGINT'])
        # B4: the create's process group, only while its leader is unreaped.
        self.assertEqual(re.findall(r'\bkillpg\(([^)]*)\)', code), ['detachedPID, SIGINT'])
        group = code.split('public func interruptGroup()', 1)[1].split('// MARK:', 1)[0]
        self.assertRegex(group, r'guard !hasExited else \{\s*return false\s*\}\s*return killpg\(detachedPID, SIGINT\) == 0')

    def test_b4_create_file_builds_only_create_commands(self):
        code = re.sub(r'//.*', '', self.CREATE_FILE.read_text(encoding='utf-8'))
        arrays = [re.findall(r'"([^"]*)"', body) for body in re.findall(r'\[("[^\]]*)\]', code)]
        built = sorted({tuple(a) for a in arrays if a and a[0] in ('vm', 'fw')})
        self.assertEqual(built, [
            ('fw', 'catalog', '--json'), ('vm', 'create'), ('vm', 'create', '--resume'),
            ('vm', 'create-status', '--json'),
        ])
        # Every create and resume carries the system authentication dialog option, once.
        self.assertEqual(code.count('"--root-popup"'), 2)
        self.assertEqual(code.count('arguments.append("--root-popup")'), 2)
        # The tool change is accepted only when the caller passes the confirmation.
        self.assertEqual(code.count('"--accept-tool-change"'), 1)
        self.assertRegex(code, r'if acceptToolChange \{\s*arguments\.append\("--accept-tool-change"\)')
        # less is refused before anything is built.
        self.assertIn('self != .less', code)
        self.assertRegex(code, r'guard request\.variant\.isAvailable else \{\s*return \.variantUnavailable')
        self.assertRegex(code, r'guard let variant = VPhoneLaunchpadCreateVariant\(rawValue: variant\), variant\.isAvailable')
        # Every machine command names its library root.
        for start in (r'\["vm", "create", request\.name\] \+ request\.machine\.libraryArguments',
                      r'\["vm", "create", machine\.name, "--resume"\] \+ machine\.libraryArguments',
                      r'\["vm", "create-status", machine\.name, "--json"\] \+ machine\.libraryArguments'):
            self.assertRegex(code, start)
        self.assertIn('private init(_ kind: Kind, _ arguments: [String])', code)

    def test_b4_status_runs_once_after_the_create_exits(self):
        sources = launchpad_swift()
        calls = {path: re.sub(r'//.*', '', text).count('VPhoneLaunchpadCreateCommand.status(')
                 for path, text in sources.items() if path != self.CREATE_FILE}
        self.assertEqual({path: n for path, n in calls.items() if n}, {self.CREATION: 1})
        code = re.sub(r'//.*', '', self.CREATION.read_text(encoding='utf-8'))
        follow = code.split('private func follow(', 1)[1].split('public func cancel()', 1)[0]
        self.assertLess(follow.index('while child.isRunning'), follow.index('await waiter.value'))
        self.assertLess(follow.index('await waiter.value'), follow.index('VPhoneLaunchpadCreateCommand.status('))
        # The periodic list refresh reads no checkpoint and runs no create command.
        library = re.sub(r'//.*', '', (ROOT / 'sources/VPhoneLaunchpadKit/VPhoneLaunchpadMachineLibrary.swift').read_text())
        refresh = library.split('public func refresh() async {', 1)[1].split('// MARK: - Start and stop', 1)[0]
        self.assertNotIn('VPhoneLaunchpadCreate', refresh)
        self.assertNotIn('Checkpoint', refresh)

    def test_only_vm_list_stop_and_launch_are_run(self):
        runs, starts, typed, catalog = [], [], [], []
        for path, text in launchpad_swift().items():
            runs += re.findall(r'\.run\(\s*\[([^\]]*)\]', text)
            starts += re.findall(r'commandLine\.start\(\s*(\w+)', text)
            typed += re.findall(r'commandLine\.run\(\s*(\w+)\s*\)', text)
            catalog += re.findall(r'commandLine\.run\(\s*VPhoneLaunchpadCreateCommand\.(\w+)', text)
        self.assertEqual(sorted(re.findall(r'"([^"]+)"', arguments)[:3] for arguments in runs),
                         [['vm', 'list', '--json'], ['vm', 'stop']])
        # B2 `vm launch`; B4 `vm create` and `--resume`, a whitelisted command value.
        self.assertEqual(sorted(starts), ['arguments', 'command'])
        # B3/B5: everything else runs a whitelisted command value; B4 adds the
        # one create-status after a create run and the firmware catalog.
        self.assertEqual(sorted(typed), ['command', 'command', 'command', 'status'])
        self.assertEqual(catalog, ['catalog'])
        library = (ROOT / 'sources/VPhoneLaunchpadKit/VPhoneLaunchpadMachineLibrary.swift').read_text()
        self.assertIn('var arguments = ["vm", "launch", machine.name] + machine.libraryArguments', library)

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
        # B6: the embedded-CLI tests have their own target, outside `test` and `test_swift`.
        self.assertRegex(makefile, r'\ntest_launchpad_cli:\n\tzsh \$\(SCRIPTS\)/run_launchpad_cli_tests\.sh\n')
        for target in ('test', 'test_python', 'test_swift'):
            recipe = re.search(rf'\n{target}:[^\n]*\n((?:\t[^\n]*\n)*)', makefile)
            self.assertIsNotNone(recipe, target)
            self.assertNotIn('launchpad', recipe.group(0), target)
        self.assertNotIn('RealCLI', (ROOT / 'scripts/run_tests.py').read_text())

    # B6: the menu bar menu opens the window, starts or stops a machine and quits.
    MENU_BAR = ROOT / 'sources/VPhoneLaunchpad/VPhoneLaunchpadMenuBarMenu.swift'
    MENU_BAR_KIT = ROOT / 'sources/VPhoneLaunchpadKit/VPhoneLaunchpadMenuBar.swift'

    def test_b6_menu_bar_offers_only_open_start_stop_and_quit(self):
        code = re.sub(r'//.*', '', self.MENU_BAR.read_text(encoding='utf-8'))
        menu = code.split('struct VPhoneLaunchpadMenuBarMenu', 1)[1].split('enum VPhoneLaunchpadMainWindow', 1)[0]
        self.assertEqual(sorted(set(re.findall(r'Button\("([^"]*)"', menu))),
                         ['Open Launchpad', 'Quit', 'Start', 'Start Headless', 'Stop'])
        self.assertEqual(re.findall(r'Button\((?!")', menu), [])
        # Machine actions go through the library's menu entry point only.
        self.assertEqual(re.findall(r'library\.(\w+)\(', menu), ['performMenuBarAction'])
        for avoided in ('panels', 'sheet', 'present(', 'Edit', 'Create', 'import', 'Import', 'delete', 'export'):
            self.assertNotIn(avoided, menu)
        kit = re.sub(r'//.*', '', self.MENU_BAR_KIT.read_text(encoding='utf-8'))
        perform = kit.split('func performMenuBarAction', 1)[1]
        self.assertEqual(re.findall(r'\b(start|stop)\(([^)]*)\)', perform),
                         [('start', 'machine'), ('start', 'machine, headless: true'), ('stop', 'machine')])
        self.assertIn('guard canStop(machine) else', perform)
        # Closing the last window quits unless menu bar mode is on.
        app = (ROOT / 'sources/VPhoneLaunchpad/VPhoneLaunchpadApp.swift').read_text()
        self.assertRegex(app, r'applicationShouldTerminateAfterLastWindowClosed\(_: NSApplication\) -> Bool \{\s*'
                              r'VPhoneLaunchpadMenuBar\.terminatesAfterLastWindowClosed\(\)\s*\}')


if __name__ == '__main__':
    unittest.main()
