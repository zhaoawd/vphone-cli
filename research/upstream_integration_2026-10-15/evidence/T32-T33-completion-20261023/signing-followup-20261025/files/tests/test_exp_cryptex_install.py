"""Run the installer's real Cryptex branch on isolated directory fixtures."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class EXPCryptexInstallTests(unittest.TestCase):
    def run_stage(self, variant, reinstall='0'):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            system = root / 'mnt1'
            for name in ('OS', 'App'):
                installed = system / 'System/Cryptexes' / name
                installed.mkdir(parents=True)
                (installed / 'member').write_bytes(b'original installed content')
            for name in ('sysos', 'appos'):
                source = root / ('mnt_' + name)
                source.mkdir()
                (source / 'member').write_bytes(b'current cached content')
            (system / 'System/Library/Caches').mkdir(parents=True)
            (system / 'System/DriverKit/System/Library').mkdir(parents=True)
            stage = root / 'stage'
            stage.mkdir()
            script = (ROOT / 'scripts/cfw_install.sh').read_text()
            body = script[script.index('CRYPTEX_OS_COUNT=0'):script.index('# Some userland versions')]
            # Only mounts and cache preparation are modeled. The production
            # branch, removals, copies and symlinks execute on private fixtures.
            setup = '''set -euo pipefail
mount_vol() { :; }
cfw_cache_systemos() { :; }
cfw_cache_appos() { :; }
safe_detach() { :; }
assert_mount_under_vm() { :; }
mount_fixture() { :; }
cfw_guest_write() { "$@"; }
die() { print -u2 -- "$*"; exit 1; }
'''
            result = subprocess.run(['/bin/zsh', '-c', setup + body], capture_output=True, text=True,
                env=dict(os.environ, VPHONE_CFW_VARIANT=variant, VPHONE_REINSTALL_CRYPTEX=reinstall,
                         MNT1=str(system), CFW_HOST_MNT=str(root), TEMP_DIR=str(stage),
                         PYTHON3='mount_fixture', SCRIPT_DIR=str(ROOT / 'scripts'),
                         RESTORE_DIR=str(root), CRYPTEX_SYSOS='SystemOS', CRYPTEX_APPOS='AppOS'))
            self.assertEqual(result.returncode, 0, result.stderr)
            return [(system / 'System/Cryptexes' / name / 'member').read_bytes() for name in ('OS', 'App')]

    def test_exp_installs_current_cache_even_when_cryptex_is_present(self):
        self.assertEqual(self.run_stage('exp'), [b'current cached content'] * 2)

    def test_regular_keeps_existing_fast_path(self):
        self.assertEqual(self.run_stage('regular'), [b'original installed content'] * 2)

    def test_explicit_reinstall_still_copies_for_regular(self):
        self.assertEqual(self.run_stage('regular', '1'), [b'current cached content'] * 2)


if __name__ == '__main__':
    unittest.main()
