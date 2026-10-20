"""Regression of the actual zsh Undo path with isolated APFS replacements."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

from tests import test_guest_undo_transaction as fixtures


class GuestUndoDriverTests(unittest.TestCase):
    def test_actual_driver_restores_publishes_and_retains_install_inputs(self):
        f = fixtures.GuestUndoTransactionTests(); f.setUp(); self.addCleanup(f.doCleanups)
        root = f.vm.parent/'driver'; (root/'scripts').mkdir(parents=True)
        source = fixtures.fixtures.fixtures.plan_tests.ROOT
        shutil.copyfile(source/'scripts/vm_lock.py', root/'scripts/vm_lock.py')
        driver = (source/'scripts/cfw_install_host.sh').read_text()
        guard = 'if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then'
        self.assertIn(guard,driver)
        (root/'scripts/cfw_install_host.sh').write_text(driver.replace(guard,'if false; then'))
        bins = root/'.tools/bin'; bins.mkdir(parents=True)
        stub = bins/'stub'
        stub.write_text('''#!/bin/zsh
print -r -- "${0:t} $*" >> "$TEST_LOG"
case "${0:t}" in
 python) exec "$TEST_PYTHON" "$TEST_UNDO_HELPER" python "$@" ;;
 lsof) exit 1 ;;
 hdiutil|diskutil|umount) exec "$TEST_PYTHON" "$TEST_UNDO_HELPER" tool "${0:t}" "$@" ;;
 chown) exit 0 ;;
esac
exit 1
''')
        stub.chmod(0o755)
        for name in ('python','lsof','hdiutil','diskutil','umount','chown'): (bins/name).symlink_to(stub)
        filesystem = root/'filesystem'; shutil.copytree(f.current_root,filesystem,copy_function=shutil.copy2)
        mounts = root/'mounts'; mounts.write_text('')
        zdot = root/'zdot'; zdot.mkdir()
        (zdot/'.zshenv').write_text('function /sbin/mount() { cat "$TEST_MOUNTS"; }\n')
        env = dict(os.environ, VPHONE_PYTHON=str(bins/'python'), TEST_PYTHON=sys.executable,
            TEST_UNDO_HELPER=str(source/'tests/cfw_guest_undo_driver_fixture.py'), TEST_UNDO_FILESYSTEM=str(filesystem),
            TEST_UNDO_STATE=str(root/'attachment.json'), TEST_MOUNTS=str(mounts), TEST_LOG=str(root/'calls'), ZDOTDIR=str(zdot))
        # Ensure Undo itself preserves unrelated inputs even without this flag.
        env.pop('VPHONE_KEEP_ARTIFACTS',None)
        for key in ('VPHONE_INVOKER_UID','VPHONE_INVOKER_GID','SUDO_UID','SUDO_GID'): env.pop(key,None)
        inputs = f.vm/'cfw_input'; inputs.mkdir(); (inputs/'keep').write_bytes(b'original input')
        result = subprocess.run(['/bin/zsh',str(root/'scripts/cfw_install_host.sh'),'--variant','regular',
            '--generation',f.fixture.generation,'--undo-declaration','dyld-boot-maxslide',str(f.vm)],
            env=env,pass_fds=(f.fixture.fixture.f.lock_fd,),capture_output=True,timeout=30)
        self.assertEqual(result.returncode,0,result.stdout.decode()+result.stderr.decode())
        self.assertIn(b'guest DSC Undo published',result.stdout)
        expected = fixtures.fixtures.fixtures.cache(b'changed')
        self.assertEqual((f.vm/'Disk.img').read_bytes(),expected)
        self.assertEqual((inputs/'keep').read_bytes(),b'original input')
        self.assertNotIn('guestEnvironment',json.loads((f.vm/'launchpad.json').read_bytes()))
        calls = (root/'calls').read_text()
        self.assertLess(calls.index('prepare-undo'),calls.index('apply-undo'))
        self.assertLess(calls.index('apply-undo'),calls.index('verify-final'))
        self.assertIn('-nomount -readonly',calls)
        self.assertNotIn('apfs_snap_rename.py',calls)
        self.assertFalse(list(f.vm.glob('.cfw_disk.*')))


if __name__ == '__main__': unittest.main()
