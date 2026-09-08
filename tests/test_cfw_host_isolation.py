"""Run the host driver with disposable installers and disk-command doubles."""
import os
import plistlib
from pathlib import Path
import shutil
import sys
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
        shutil.copyfile(ROOT / "scripts/vm_lock.py", scripts / "vm_lock.py")
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
 hdiutil:attach) if [[ ${BAD_ATTACH:-0} == 1 ]]; then print unexpected-output; else cat "$TEST_ATTACH_PLIST"; fi; exit ${FAIL_ATTACH:-0};;
 umount:*) if [[ ${TRANSIENT_UMOUNT:-0} == 1 && ! -e "$TEST_MOUNTS.retry" ]]; then touch "$TEST_MOUNTS.retry"; exit 16; fi; [[ ${FAIL_UMOUNT:-0} == 1 ]] && exit 16; "$TEST_PYTHON" -c 'import os,pathlib,sys; p=pathlib.Path(os.environ["TEST_MOUNTS"]); p.write_text("".join(l for l in p.read_text().splitlines(True) if " on "+sys.argv[1]+" (" not in l))' "$1"; exit 0;;
 diskutil:info) [[ ${FAIL_DISCOVERY:-0} == 1 ]] && exit 9; print '<?xml version="1.0"?><plist version="1.0"><dict><key>APFSContainerReference</key><string>disk92</string></dict></plist>'; exit 0;;
 diskutil:apfs) print 'APFS Volume Disk (Role): disk92s1 (System)'; print 'Name: System (Case-sensitive)'; exit 0;;
 hdiutil:detach|diskutil:eject) [[ ${FAIL_CLEANUP:-0} == 1 ]] && exit 1; if [[ -f "$TEST_MOUNTS" ]]; then "$TEST_PYTHON" -c 'import os,pathlib,sys; p=pathlib.Path(os.environ["TEST_MOUNTS"]); p.write_text("".join(l for l in p.read_text().splitlines(True) if " on "+sys.argv[1]+" (" not in l))' "$2"; fi; exit 0;;
 python:*) if [[ "$1" == */vm_lock.py || "$1" == -c ]]; then exec "$TEST_PYTHON" "$@"; fi; exit 0;;
esac
exit 0
''')
        stub.chmod(0o755)
        for name in ('lsof', 'hdiutil', 'diskutil', 'umount', 'python', 'chown'):
            (bins / name).symlink_to(stub)
        self.env = dict(os.environ, TEST_LOG=str(self.root / 'calls'),
                        VPHONE_PYTHON=str(bins / 'python'), VPHONE_KEEP_ARTIFACTS='1', TEST_PYTHON=sys.executable)
        self.env.pop('SUDO_USER', None)
        attach = self.root / 'attach.plist'
        attach.write_bytes(plistlib.dumps({'system-entities': [{'dev-entry': '/dev/disk91'}, {'dev-entry': '/dev/disk91s1'}]}))
        self.env['TEST_ATTACH_PLIST'] = str(attach)
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
        vm.mkdir(exist_ok=True)
        (vm / 'Disk.img').touch()
        proc = subprocess.Popen(['/bin/zsh', str(self.driver), '--variant', 'exp', str(vm)],
                                    env=dict(self.env, TEST_MOUNTS=str(vm / "mount-table"), **env), stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        def stop():
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.communicate(timeout=10)
        self.addCleanup(stop)
        return vm, proc

    def finish(self, proc):
        out, err = proc.communicate(timeout=30)
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

    def test_same_vm_shell_entry_rejects_second_installer(self):
        vm, first = self.start(INSTALL_SLEEP='3')
        deadline = time.monotonic() + 15
        while not (vm / 'ready').exists() and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertTrue((vm / 'ready').exists())
        _, second = self.start()
        rc, output = self.finish(second)
        self.assertNotEqual(rc, 0, output)
        self.assertEqual(self.finish(first)[0], 0)
        self.assertEqual((self.root / 'calls').read_text().count('hdiutil attach'), 1)

    def test_transient_unmount_failure_retries_before_snapshot_edit(self):
        vm, proc = self.start(TRANSIENT_UMOUNT='1')
        rc, output = self.finish(proc)
        self.assertEqual(rc, 0, output)
        self.assertTrue((vm / 'mount-table.retry').exists())
        calls = (self.root / 'calls').read_text()
        self.assertEqual(sum(line.startswith('umount ') for line in calls.splitlines()), 2)
        self.assertIn('apfs_snap_rename.py', calls)

    def test_previous_mount_blocks_install_and_ownership_changes(self):
        vm = self.root / 'vm'
        vm.mkdir()
        (vm / 'mount-table').write_text(f'/dev/disk81s1 on {vm.resolve()}/.cfw_temp/mnt_sysos_hv_vmm (apfs, local)\n')
        _, proc = self.start(SUDO_USER='test-user')
        rc, output = self.finish(proc)
        self.assertNotEqual(rc, 0, output)
        calls = (self.root / 'calls').read_text()
        self.assertNotIn('hdiutil attach', calls)
        self.assertNotIn('chown ', calls)

    def test_attach_with_synthesized_container_detaches_physical_disk(self):
        Path(self.env['TEST_ATTACH_PLIST']).write_bytes(plistlib.dumps({'system-entities': [
            {'dev-entry': '/dev/disk91', 'content-hint': 'GUID_partition_scheme'},
            {'dev-entry': '/dev/disk91s1', 'content-hint': '7C3457EF-0000-11AA-AA11-00306543ECAC'},
            {'dev-entry': '/dev/disk92', 'content-hint': 'EF57347C-0000-11AA-AA11-00306543ECAC'},
            {'dev-entry': '/dev/disk92s1', 'content-hint': '41504653-0000-11AA-AA11-00306543ECAC'},
        ]}))
        _, proc = self.start()
        rc, output = self.finish(proc)
        self.assertEqual(rc, 0, output)
        calls = (self.root / 'calls').read_text()
        self.assertIn('hdiutil detach /dev/disk91', calls)
        self.assertNotIn('hdiutil detach /dev/disk92', calls)

    def test_unknown_attach_output_is_retained(self):
        vm, proc = self.start(BAD_ATTACH='1')
        rc, output = self.finish(proc)
        self.assertNotEqual(rc, 0, output)
        logs = list(vm.glob('.cfw_mount.*/attach.log'))
        self.assertEqual(len(logs), 1)
        self.assertIn('unexpected-output', logs[0].read_text())
        self.assertNotIn('apfs_snap_rename.py', (self.root / 'calls').read_text())

    def test_failed_volume_unmount_does_not_detach_base_disk(self):
        vm, proc = self.start(FAIL_UMOUNT='1')
        rc, output = self.finish(proc)
        self.assertNotEqual(rc, 0, output)
        calls = (self.root / 'calls').read_text()
        self.assertNotIn('hdiutil detach /dev/disk91', calls)
        self.assertNotIn('apfs_snap_rename.py', calls)
        self.assertTrue(list(vm.glob('.cfw_mount.*/attach.log')))

    def test_ownership_restoration_never_recurses_over_bundle(self):
        vm, proc = self.start(SUDO_USER='test-user')
        rc, output = self.finish(proc)
        self.assertEqual(rc, 0, output)
        calls = (self.root / 'calls').read_text()
        self.assertNotIn(f'chown -R test-user {vm}', calls)

    def test_interrupt_cleans_owned_mounts_and_preserves_signal_status(self):
        vm, proc = self.start(INSTALL_SLEEP='30')
        deadline = time.monotonic() + 15
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
