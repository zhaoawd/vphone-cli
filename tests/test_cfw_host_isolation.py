"""Run the host driver with disposable installers and disk-command doubles."""
import os
import plistlib
import re
from pathlib import Path
import shutil
import sys
import signal
import time
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class HostDriverFixture(unittest.TestCase):
    """Driver copy, disk-command doubles and disposable installers; no tests."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='cfw host test ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        scripts = self.root / 'scripts'
        scripts.mkdir()
        shutil.copyfile(ROOT / "scripts/vm_lock.py", scripts / "vm_lock.py")
        for name in ("cfw_disk_txn.py", "sparse_file.py"):
            if (ROOT / "scripts" / name).exists():
                shutil.copyfile(ROOT / "scripts" / name, scripts / name)
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
 lsof:*) [[ ${REAL_LSOF:-0} == 1 ]] && exec /usr/sbin/lsof "$@"; exit 1;;
 hdiutil:attach) print -r -- "${@[-1]}" > "$TEST_MOUNTS.attached"; if [[ ${BAD_ATTACH:-0} == 1 ]]; then print unexpected-output; else cat "$TEST_ATTACH_PLIST"; fi; exit ${FAIL_ATTACH:-0};;
 umount:*) if [[ ${TRANSIENT_UMOUNT:-0} == 1 && ! -e "$TEST_MOUNTS.retry" ]]; then touch "$TEST_MOUNTS.retry"; exit 16; fi; [[ ${FAIL_UMOUNT:-0} == 1 ]] && exit 16; "$TEST_PYTHON" -c 'import os,pathlib,sys; p=pathlib.Path(os.environ["TEST_MOUNTS"]); p.write_text("".join(l for l in p.read_text().splitlines(True) if " on "+sys.argv[1]+" (" not in l))' "$1"; exit 0;;
 diskutil:info) [[ ${FAIL_DISCOVERY:-0} == 1 ]] && exit 9; print '<?xml version="1.0"?><plist version="1.0"><dict><key>APFSContainerReference</key><string>disk92</string></dict></plist>'; exit 0;;
 diskutil:apfs) print 'APFS Volume Disk (Role): disk92s1 (System)'; print 'Name: System (Case-sensitive)'; exit 0;;
 hdiutil:detach|diskutil:eject) [[ ${FAIL_CLEANUP:-0} == 1 ]] && exit 1; if [[ -f "$TEST_MOUNTS" ]]; then "$TEST_PYTHON" -c 'import os,pathlib,sys; p=pathlib.Path(os.environ["TEST_MOUNTS"]); p.write_text("".join(l for l in p.read_text().splitlines(True) if " on "+sys.argv[1]+" (" not in l))' "$2"; fi; exit 0;;
 python:*) if [[ "$1" == */vm_lock.py || "$1" == -c ]]; then exec "$TEST_PYTHON" "$@"; fi
   if [[ "$1" == */cfw_disk_txn.py ]]; then exec "$TEST_PYTHON" "$TEST_TXN_HARNESS" "$@"; fi
   if [[ "$1" == */apfs_snap_rename.py ]]; then [[ ${FAIL_SNAP:-0} == 1 ]] && exit 5; exec "$TEST_PYTHON" -c 'import sys; f=open(sys.argv[1],"r+b"); f.seek(1024); f.write(b"SNAPSHOT-FLIPPED")' "$2"; fi
   exit 0;;
esac
exit 0
''')
        stub.chmod(0o755)
        for name in ('lsof', 'hdiutil', 'diskutil', 'umount', 'python', 'chown'):
            (bins / name).symlink_to(stub)
        self.env = dict(os.environ, TEST_LOG=str(self.root / 'calls'),
                        VPHONE_PYTHON=str(bins / 'python'), VPHONE_KEEP_ARTIFACTS='1', TEST_PYTHON=sys.executable,
                        TEST_TXN_HARNESS=str(ROOT / 'tests/cfw_disk_txn_faults.py'))
        for name in ('REAL_LSOF', 'FAIL_SNAP', 'CFW_TXN_FAULTS', 'VPHONE_VM_LOCK_FD', 'VPHONE_CFW_LOCK_REEXEC'):
            self.env.pop(name, None)
        self.env.pop('SUDO_USER', None)
        self.env.pop('SUDO_UID', None)
        self.env.pop('FORCE_DSC_MAXSLIDE', None)
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
print -r -- "${0:t} ${FORCE_DSC_MAXSLIDE-<unset>}" > "$PWD/installer-env"
[[ -n ${CFW_HOST_MNT:-} && -d $CFW_HOST_MNT ]] || exit 72
mkdir -p "$CFW_HOST_MNT/mnt1" "$CFW_HOST_MNT/mnt_sysos_hv_vmm"
print -r -- "/dev/disk92s1 on $CFW_HOST_MNT/mnt1 (apfs, local)" > "$TEST_MOUNTS"
print -r -- "/dev/disk93s1 on $CFW_HOST_MNT/mnt_sysos_hv_vmm (apfs, local)" >> "$TEST_MOUNTS"
print -r -- '/dev/disk80s1 on /private/tmp/another-task/mnt1 (apfs, local)' >> "$TEST_MOUNTS"
mkdir -p "$PWD/.cfw_temp/sub" "$PWD/cfw_input"
print signed > "$PWD/.vphoned.signed"
print -r -- "${SUDO_UID-<unset>} ${SUDO_USER-<unset>}" > "$PWD/installer-sudo-env"
if [[ ${LINKED_ENTRIES:-0} == 1 ]]; then
  print plain > "$PWD/cfw_input/plain"
  ln "$PWD/Disk.img" "$PWD/cfw_input/linked"
  ln -s /etc "$PWD/cfw_input/symlink"
fi
[[ ${STRAY_FILE:-0} == 1 ]] && print stray > "$CFW_HOST_MNT/mnt1/leftover"
[[ ${LATE_MOUNT:-0} == 1 ]] && print -r -- "/dev/disk85s1 on $PWD/.cfw_temp/sub (apfs, local)" >> "$TEST_MOUNTS"
if [[ -f "$TEST_MOUNTS.attached" ]]; then
  "$TEST_PYTHON" -c 'import sys; f=open(sys.argv[1],"r+b"); f.seek(512); f.write(b"CFW-PATCHED")' "$(<"$TEST_MOUNTS.attached")"
fi
if [[ ${REPLACE_ORIGINAL:-0} == 1 ]]; then
  mv "$PWD/Disk.img" "$PWD/Disk.img.moved"
  print replacement > "$PWD/Disk.img"
fi
print ready > "$PWD/ready"
sleep ${INSTALL_SLEEP:-0.2}
exit ${INSTALL_EXIT:-0}
''')
        self.driver = scripts / 'cfw_install_host.sh'

    # Variables the doubles and the driver need on the authentication-dialog
    # path, where vphone-cli passes every variable inline (see bare_env).
    INLINE_KEYS = ('TEST_LOG', 'VPHONE_PYTHON', 'VPHONE_KEEP_ARTIFACTS', 'TEST_PYTHON', 'TEST_TXN_HARNESS',
                   'TEST_ATTACH_PLIST', 'ZDOTDIR')

    def bare_env(self):
        """Environment of `do shell script ... with administrator privileges`.

        `--root-popup` elevates through osascript, whose shell starts with a
        bare environment: no SUDO_USER/SUDO_UID/SUDO_GID and only the variables
        vphone-cli writes inline (VPhoneProcessRunner.runWithAdminPrivileges).
        """
        env = {key: self.env[key] for key in self.INLINE_KEYS}
        env['PATH'] = '/usr/bin:/bin:/usr/sbin:/sbin'
        return env

    def start(self, name='vm', variant='exp', bare=False, **env):
        vm = self.root / name
        vm.mkdir(exist_ok=True)
        if not (vm / 'Disk.img').exists():
            (vm / 'Disk.img').touch()
        base = self.bare_env() if bare else self.env
        proc = subprocess.Popen(['/bin/zsh', str(self.driver), '--variant', variant, str(vm)],
                                    env=dict(base, TEST_MOUNTS=str(vm / "mount-table"), **env), stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
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



class HostIsolationTests(HostDriverFixture):
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
        _, proc = self.start(**self.sudo_invoker())
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

    OWNER = f'{os.getuid()}:{os.getgid()}'

    def sudo_invoker(self, uid=None):
        """Variables sudo sets for the re-executed driver (`make cfw_install`, or
        vphone-cli's sudo path, which also passes VPHONE_INVOKER_UID/GID)."""
        return dict(SUDO_USER='test-user', SUDO_UID=str(os.getuid() if uid is None else uid), SUDO_GID=str(os.getgid()))

    def popup_invoker(self, uid=None):
        """Variables vphone-cli writes inline on the --root-popup path. SUDO_USER
        is forwarded for scripts/fetch_debs.sh; SUDO_UID and SUDO_GID are not."""
        return dict(SUDO_USER='test-user', VPHONE_INVOKER_UID=str(os.getuid() if uid is None else uid),
                    VPHONE_INVOKER_GID=str(os.getgid()))

    def calls(self):
        log = self.root / 'calls'
        return log.read_text() if log.exists() else ''

    def chowned_paths(self, owner=OWNER):
        paths = []
        for line in self.calls().splitlines():
            if line.startswith('chown '):
                prefix = f'chown -h {owner} '
                self.assertTrue(line.startswith(prefix), line)
                # The stub logs "$*"; every argument is an absolute path.
                paths += re.split(r' (?=/)', line[len(prefix):])
        return sorted(paths)

    def returned_artifacts(self, vm, published=True):
        """Every path the driver must hand back: install artifacts and the
        archived transaction record, never the bundle root or Disk.img."""
        real = vm.resolve()
        record = next(vm.glob('.cfw-history/*')).name
        history = f'{real}/.cfw-history'
        paths = [f'{real}/.vphoned.signed', f'{real}/.cfw_temp', f'{real}/.cfw_temp/sub', f'{real}/cfw_input',
                 history, f'{history}/{record}', f'{history}/{record}/transaction.json']
        if published:
            # T15: the previous Disk.img is kept in the record directory.
            paths.append(f'{history}/{record}/Disk.img')
        return sorted(paths)

    def test_ownership_restoration_never_recurses_over_bundle(self):
        vm, proc = self.start(**self.sudo_invoker())
        rc, output = self.finish(proc)
        self.assertEqual(rc, 0, output)
        # The published Disk.img and the bundle root are not touched.
        self.assertEqual(self.chowned_paths(), self.returned_artifacts(vm))
        self.assertNotIn('chown -R', self.calls())
        self.assertIn('restored ownership', output)

    def test_root_popup_path_returns_artifacts_without_sudo_variables(self):
        # The authentication dialog sets no SUDO_* variable; the uid and gid
        # vphone-cli passes inline decide the owner.
        vm, proc = self.start(bare=True, **self.popup_invoker())
        rc, output = self.finish(proc)
        self.assertEqual(rc, 0, output)
        self.assertEqual((vm / 'installer-sudo-env').read_text().strip(), '<unset> test-user')
        self.assertEqual(self.chowned_paths(), self.returned_artifacts(vm))
        self.assertIn('restored ownership', output)
        self.assertNotIn('NOT restored', output)

    def test_explicit_invoker_takes_precedence_over_sudo(self):
        vm, proc = self.start(**dict(self.sudo_invoker(uid=os.getuid() + 424242), **self.popup_invoker()))
        rc, output = self.finish(proc)
        self.assertEqual(rc, 0, output)
        self.assertEqual(self.chowned_paths(), self.returned_artifacts(vm))

    def test_failed_install_returns_artifacts_on_both_elevation_paths(self):
        for path, bare, invoker in (('sudo', False, self.sudo_invoker()), ('popup', True, self.popup_invoker())):
            with self.subTest(path=path):
                log = self.root / 'calls'
                log.unlink(missing_ok=True)
                vm, proc = self.start(f'vm-fail-{path}', bare=bare, INSTALL_EXIT='37', **invoker)
                rc, output = self.finish(proc)
                self.assertEqual(rc, 37, output)
                # Nothing was published: the record holds transaction.json only.
                self.assertFalse(list(vm.glob('.cfw-history/*/Disk.img')))
                self.assertEqual(self.chowned_paths(), self.returned_artifacts(vm, published=False))

    def test_interrupted_install_returns_artifacts(self):
        vm, proc = self.start(bare=True, INSTALL_SLEEP='30', **self.popup_invoker())
        deadline = time.monotonic() + 15
        while not (vm / 'ready').exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue((vm / 'ready').exists())
        os.killpg(proc.pid, signal.SIGINT)
        rc, output = self.finish(proc)
        self.assertEqual(rc, 130, output)
        self.assertEqual(self.chowned_paths(), self.returned_artifacts(vm, published=False))

    def test_malformed_invoker_ids_are_refused_before_any_change(self):
        cases = [
            ('popup-uid-text', True, dict(VPHONE_INVOKER_UID='kolar', VPHONE_INVOKER_GID='20')),
            ('popup-uid-negative', True, dict(VPHONE_INVOKER_UID='-1', VPHONE_INVOKER_GID='20')),
            ('popup-uid-leading-zero', True, dict(VPHONE_INVOKER_UID='0501', VPHONE_INVOKER_GID='20')),
            ('popup-gid-text', True, dict(VPHONE_INVOKER_UID=str(os.getuid()), VPHONE_INVOKER_GID='staff')),
            ('sudo-uid-text', False, dict(SUDO_USER='test-user', SUDO_UID='501;id')),
        ]
        for name, bare, invoker in cases:
            with self.subTest(case=name):
                vm, proc = self.start(f'vm-{name}', bare=bare, **invoker)
                rc, output = self.finish(proc)
                self.assertEqual(rc, 2, output)
                self.assertIn('refusing before any change', output)
                self.assertNotIn('hdiutil attach', self.calls())
                self.assertNotIn('chown ', self.calls())
                self.assertFalse(list(vm.glob('.cfw_disk.*')) + list(vm.glob('.cfw_mount.*')))
                self.assertFalse((vm / '.cfw-history').exists())

    def test_root_invoker_leaves_owners_unchanged(self):
        _, proc = self.start(bare=True, VPHONE_INVOKER_UID='0', VPHONE_INVOKER_GID='0')
        rc, output = self.finish(proc)
        self.assertEqual(rc, 0, output)
        self.assertNotIn('chown ', self.calls())
        self.assertIn('NOT restored: the invoker is root', output)

    def test_invoker_that_does_not_own_the_bundle_receives_nothing(self):
        # The uid is validated against the bundle directory's owner; the
        # artifacts of another account's bundle are not given to the invoker.
        for path, bare, invoker in (('sudo', False, self.sudo_invoker(uid=os.getuid() + 424242)),
                                    ('popup', True, self.popup_invoker(uid=os.getuid() + 424242))):
            with self.subTest(path=path):
                _, proc = self.start(f'vm-other-{path}', bare=bare, **invoker)
                rc, output = self.finish(proc)
                self.assertEqual(rc, 0, output)
                self.assertNotIn('chown ', self.calls())
                self.assertIn(f'does not own', output)
                self.assertIn('NOT restored', output)

    def test_ownership_restoration_skips_hard_links_and_symlinks(self):
        # Upstream VPhoneHostFilePermissions skips a regular file with more
        # than one link: it may name a file outside the VM directory.
        vm, proc = self.start(LINKED_ENTRIES='1', **self.sudo_invoker())
        rc, output = self.finish(proc)
        self.assertEqual(rc, 0, output)
        real = vm.resolve()
        self.assertIn(f'{real}/cfw_input/plain', self.chowned_paths())
        self.assertNotIn(f'{real}/cfw_input/linked', self.chowned_paths())
        self.assertNotIn(f'{real}/cfw_input/symlink', self.chowned_paths())
        # The installer double hard-links the original Disk.img, which T15
        # keeps as the previous disk in .cfw-history; it keeps its owner.
        previous = next(vm.glob('.cfw-history/*/Disk.img'))
        self.assertEqual(os.stat(previous).st_nlink, 2)
        self.assertNotIn(str(previous.resolve()), self.chowned_paths())

    def test_ownership_restoration_requires_a_known_invoker(self):
        _, proc = self.start(SUDO_USER='test-user')
        rc, output = self.finish(proc)
        self.assertEqual(rc, 0, output)
        self.assertNotIn('chown ', self.calls())
        self.assertIn('NOT restored: invoker uid unknown', output)

    def test_late_mount_beneath_vm_only_skips_ownership_restore(self):
        vm, proc = self.start(LATE_MOUNT='1', **self.sudo_invoker())
        rc, output = self.finish(proc)
        self.assertEqual(rc, 0, output)
        calls = (self.root / 'calls').read_text()
        self.assertIn('apfs_snap_rename.py', calls)
        self.assertNotIn('chown ', calls)
        self.assertIn('NOT restored', output)

    def test_stray_file_in_mount_dir_is_retained_without_failing_install(self):
        vm, proc = self.start(STRAY_FILE='1')
        rc, output = self.finish(proc)
        self.assertEqual(rc, 0, output)
        calls = (self.root / 'calls').read_text()
        self.assertIn('hdiutil detach /dev/disk91', calls)
        self.assertIn('apfs_snap_rename.py', calls)
        retained = list(vm.glob('.cfw_mount.*/mnt1/leftover'))
        self.assertEqual(len(retained), 1)
        self.assertFalse(list(vm.glob('.cfw_mount.*/attach.log')))
        self.assertIn('unexpected files retained', output)

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

    def test_removed_force_dsc_maxslide_is_reported_and_not_forwarded(self):
        # T13a: the opt-in is gone; every variant reports it and no installer sees it.
        notice = '[!] FORCE_DSC_MAXSLIDE has been removed'
        installers = {'regular': 'cfw_install.sh', 'dev': 'cfw_install_dev.sh',
                      'jb': 'cfw_install_jb.sh', 'exp': 'cfw_install_exp.sh'}
        for variant, installer in installers.items():
            for value in ('1', '0'):
                with self.subTest(variant=variant, value=value):
                    vm, p = self.start(f'vm-{variant}-{value}', variant=variant, FORCE_DSC_MAXSLIDE=value)
                    rc, output = self.finish(p)
                    self.assertEqual(rc, 0, output)
                    self.assertEqual(output.count(notice), 1, output)
                    self.assertEqual((vm / 'installer-env').read_text().strip(), f'{installer} <unset>')
        vm, p = self.start('vm-unset', variant='regular')
        rc, output = self.finish(p)
        self.assertEqual(rc, 0, output)
        self.assertNotIn('FORCE_DSC_MAXSLIDE', output)
        self.assertEqual((vm / 'installer-env').read_text().strip(), 'cfw_install.sh <unset>')


if __name__ == '__main__':
    unittest.main()
