import platform
import subprocess
import tempfile
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == 'Darwin', 'macOS SDK required')
class LaunchHookSpawnTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='launchhook-spawn-')
        cls.directory = Path(cls.temp.name)
        source = (ROOT / 'sources/VPhoneGuestComponents/LaunchHook/launchdhook-vphone.c').read_text()
        # Preserve the actual hook logic; avoid activating dyld interposition in
        # the host test executable. The spawn callee is an observing substitute.
        source = source.replace('../Shared/', str(ROOT / 'sources/VPhoneGuestComponents/Shared') + '/')
        source = source.replace('__DATA,__interpose', '__DATA,__vp_test')
        fixture = (ROOT / 'tests/fixtures/launchhook_spawn_harness.c').read_text()
        unit = cls.directory / 'harness.c'
        unit.write_text('#define posix_spawn vpTestPosixSpawn\n#define posix_spawnp vpTestPosixSpawnP\n' + source + '\n' + fixture)
        cls.binary = cls.directory / 'harness'
        result = subprocess.run(['xcrun', 'clang', '-Wno-deprecated-declarations', str(unit),
                                 str(ROOT / 'sources/VPhoneGuestComponents/Shared/RootHideLoaderLinks.c'),
                                 str(ROOT / 'sources/VPhoneGuestComponents/Shared/VPhoneSimulationAccess.c'),
                                 '-o', str(cls.binary)],
                                capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def check_spawn(self, path, expected, mode=None, environment=None):
        result = subprocess.run([str(self.binary), path, expected] + ([mode] if mode else []) + ([environment] if environment else []), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_xpcproxy_receives_systemhook(self):
        self.check_spawn('/usr/libexec/xpcproxy', 'inject')

    def test_direct_cameracaptured_receives_systemhook(self):
        self.check_spawn('/usr/libexec/cameracaptured', 'inject')

    def test_unrelated_daemon_remains_unmodified(self):
        self.check_spawn('/usr/libexec/logd', 'plain')

    def test_spawnp_xpcproxy_receives_systemhook(self):
        self.check_spawn('/usr/libexec/xpcproxy', 'inject', 'spawnp')

    def test_spawnp_cameracaptured_receives_systemhook(self):
        self.check_spawn('/usr/libexec/cameracaptured', 'inject', 'spawnp')

    def test_spawnp_unrelated_daemon_remains_unmodified(self):
        self.check_spawn('/usr/libexec/logd', 'plain', 'spawnp')

    def test_safe_mode_is_preserved_for_camera_on_both_spawn_paths(self):
        for mode in ['spawn', 'spawnp']:
            for flag in ['DISABLE_TWEAKS=1', '_SafeMode=1', '_MSSafeMode=1']:
                with self.subTest(mode=mode, flag=flag):
                    self.check_spawn('/usr/libexec/cameracaptured', 'plain', mode, flag)

    def test_app_receives_systemhook_on_both_spawn_paths(self):
        for mode in ['spawn', 'spawnp']:
            self.check_spawn('/Applications/Example.app/Example', 'inject', mode)
