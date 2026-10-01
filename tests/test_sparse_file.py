"""Hole-aware reads of Disk.img fall back to reading every byte when holes are unknown.

T03 found that a decmpfs (UF_COMPRESSED) file answers SEEK_DATA and SEEK_HOLE
with ENXIO, which a reader takes for "all hole"; T15 found ENOTTY on HFS+.
scripts/cfw_disk_txn.py digests and copies Disk.img through data_ranges, and
tools/apfs_snap_rename.py scans it; both use scripts/sparse_file.py, so neither
may treat such a file as zeros.

The decmpfs fixture is a real compressed file: `ditto --hfsCompression` leaves
files uncompressed on this host (st_flags 0, checked 2026-10-01), so the
fixture writes the com.apple.decmpfs xattr and sets UF_COMPRESSED itself (as
tests/test_apfs_snap_rename.py does); the kernel decompresses it on read.
"""
import errno
import hashlib
import importlib.util
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import cfw_disk_txn  # noqa: E402
from test_apfs_snap_rename import snap, write_decmpfs  # noqa: E402

MIB = 1 << 20


def pattern(size, zero_from=None, zero_to=None):
    data = bytearray(hashlib.sha256(b'vphone-sparse').digest() * (size // 32 + 1))[:size]
    if zero_from is not None:
        data[zero_from:zero_to] = bytes(zero_to - zero_from)
    return bytes(data)


def sha(data):
    return hashlib.sha256(data).hexdigest()


class SparseReadTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='sparse read ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def open(self, path):
        fd = os.open(path, os.O_RDONLY)
        self.addCleanup(os.close, fd)
        return fd

    def sparse_file(self, size=32 * MIB):
        """Data at the head and near the end, a hole in between."""
        path = self.root / 'Disk.img'
        with open(path, 'wb') as stream:
            stream.truncate(size)
            stream.write(pattern(MIB))
            stream.seek(size - 2 * MIB)
            stream.write(pattern(MIB))
        return path

    def assert_reads_everything(self, path, fd):
        content = Path(path).read_bytes()
        size = len(content)
        self.assertEqual(list(cfw_disk_txn.data_ranges(fd, size)), [(0, size)])
        self.assertEqual(cfw_disk_txn.digest_fd(fd, size), sha(content))

    # MARK: decmpfs

    def test_decmpfs_disk_is_digested_and_copied_by_content(self):
        # Inline decmpfs type 3 holds one 64 KiB compression block (larger
        # inline streams read back wrong on this host), so the file is 64 KiB.
        size = 64 << 10
        content = pattern(size, zero_from=16 << 10, zero_to=48 << 10)
        path = self.root / 'Disk.img'
        write_decmpfs(path, content)
        self.assertTrue(os.lstat(path).st_flags & stat.UF_COMPRESSED)
        fd = self.open(path)
        with self.assertRaises(OSError) as raised:   # the fixture reproduces T03
            os.lseek(fd, 0, os.SEEK_DATA)
        self.assertEqual(raised.exception.errno, errno.ENXIO)

        self.assertEqual(list(cfw_disk_txn.data_ranges(fd, size)), [(0, size)])
        self.assertEqual(cfw_disk_txn.digest_fd(fd, size), sha(content))
        self.assertEqual(cfw_disk_txn.sample_digest(fd, size), {'kind': 'full', 'sha256': sha(content)})
        copy = self.root / 'copy.img'
        self.assertEqual(cfw_disk_txn.copy_file(fd, copy, size), sha(content))
        self.assertEqual(copy.read_bytes(), content)
        self.assertNotEqual(sha(content), sha(bytes(size)))

    # MARK: SEEK_DATA / SEEK_HOLE errors

    def lseek_failing(self, code, whence_failing, at_offset=None):
        real = os.lseek

        def lseek(fd, offset, whence):
            if whence in whence_failing and (at_offset is None or offset == at_offset):
                raise OSError(code, os.strerror(code))
            return real(fd, offset, whence)
        return mock.patch.object(os, 'lseek', lseek)

    def test_enotty_from_seek_data_and_seek_hole_reads_everything(self):
        path = self.sparse_file()
        fd = self.open(path)
        with self.lseek_failing(errno.ENOTTY, (os.SEEK_DATA, os.SEEK_HOLE)):
            self.assert_reads_everything(path, fd)

    def test_enotty_from_seek_hole_after_a_data_range_reads_the_rest(self):
        # SEEK_HOLE answers at 0 (the probe) and fails later: HFS+-like partial support.
        path = self.sparse_file()
        fd = self.open(path)
        real = os.lseek

        def lseek(fd_, offset, whence):
            if whence == os.SEEK_HOLE and offset != 0:
                raise OSError(errno.ENOTTY, os.strerror(errno.ENOTTY))
            if whence == os.SEEK_DATA:
                return 0 if offset == 0 else real(fd_, offset, whence)
            return real(fd_, offset, whence)
        content = path.read_bytes()
        with mock.patch.object(os, 'lseek', lseek):
            ranges = list(cfw_disk_txn.data_ranges(fd, len(content)))
            digest = cfw_disk_txn.digest_fd(fd, len(content))
        self.assertEqual(ranges[0][0], 0)
        self.assertEqual(ranges[-1][1], len(content))  # read to the end from the failing query on
        self.assertEqual(digest, sha(content))

    def test_other_seek_errors_read_everything(self):
        path = self.sparse_file()
        fd = self.open(path)
        for code in (errno.EIO, errno.EINVAL, errno.ENOTSUP):
            with self.subTest(errno=errno.errorcode[code]), self.lseek_failing(code, (os.SEEK_DATA,)):
                self.assert_reads_everything(path, fd)

    def test_enxio_without_a_compressed_flag_is_not_taken_for_an_empty_file(self):
        # A file that is not flagged UF_COMPRESSED but whose volume answers
        # every hole query with ENXIO is read, not reported as zeros.
        path = self.sparse_file()
        fd = self.open(path)
        with self.lseek_failing(errno.ENXIO, (os.SEEK_DATA, os.SEEK_HOLE)):
            self.assert_reads_everything(path, fd)

    # MARK: reliable holes

    def test_reliable_sparse_file_still_skips_its_holes(self):
        path = self.sparse_file()
        fd = self.open(path)
        content = path.read_bytes()
        ranges = list(cfw_disk_txn.data_ranges(fd, len(content)))
        if sum(end - start for start, end in ranges) == len(content):
            self.skipTest('this volume reports no holes for the fixture')
        self.assertLess(sum(end - start for start, end in ranges), len(content))
        self.assertEqual(cfw_disk_txn.digest_fd(fd, len(content)), sha(content))
        copy = self.root / 'copy.img'
        self.assertEqual(cfw_disk_txn.copy_file(fd, copy, len(content)), sha(content))
        self.assertEqual(copy.read_bytes(), content)

    def test_snapshot_rename_and_the_disk_transaction_share_one_rule(self):
        import sparse_file
        self.assertIs(snap.holes_reliable, sparse_file.holes_reliable)
        self.assertIs(cfw_disk_txn.data_ranges, sparse_file.data_ranges)


if __name__ == '__main__':
    unittest.main()
