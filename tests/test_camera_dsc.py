"""Camera DSC preflight and page-signature tests using small on-disk caches."""

import contextlib
import hashlib
import io
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.patchers import cfw_patch_camera_dsc as camera
from scripts.patchers.cfw_asm import asm
from scripts.patchers.cfw_dsc_chunks import DSCChunks


class CameraDSCTests(unittest.TestCase):
    BASE = 0x180000000
    PAGE = 4096
    CODE_SIZE = 3 * PAGE
    HASH_OFFSET = CODE_SIZE + 20 + 44
    ORIGINAL = asm("hint #27\nstp x29, x30, [sp, #-16]!")  # pacibsp
    NU_PATCH = asm("mov w0, #0\nret")
    AVF_PATCH = asm("mov w0, #3\nret")

    def setUp(self):
        tmp = tempfile.TemporaryDirectory(prefix="camera-dsc-test-")
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.path = self.root / "dyld_shared_cache_arm64e"
        self.nu = {sym: self.BASE + self.PAGE + 0x100 + i * 16
                   for i, sym in enumerate(camera.NU_STYLE_TRANSFER_SYMBOLS)}
        self.avf = {camera.AVF_AUTH_STATUS_SYMBOL: self.BASE + 2 * self.PAGE + 0x100}
        self.data = bytearray(self.CODE_SIZE)
        self.data[:16] = b"dyld_v1   arm64e"
        struct.pack_into("<II", self.data, 16, 0x100, 1)
        struct.pack_into("<QQQII", self.data, 0x100,
                         self.BASE, self.CODE_SIZE, 0, 7, 5)
        cd_len = 44 + 3 * 32
        struct.pack_into("<QQ", self.data, 0x28, self.CODE_SIZE, 20 + cd_len)
        cd = bytearray(cd_len)
        struct.pack_into(">IIIIIIIII", cd, 0, 0xFADE0C02, cd_len, 0x20001,
                         0, 44, 0, 0, 3, self.CODE_SIZE)
        cd[36:40] = bytes([32, 2, 0, 12])
        self.data.extend(struct.pack(">IIIII", 0xFADE0CC0, 20 + cd_len, 1, 0, 20))
        self.data.extend(cd)
        for vma in [*self.nu.values(), *self.avf.values()]:
            offset = vma - self.BASE
            self.data[offset:offset + 8] = self.ORIGINAL
        for i in range(3):
            self.data[self.HASH_OFFSET + i * 32:self.HASH_OFFSET + (i + 1) * 32] = (
                hashlib.sha256(self.data[i * self.PAGE:(i + 1) * self.PAGE]).digest())
        self.path.write_bytes(self.data)
        self.chunks = DSCChunks(str(self.root))
        self.writes = []
        real_write = self.chunks.write_at_vma

        def write(vma, data):
            self.writes.append(vma)
            real_write(vma, data)

        self.chunks.write_at_vma = write
        self.log = io.StringIO()
        # Enter before registering mocks so cleanup always restores stdout.
        self.redirect = contextlib.redirect_stdout(self.log)
        self.redirect.__enter__()
        self.addCleanup(self.redirect.__exit__, None, None, None)
        for attr, value in [("DSCChunks", self.chunks), ("resolve_nu_symbols", self.nu),
                            ("resolve_avf_auth_symbol", self.avf)]:
            patcher = mock.patch.object(camera, attr, return_value=value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def apply(self, **kwargs):
        return camera.apply_all_camera_patches(str(self.root), str(self.path), **kwargs)

    def replace(self, vma, value):
        with self.path.open("r+b") as f:
            f.seek(vma - self.BASE)
            f.write(value)

    def assert_patched(self):
        for vma in self.nu.values():
            self.assertEqual(self.chunks.bytes_at_vma(vma, 8), self.NU_PATCH)
        self.assertEqual(self.chunks.bytes_at_vma(next(iter(self.avf.values())), 8), self.AVF_PATCH)
        self.assert_hashes()

    def assert_hashes(self):
        data = self.path.read_bytes()
        for i in range(3):
            self.assertEqual(data[self.HASH_OFFSET + i * 32:self.HASH_OFFSET + (i + 1) * 32],
                             hashlib.sha256(data[i * self.PAGE:(i + 1) * self.PAGE]).digest())

    def test_original_and_repeated_input(self):
        self.assertEqual(self.apply(), 2)
        self.assertEqual(len(self.writes), 6)
        self.assert_patched()
        before = self.path.read_bytes()
        self.writes.clear()
        self.apply()
        self.assertEqual(self.writes, [])
        self.assertEqual(self.path.read_bytes(), before)
        self.assertIn("already-patched", self.log.getvalue())
        self.assertIn("+0x", self.log.getvalue())

    def test_nu_patched_avf_original(self):
        for vma in self.nu.values():
            self.replace(vma, self.NU_PATCH)
        self.apply()
        self.assertEqual(self.writes, list(self.avf.values()))
        self.assert_patched()

    def test_mixed_within_nu_group(self):
        existing = list(self.nu.values())[::2]
        for vma in existing:
            self.replace(vma, self.NU_PATCH)
        self.apply()
        self.assertEqual(len(self.writes), 3)
        self.assertTrue(set(existing).isdisjoint(self.writes))
        self.assert_patched()

    def test_last_site_mismatch_has_no_writes(self):
        self.replace(next(iter(self.avf.values())), asm("nop\nnop"))
        before = self.path.read_bytes()
        with self.assertRaisesRegex(RuntimeError, "prologue not pacibsp"):
            self.apply()
        self.assertEqual(self.writes, [])
        self.assertEqual(self.path.read_bytes(), before)

    def test_missing_symbol_has_no_writes(self):
        self.avf.clear()
        with self.assertRaisesRegex(RuntimeError, "missing camera symbols"):
            self.apply()
        self.assertEqual(self.writes, [])

    def test_resolver_error_has_no_writes(self):
        with mock.patch.object(camera, "resolve_avf_auth_symbol", side_effect=RuntimeError("missing")):
            with self.assertRaisesRegex(RuntimeError, "missing"):
                self.apply()
        self.assertEqual(self.writes, [])

    def test_short_read_is_rejected_even_with_force(self):
        read = self.chunks.bytes_at_vma
        last = next(iter(self.avf.values()))
        with mock.patch.object(self.chunks, "bytes_at_vma",
                               side_effect=lambda vma, n: b"x" if vma == last else read(vma, n)):
            with self.assertRaisesRegex(RuntimeError, "short read"):
                self.apply(force=True)
        self.assertEqual(self.writes, [])

    def test_dry_run_leaves_bytes_and_hashes_unchanged(self):
        before = self.path.read_bytes()
        with mock.patch.object(camera, "reattest_modified_pages") as hashes:
            self.apply(dry_run=True)
        hashes.assert_not_called()
        self.assertEqual(self.writes, [])
        self.assertEqual(self.path.read_bytes(), before)

    def test_force_overrides_mismatch(self):
        self.replace(next(iter(self.avf.values())), asm("nop\nnop"))
        self.apply(force=True)
        self.assert_patched()

    def test_avf_only_does_not_resolve_or_modify_nu(self):
        with mock.patch.object(camera, "resolve_nu_symbols", side_effect=AssertionError("NU requested")):
            self.assertEqual(camera.apply_avf_auth_only(str(self.root), str(self.path)), 1)
        self.assertEqual(self.writes, list(self.avf.values()))
        for vma in self.nu.values():
            self.assertEqual(self.chunks.bytes_at_vma(vma, 8), self.ORIGINAL)
        self.assert_hashes()

    def test_write_failure_propagates_and_rerun_recovers(self):
        write = self.chunks.write_at_vma
        last = next(iter(self.avf.values()))

        def fail(vma, data):
            if vma == last:
                raise OSError("write failed")
            write(vma, data)

        with mock.patch.object(self.chunks, "write_at_vma", side_effect=fail):
            with self.assertRaisesRegex(OSError, "write failed"):
                self.apply()
        self.assertEqual(len(self.writes), 5)  # I/O failures do not roll back.
        self.apply()
        self.assert_patched()

    def test_hash_failure_propagates_and_rerun_recovers(self):
        with mock.patch.object(camera, "reattest_modified_pages", side_effect=OSError("hash failed")):
            with self.assertRaisesRegex(OSError, "hash failed"):
                self.apply()
        self.assertEqual(len(self.writes), 6)
        self.writes.clear()
        self.apply()
        self.assertEqual(self.writes, [])
        self.assert_patched()

    def test_silent_hash_skip_is_rejected(self):
        with mock.patch.object(camera, "reattest_modified_pages", return_value=[]):
            with self.assertRaisesRegex(RuntimeError, "page hash verify failed"):
                self.apply()

    def test_missing_code_directory_has_no_writes(self):
        with mock.patch.object(camera, "_read_chunk_cd_blob", return_value=None):
            with self.assertRaisesRegex(RuntimeError, "no supported CodeDirectory"):
                self.apply()
        self.assertEqual(self.writes, [])

    def test_post_write_byte_mismatch_is_rejected(self):
        with mock.patch.object(self.chunks, "write_at_vma"):
            with self.assertRaisesRegex(RuntimeError, "post-write verify failed"):
                self.apply()

    def test_patch_crossing_page_boundary_updates_both_hashes(self):
        vma = self.BASE + 2 * self.PAGE - 4
        self.avf[camera.AVF_AUTH_STATUS_SYMBOL] = vma
        self.replace(vma, self.ORIGINAL)
        self.apply()
        self.assert_patched()

    def test_overlapping_sites_have_no_writes(self):
        self.avf[camera.AVF_AUTH_STATUS_SYMBOL] = next(iter(self.nu.values()))
        with self.assertRaisesRegex(RuntimeError, "overlapping"):
            self.apply()
        self.assertEqual(self.writes, [])


if __name__ == "__main__":
    unittest.main()
