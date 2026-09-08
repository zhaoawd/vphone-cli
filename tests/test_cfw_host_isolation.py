"""Run the host driver with disposable installers and disk-command doubles."""
import os
from pathlib import Path
import signal
import time
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class HostIsolationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='cfw host test ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        scripts = self.root / 'scripts'
        scripts.mkdir()
        driver = (ROOT / 'scripts/cfw_install_host.sh').read_text()
        # Only bypass privilege escalation; no real disk commands are permitted.
        guard = 'if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then'
        self.assertIn(guard, driver)
        (scripts / 'cfw_install_host.sh').write_text(driver.replace(guard, 'if false; then'))
        bins = self.root / '.tools/bin'
        bins.mkdir(parents=True)
        stub = bins / 'stub'
        stub.write_text('''#!/bin/zsh
print -r -- "${0:t} $*" >> "$TEST_LOG"
case "${0:t}:$1" in
 lsof:*) exit 1;;
 hdiutil:attach) print /dev/disk91; exit ${FAIL_ATTACH:-0};;
 diskutil:info) [[ ${FAIL_DISCOVERY:-0} == 1 ]] && exit 9; print '<?xml version="1.0"?><plist version="1.0"><dict><key>APFSContainerReference</key><string>disk92</string></dict></plist>'; exit 0;;
 diskutil:apfs) print 'APFS Volume Disk (Role): disk92s1 (System)'; print 'Name: System (Case-sensitive)'; exit 0;;
 hdiutil:detach|diskutil:eject) exit ${FAIL_CLEANUP:-0};;
 python:*) exit 0;;
esac
exit 0
''')
        stub.chmod(0o755)
        for name in ('lsof', 'hdiutil', 'diskutil', 'umount', 'python'):
            (bins / name).symlink_to(stub)
        self.env = dict(os.environ, TEST_LOG=str(self.root / 'calls'),
                        VPHONE_PYTHON=str(bins / 'python'), VPHONE_KEEP_ARTIFACTS='1')
        self.env.pop('SUDO_USER', None)
        zdot = self.root / 'zdot'
        zdot.mkdir()
        (zdot / '.zshenv').write_text('function /sbin/mount() { cat "$TEST_MOUNTS" 2>/dev/null; return 0; }\n')
        self.env['ZDOTDIR'] = str(zdot)
        for variant in ('', '_dev', '_jb', '_exp'):
            (scripts / f'cfw_install{variant}.sh').write_text('''#!/bin/zsh
print -r -- "${CFW_HOST_MNT:-missing}" > "$PWD/run-dir"
[[ -n ${CFW_HOST_MNT:-} && -d $CFW_HOST_MNT ]] || exit 72
mkdir -p "$CFW_HOST_MNT/mnt1" "$CFW_HOST_MNT/mnt_sysos_hv_vmm"
print -r -- "/dev/disk92s1 on $CFW_HOST_MNT/mnt1 (apfs, local)" > "$TEST_MOUNTS"
print -r -- "/dev/disk93s1 on $CFW_HOST_MNT/mnt_sysos_hv_vmm (apfs, local)" >> "$TEST_MOUNTS"
print -r -- '/dev/disk80s1 on /private/tmp/another-task/mnt1 (apfs, local)' >> "$TEST_MOUNTS"
print ready > "$PWD/ready"
sleep ${INSTALL_SLEEP:-0.2}
exit ${INSTALL_EXIT:-0}
''')
        self.driver = scripts / 'cfw_install_host.sh'

    def start(self, name='vm', **env):
        vm = self.root / name
        vm.mkdir()
        (vm / 'Disk.img').touch()
        proc = subprocess.Popen(['/bin/zsh', str(self.driver), '--variant', 'exp', str(vm)],
                                    env=dict(self.env, TEST_MOUNTS=str(vm / "mount-table"), **env), stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        self.addCleanup(lambda: proc.poll() is None and proc.kill())
        return vm, proc

    def finish(self, proc):
        out, err = proc.communicate(timeout=10)
        return proc.returncode, (out + err).decode()

    def test_concurrent_runs_use_distinct_directories_and_remove_them(self):
        vm1, p1 = self.start('vm1')
        vm2, p2 = self.start('vm2')
        results = [self.finish(p) for p in (p1, p2)]
        for rc, output in results:
            self.assertEqual(rc, 0, output)
        dirs = [(vm / 'run-dir').read_text().strip() for vm in (vm1, vm2)]
        self.assertNotEqual(*dirs)
        for directory in dirs:
            self.assertFalse(Path(directory).exists())
        calls = (self.root / 'calls').read_text()
        self.assertNotIn('/private/tmp/cfwhost/', calls)
        self.assertNotIn('/private/tmp/another-task/', calls)
        for directory in dirs:
            self.assertIn(f'umount {directory}/mnt1', calls)
            self.assertIn(f'hdiutil detach {directory}/mnt_sysos_hv_vmm', calls)

    def test_interrupt_cleans_owned_mounts_and_preserves_signal_status(self):
        vm, proc = self.start(INSTALL_SLEEP='30')
        deadline = time.monotonic() + 5
        while not (vm / 'ready').exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue((vm / 'ready').exists())
        os.killpg(proc.pid, signal.SIGINT)
        rc, output = self.finish(proc)
        self.assertEqual(rc, 130, output)
        self.assertFalse(Path((vm / 'run-dir').read_text().strip()).exists())
        self.assertNotIn('/private/tmp/another-task/', (self.root / 'calls').read_text())

    def test_partial_attach_failure_still_detaches_reported_disk(self):
        _, p = self.start(FAIL_ATTACH='19')
        rc, output = self.finish(p)
        self.assertEqual(rc, 19, output)
        self.assertIn('hdiutil detach /dev/disk91', (self.root / 'calls').read_text())

    def test_discovery_failure_detaches_the_attached_disk(self):
        _, p = self.start(FAIL_DISCOVERY='1')
        rc, _ = self.finish(p)
        self.assertNotEqual(rc, 0)
        self.assertIn('hdiutil detach /dev/disk91', (self.root / 'calls').read_text())

    def test_cleanup_failure_prevents_offline_snapshot_edit(self):
        _, p = self.start(FAIL_CLEANUP='1')
        rc, _ = self.finish(p)
        self.assertNotEqual(rc, 0)
        self.assertNotIn('apfs_snap_rename.py', (self.root / 'calls').read_text())

    def test_installer_failure_survives_cleanup_failure(self):
        _, p = self.start(INSTALL_EXIT='37', FAIL_CLEANUP='1')
        rc, output = self.finish(p)
        self.assertEqual(rc, 37, output)


if __name__ == '__main__':
    unittest.main()
