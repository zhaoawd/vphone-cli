"""T15: CFW writes only a copy of Disk.img; the original is published over atomically.

The host driver runs with disk-command doubles (see HostDriverFixture). The
attach double records the image it was given; the installer double writes a
marker into that image and the snapshot double writes another, so a write that
reaches the original Disk.img is visible as a changed SHA-256.
"""
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_cfw_host_isolation import HostDriverFixture  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]

DISK_SIZE = 32 << 20


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


class DiskTransactionTests(HostDriverFixture):
    def make_disk(self, name='vm'):
        vm = self.root / name
        vm.mkdir(exist_ok=True)
        disk = vm / 'Disk.img'
        with open(disk, 'wb') as stream:
            # Sparse like a VM disk: data at the head, a hole, data near the end.
            stream.truncate(DISK_SIZE)
            stream.write(os.urandom(256 << 10))
            stream.seek(DISK_SIZE - (64 << 10))
            stream.write(os.urandom(32 << 10))
        info = disk.stat()
        self.assertLess(info.st_blocks * 512, DISK_SIZE // 2, 'test disk is not sparse')
        return vm, sha256(disk), info.st_ino

    def calls(self):
        log = self.root / 'calls'
        return log.read_text() if log.exists() else ''

    def records(self, vm):
        return [json.loads(path.read_text()) for path in sorted(vm.glob('.cfw-history/*/transaction.json'))]

    def assert_original_intact(self, vm, digest, inode, path='Disk.img'):
        disk = vm / path
        self.assertEqual(sha256(disk), digest)
        self.assertEqual(disk.stat().st_ino, inode)

    def assert_no_staged_copy(self, vm):
        self.assertEqual(list(vm.glob('.cfw_disk.*/Disk.img')), [])
        self.assertEqual(list(vm.glob('.cfw-history/*/Disk.img')), [])

    def assert_failed_record(self, vm, needle=None):
        records = self.records(vm)
        self.assertEqual(len(records), 1, records)
        self.assertEqual(records[0]['status'], 'failed')
        self.assertTrue(records[0]['original_check']['unchanged'], records[0])
        if needle:
            self.assertIn(needle, json.dumps(records[0]))
        return records[0]

    # MARK: - Success

    def test_success_publishes_patched_clone_and_keeps_original_for_each_variant(self):
        for variant in ('regular', 'dev', 'jb', 'exp'):
            with self.subTest(variant=variant):
                vm, digest, inode = self.make_disk(f'vm-{variant}')
                _, proc = self.start(f'vm-{variant}', variant=variant, REAL_LSOF='1')
                rc, output = self.finish(proc)
                self.assertEqual(rc, 0, output)
                attached = Path((vm / 'mount-table.attached').read_text().strip())
                self.assertNotEqual(attached.resolve(), (vm / 'Disk.img').resolve())
                self.assertIn(f'apfs_snap_rename.py {attached}', self.calls())
                published = (vm / 'Disk.img').read_bytes()
                self.assertEqual(published[512:523], b'CFW-PATCHED')
                self.assertEqual(published[1024:1040], b'SNAPSHOT-FLIPPED')
                self.assertNotEqual((vm / 'Disk.img').stat().st_ino, inode)
                backups = list(vm.glob('.cfw-history/*/Disk.img'))
                self.assertEqual(len(backups), 1)
                self.assertEqual(sha256(backups[0]), digest)
                self.assertEqual(backups[0].stat().st_ino, inode)
                self.assertEqual(list(vm.glob('.cfw_disk.*')), [])
                record = self.records(vm)[0]
                self.assertEqual(record['status'], 'published')
                self.assertEqual(record['method'], 'clone')
                self.assertTrue(record['original_check']['unchanged'])

    def test_clone_unavailable_uses_verified_sparse_full_copy(self):
        vm, digest, inode = self.make_disk()
        _, proc = self.start(CFW_TXN_FAULTS='clone')
        rc, output = self.finish(proc)
        self.assertEqual(rc, 0, output)
        record = self.records(vm)[0]
        self.assertEqual(record['method'], 'copy')
        self.assertEqual(record['clone_error'], 'ENOTSUP')
        self.assertEqual(record['copy']['source_sha256'], digest)
        self.assertEqual(record['copy']['copy_sha256'], digest)
        backup = next(vm.glob('.cfw-history/*/Disk.img'))
        self.assertEqual(sha256(backup), digest)
        self.assertEqual(backup.stat().st_ino, inode)
        disk = vm / 'Disk.img'
        self.assertEqual(disk.stat().st_size, DISK_SIZE)
        self.assertLess(disk.stat().st_blocks * 512, DISK_SIZE // 2)
        self.assertEqual(disk.read_bytes()[512:523], b'CFW-PATCHED')

    # MARK: - Staging refusals

    def test_clone_and_copy_failure_refuses_and_leaves_original(self):
        vm, digest, inode = self.make_disk()
        _, proc = self.start(CFW_TXN_FAULTS='clone,copy')
        rc, output = self.finish(proc)
        self.assertNotEqual(rc, 0, output)
        self.assertNotIn('hdiutil attach', self.calls())
        self.assertNotIn('apfs_snap_rename.py', self.calls())
        self.assert_original_intact(vm, digest, inode)
        self.assert_no_staged_copy(vm)
        self.assert_failed_record(vm, 'EIO')

    def test_copy_verification_mismatch_refuses(self):
        vm, digest, inode = self.make_disk()
        _, proc = self.start(CFW_TXN_FAULTS='clone,corrupt')
        rc, output = self.finish(proc)
        self.assertNotEqual(rc, 0, output)
        self.assertIn('verification', output)
        self.assertNotIn('hdiutil attach', self.calls())
        self.assert_original_intact(vm, digest, inode)
        self.assert_no_staged_copy(vm)
        self.assert_failed_record(vm, 'verification')

    def test_external_holder_of_original_refuses(self):
        vm, digest, inode = self.make_disk()
        holder = subprocess.Popen([sys.executable, '-c', 'import sys,time; f=open(sys.argv[1],"rb"); print("open", flush=True); time.sleep(60)',
                                   str(vm / 'Disk.img')], stdout=subprocess.PIPE)
        self.addCleanup(lambda: (holder.kill(), holder.wait(), holder.stdout.close()))
        self.assertEqual(holder.stdout.readline().strip(), b'open')
        _, proc = self.start(REAL_LSOF='1')
        rc, output = self.finish(proc)
        self.assertNotEqual(rc, 0, output)
        self.assertIn(str(holder.pid), output)
        self.assertNotIn('hdiutil attach', self.calls())
        self.assert_original_intact(vm, digest, inode)
        self.assert_no_staged_copy(vm)

    def test_vm_lock_held_elsewhere_refuses_before_staging(self):
        vm, digest, inode = self.make_disk()
        fd = os.open(vm, os.O_RDONLY | os.O_DIRECTORY)
        self.addCleanup(os.close, fd)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        _, proc = self.start()
        rc, output = self.finish(proc)
        self.assertNotEqual(rc, 0, output)
        self.assertIn('VM lock unavailable', output)
        self.assertNotIn('hdiutil attach', self.calls())
        self.assert_original_intact(vm, digest, inode)
        self.assertEqual(list(vm.glob('.cfw_disk.*')), [])

    # MARK: - Identity changes

    def test_original_replaced_before_mount_refuses(self):
        vm, digest, inode = self.make_disk()
        _, proc = self.start(CFW_TXN_FAULTS='replace-after-stage')
        rc, output = self.finish(proc)
        self.assertNotEqual(rc, 0, output)
        self.assertIn('pre-mount', output)
        self.assertNotIn('hdiutil attach', self.calls())
        self.assert_original_intact(vm, digest, inode, 'Disk.img.moved')
        self.assertEqual((vm / 'Disk.img').read_bytes(), b'replacement\n')
        self.assert_no_staged_copy(vm)
        self.assert_failed_record(vm)

    def test_original_replaced_during_install_blocks_publication(self):
        vm, digest, inode = self.make_disk()
        _, proc = self.start(REPLACE_ORIGINAL='1')
        rc, output = self.finish(proc)
        self.assertNotEqual(rc, 0, output)
        self.assertIn('pre-publish', output)
        self.assert_original_intact(vm, digest, inode, 'Disk.img.moved')
        self.assertEqual((vm / 'Disk.img').read_bytes(), b'replacement\n')
        self.assert_no_staged_copy(vm)
        self.assert_failed_record(vm)

    # MARK: - Failures after staging

    def test_installer_failure_keeps_original_and_removes_copy(self):
        vm, digest, inode = self.make_disk()
        _, proc = self.start(INSTALL_EXIT='37')
        rc, output = self.finish(proc)
        self.assertEqual(rc, 37, output)
        self.assertNotIn('apfs_snap_rename.py', self.calls())
        self.assert_original_intact(vm, digest, inode)
        self.assert_no_staged_copy(vm)
        record = self.assert_failed_record(vm)
        self.assertEqual(record['exit_code'], 37)

    def test_snapshot_flip_failure_keeps_original(self):
        vm, digest, inode = self.make_disk()
        _, proc = self.start(FAIL_SNAP='1')
        rc, output = self.finish(proc)
        self.assertNotEqual(rc, 0, output)
        self.assert_original_intact(vm, digest, inode)
        self.assert_no_staged_copy(vm)
        self.assert_failed_record(vm)

    def test_publication_failure_keeps_original(self):
        vm, digest, inode = self.make_disk()
        _, proc = self.start(CFW_TXN_FAULTS='swap')
        rc, output = self.finish(proc)
        self.assertNotEqual(rc, 0, output)
        self.assertIn('apfs_snap_rename.py', self.calls())
        self.assert_original_intact(vm, digest, inode)
        self.assert_no_staged_copy(vm)
        self.assert_failed_record(vm, 'EIO')

    def test_swap_unsupported_publishes_by_exclusive_renames(self):
        # HFS+ rejects RENAME_SWAP with ENOTSUP (native run, cfw_disk_txn_native.py).
        vm, digest, inode = self.make_disk()
        _, proc = self.start(CFW_TXN_FAULTS='swap-unsupported')
        rc, output = self.finish(proc)
        self.assertEqual(rc, 0, output)
        record = self.records(vm)[0]
        self.assertEqual(record['publish_method'], 'renamex_np RENAME_EXCL (two steps)')
        self.assertEqual(record['swap_error'], 'ENOTSUP')
        self.assertTrue(all(record['after_swap'].values()), record)
        backup = next(vm.glob('.cfw-history/*/Disk.img'))
        self.assertEqual((sha256(backup), backup.stat().st_ino), (digest, inode))
        self.assertEqual((vm / 'Disk.img').read_bytes()[512:523], b'CFW-PATCHED')

    def test_exclusive_rename_failure_moves_original_back(self):
        vm, digest, inode = self.make_disk()
        _, proc = self.start(CFW_TXN_FAULTS='swap-unsupported,excl-publish')
        rc, output = self.finish(proc)
        self.assertNotEqual(rc, 0, output)
        self.assertIn('moved back', output)
        self.assert_original_intact(vm, digest, inode)
        self.assert_no_staged_copy(vm)
        self.assertEqual(list(vm.glob('.cfw-history/*/Disk.img.previous')), [])
        self.assert_failed_record(vm, 'EIO')

    def test_cleanup_failure_retains_copy_and_keeps_original(self):
        vm, digest, inode = self.make_disk()
        _, proc = self.start(FAIL_UMOUNT='1')
        rc, output = self.finish(proc)
        self.assertNotEqual(rc, 0, output)
        self.assertNotIn('apfs_snap_rename.py', self.calls())
        self.assert_original_intact(vm, digest, inode)
        retained = list(vm.glob('.cfw_disk.*/Disk.img'))
        self.assertEqual(len(retained), 1)
        self.assertIn(str(retained[0].parent), output)
        record = json.loads((retained[0].parent / 'transaction.json').read_text())
        self.assertEqual(record['status'], 'failed')
        self.assertTrue(record['staged_retained'])

    def test_interrupt_keeps_original_and_removes_copy(self):
        vm, digest, inode = self.make_disk()
        _, proc = self.start(INSTALL_SLEEP='30')
        deadline = time.monotonic() + 15
        while not (vm / 'ready').exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue((vm / 'ready').exists())
        os.killpg(proc.pid, signal.SIGINT)
        rc, output = self.finish(proc)
        self.assertEqual(rc, 130, output)
        self.assert_original_intact(vm, digest, inode)
        self.assert_no_staged_copy(vm)
        self.assert_failed_record(vm)


class InterruptedPublicationTests(unittest.TestCase):
    """finish decides from identities when a rename completed without its record."""

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='cfw txn reconcile ')
        self.addCleanup(temp.cleanup)
        self.vm = Path(temp.name).resolve() / 'vm'
        self.vm.mkdir()
        self.disk = self.vm / 'Disk.img'
        self.disk.write_bytes(os.urandom(1 << 20))
        self.digest, self.inode = sha256(self.disk), self.disk.stat().st_ino
        self.fd = os.open(self.disk, os.O_RDONLY)
        self.addCleanup(os.close, self.fd)
        self.work = self.vm / '.cfw_disk.reconcile'
        self.work.mkdir(mode=0o700)
        spec = importlib.util.spec_from_file_location('cfw_disk_txn_under_test', ROOT / 'scripts/cfw_disk_txn.py')
        self.txn = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.txn)

    def run_txn(self, command, *extra):
        args = [sys.executable, str(ROOT / 'scripts/vm_lock.py'), str(self.vm), 'test', '--', sys.executable,
                str(ROOT / 'scripts/cfw_disk_txn.py'), command, '--fd', str(self.fd), '--owner-pid', str(os.getpid()),
                *extra, str(self.vm), str(self.work)]
        env = {k: v for k, v in os.environ.items() if k != 'VPHONE_VM_LOCK_FD'}
        return subprocess.run(args, pass_fds=(self.fd,), capture_output=True, text=True, env=env)

    def staged(self):
        result = self.run_txn('stage')
        self.assertEqual(result.returncode, 0, result.stderr)
        staged = self.work / 'Disk.img'
        with open(staged, 'r+b') as stream:
            stream.write(b'CFW-PATCHED')
        return staged, sha256(staged)

    def test_swap_without_record_is_treated_as_published(self):
        staged, patched = self.staged()
        self.txn.swap_files(staged, self.disk)  # the record still says "staged"
        result = self.run_txn('finish', '--exit-code', '130')
        self.assertEqual(result.returncode, 0, result.stderr)
        location = Path(result.stdout.strip())
        self.assertEqual(sha256(self.disk), patched)
        self.assertEqual((sha256(location / 'Disk.img'), (location / 'Disk.img').stat().st_ino), (self.digest, self.inode))
        record = json.loads((location / 'transaction.json').read_text())
        self.assertEqual(record['status'], 'published')
        self.assertIn('before its record', record['note'])

    def test_first_exclusive_rename_without_record_moves_original_back(self):
        self.staged()
        os.rename(self.disk, self.work / 'Disk.img.previous')  # interrupted after step one
        result = self.run_txn('finish', '--exit-code', '130')
        self.assertEqual(result.returncode, 0, result.stderr)
        location = Path(result.stdout.strip())
        self.assertEqual((sha256(self.disk), self.disk.stat().st_ino), (self.digest, self.inode))
        self.assertFalse((location / 'Disk.img').exists())
        record = json.loads((location / 'transaction.json').read_text())
        self.assertEqual(record['status'], 'failed')
        self.assertTrue(record['original_check']['unchanged'], record)

    def test_finish_never_deletes_the_original_inode(self):
        self.staged()
        os.unlink(self.work / 'Disk.img')
        os.link(self.disk, self.work / 'Disk.img')  # a name in WORK_DIR for the original
        result = self.run_txn('finish', '--exit-code', '1')
        self.assertEqual(result.returncode, 0, result.stderr)
        location = Path(result.stdout.strip())
        self.assertEqual((location / 'Disk.img').stat().st_ino, self.inode)
        self.assertEqual(json.loads((location / 'transaction.json').read_text())['staged_retained_reason'],
                         'not the recorded staged image')


if __name__ == '__main__':
    unittest.main()
