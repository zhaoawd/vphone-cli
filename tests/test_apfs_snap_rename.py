"""tools/apfs_snap_rename.py scans only data windows and falls back safely.

Upstream 9a1018bd skips holes with SEEK_DATA when scanning Disk.img for the
root snapshot records. T03 found that a decmpfs (UF_COMPRESSED) file answers
SEEK_DATA with ENXIO, which a scanner reads as "all hole"; T15 found ENOTTY on
HFS+. Both must fall back to reading every window, never to "nothing found".
"""
import ctypes
import ctypes.util
import errno
import importlib.util
import os
from pathlib import Path
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zlib

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / 'tools/apfs_snap_rename.py'
spec = importlib.util.spec_from_file_location('apfs_snap_rename', TOOL)
snap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(snap)

HASH = b'0123456789abcdef' * 4
NAME = snap.OLD_PREFIX + HASH
NEW_PREFIX = b'orig-fs.disabled.rn-'


def valid_block(at=100, filler=0x11):
    block = bytearray([filler]) * snap.BS
    block[at:at + len(NAME)] = NAME
    block[0:8] = struct.pack('<Q', snap.cksum(bytes(block)))
    return bytes(block)


def invalid_block(at=200):
    block = bytearray(snap.BS)
    block[at:at + len(NAME)] = NAME           # a string constant, no valid checksum
    block[0:8] = b'\x01' * 8
    return bytes(block)


def write_decmpfs(path, content):
    """decmpfs type 3: zlib stream in com.apple.decmpfs, empty data fork."""
    libc = ctypes.CDLL(ctypes.util.find_library('c'), use_errno=True)
    Path(path).write_bytes(b'')
    value = struct.pack('<IIQ', 0x636D7066, 3, len(content)) + zlib.compress(content)
    if libc.setxattr(os.fsencode(path), b'com.apple.decmpfs', value, len(value), 0, 0x0020) != 0:
        raise OSError(ctypes.get_errno(), 'setxattr com.apple.decmpfs')
    os.chflags(path, stat.UF_COMPRESSED)


class APFSSnapshotRenameScanTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='apfs snap rename ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def sparse_image(self, size, blocks):
        path = self.root / 'Disk.img'
        with open(path, 'wb') as handle:
            handle.truncate(size)
            for offset, block in blocks:
                handle.seek(offset)
                handle.write(block)
        return path

    def test_record_past_holes_in_a_128_gb_sparse_image_reads_few_windows(self):
        # Mid-window, so the jump must land on the window boundary before it.
        record = 100 * 1024 ** 3 + 3 * snap.WINDOW + 8 * snap.BS
        decoy = 7 * snap.WINDOW + 5 * snap.BS
        path = self.sparse_image(128 * 1000 ** 3, [(record, valid_block()), (decoy, invalid_block())])
        stats = {}
        hits = snap.rename(path, dry_run=True, log=lambda _: None, stats=stats)
        self.assertEqual(list(hits), [record])
        self.assertTrue(stats['skipped_holes'])
        self.assertLessEqual(stats['windows_read'], 2, stats)

        snap.rename(path, log=lambda _: None)
        with open(path, 'rb') as handle:
            handle.seek(record)
            block = handle.read(snap.BS)
            handle.seek(decoy)
            untouched = handle.read(snap.BS)
        self.assertEqual(block[100:100 + len(NEW_PREFIX)], NEW_PREFIX)
        self.assertEqual(struct.unpack('<Q', block[:8])[0], snap.cksum(block))
        self.assertEqual(untouched, invalid_block())
        self.assertEqual(snap.rename(path, dry_run=True, log=lambda _: None), {})

    def test_volume_without_hole_reports_reads_every_window(self):
        # HFS+ (T15): SEEK_DATA/SEEK_HOLE fail with ENOTTY.
        size = 4 * snap.WINDOW
        record = 3 * snap.WINDOW + 2 * snap.BS
        path = self.sparse_image(size, [(record, valid_block())])
        real_lseek = os.lseek

        def lseek(fd, offset, whence):
            if whence in (os.SEEK_DATA, os.SEEK_HOLE):
                raise OSError(errno.ENOTTY, os.strerror(errno.ENOTTY))
            return real_lseek(fd, offset, whence)

        stats = {}
        with mock.patch.object(snap.os, 'lseek', lseek):
            hits = snap.rename(path, dry_run=True, log=lambda _: None, stats=stats)
        self.assertEqual(list(hits), [record])
        self.assertFalse(stats['skipped_holes'])
        self.assertEqual(stats['windows_read'], 4)

    def test_decmpfs_image_is_read_not_taken_for_a_hole(self):
        content = bytearray(16 * snap.BS)
        content[5 * snap.BS:6 * snap.BS] = valid_block()
        path = self.root / 'Disk.img'
        write_decmpfs(path, bytes(content))
        info = os.lstat(path)
        self.assertTrue(info.st_flags & stat.UF_COMPRESSED)
        fd = os.open(path, os.O_RDONLY)
        try:
            with self.assertRaises(OSError) as raised:
                os.lseek(fd, 0, os.SEEK_DATA)
            self.assertEqual(raised.exception.errno, errno.ENXIO)
            self.assertFalse(snap.holes_reliable(fd))
        finally:
            os.close(fd)

        stats = {}
        hits = snap.rename(path, dry_run=True, log=lambda _: None, stats=stats)
        self.assertEqual(list(hits), [5 * snap.BS])
        self.assertEqual(stats['windows_read'], 1)

        snap.rename(path, log=lambda _: None)
        data = path.read_bytes()
        self.assertEqual(len(data), len(content))
        block = data[5 * snap.BS:6 * snap.BS]
        self.assertEqual(block[100:100 + len(NEW_PREFIX)], NEW_PREFIX)
        self.assertEqual(struct.unpack('<Q', block[:8])[0], snap.cksum(block))
        self.assertEqual(data[:5 * snap.BS], bytes(5 * snap.BS))

    def test_record_across_a_window_edge_is_found_as_by_a_whole_file_scan(self):
        # A prefix in the last bytes of a window, hex digits in the next one.
        block = bytearray(snap.BS)
        at = snap.BS - 30
        block[at:] = NAME[:30]
        block[0:8] = struct.pack('<Q', snap.cksum(bytes(block)))
        tail = bytearray(snap.BS)
        tail[:len(NAME) - 30] = NAME[30:]
        path = self.sparse_image(2 * snap.WINDOW, [(snap.WINDOW - snap.BS, bytes(block)),
                                                     (snap.WINDOW, bytes(tail))])
        hits = snap.rename(path, dry_run=True, log=lambda _: None)
        self.assertEqual(list(hits), [snap.WINDOW - snap.BS])
        self.assertEqual(hits[snap.WINDOW - snap.BS][0][1], NAME)

    def test_cli_output_is_unchanged(self):
        path = self.sparse_image(2 * snap.WINDOW, [(snap.WINDOW + snap.BS, valid_block())])
        result = subprocess.run([sys.executable, str(TOOL), str(path), '--dry-run'],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [
            'detected snapshot: ' + NAME.decode(),
            "records: 1 in 1 block(s): ['%s']" % hex(snap.WINDOW + snap.BS),
            '[dry-run] would rename prefix -> orig-fs.disabled.rn-',
        ])
        result = subprocess.run([sys.executable, str(TOOL), str(path), '--new-prefix', 'short'],
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('--new-prefix must be exactly 20 bytes', result.stderr)


if __name__ == '__main__':
    unittest.main()
