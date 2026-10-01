"""dyld shared cache maxSlide decision (T13a): synthetic caches, no firmware.

Covers when `patch-dsc-maxslide` writes, and that every refusal leaves the
cache bytes unchanged. Decision and header checks follow upstream 2.2.3
`DyldSharedCacheMaxSlidePatcher.swift`.
"""
import contextlib
import io
import os
import re
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from patchers.cfw_patch_dsc_maxslide import patch_dsc_maxslide  # noqa: E402

MAIN = "dyld_shared_cache_arm64e"
REGION = 0x180000000
START = 0x180000000
OFF_MAX_SLIDE = 0xF0


def build_cache(*, size, max_slide, start=START, span=None, mapping_offset=0x198,
                mappings=None, magic=b"dyld_v1  arm64e\x00", length=None):
    """Return main-chunk bytes: a dyld_cache_header plus its mapping table."""
    if span is None:
        span = size - 0x4000
    if mappings is None:
        mappings = [(START, span, 0)]
    table_end = mapping_offset + 32 * len(mappings)
    data = bytearray(max(0x100, table_end))
    data[0:16] = magic
    struct.pack_into("<II", data, 0x10, mapping_offset, len(mappings))
    struct.pack_into("<QQQ", data, 0xE0, start, size, max_slide)
    if mapping_offset >= 0x100:
        for index, (address, msize, file_offset) in enumerate(mappings):
            struct.pack_into("<QQQII", data, mapping_offset + 32 * index,
                             address, msize, file_offset, 5, 5)
    if length is not None:
        data = data[:length]
    return bytes(data)


def zeroed_slide(data):
    out = bytearray(data)
    out[OFF_MAX_SLIDE:OFF_MAX_SLIDE + 8] = bytes(8)
    return bytes(out)


class MaxSlideDecisionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="dsc maxslide ")
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.main = self.dir / MAIN

    def write(self, data):
        self.main.write_bytes(data)
        return data

    def run_patch(self, **kwargs):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            result = patch_dsc_maxslide(str(self.dir), **kwargs)
        return result, out.getvalue().splitlines()

    # MARK: - needs clearing

    def test_overflow_zeroes_max_slide_only(self):
        # 24A435 header values (upstream d930e50).
        original = self.write(build_cache(size=0x17D504000, max_slide=0x20000000))
        result, lines = self.run_patch()
        self.assertEqual(result, 1)
        self.assertEqual(self.main.read_bytes(), zeroed_slide(original))
        self.assertEqual(lines, [
            "  [.] dyld_shared_cache_arm64e: start=0x180000000 size=0x17D504000 maxSlide=0x20000000",
            "      [+] overflow: span+maxSlide 0x19D504000 > region 0x180000000; set maxSlide 0x20000000 -> 0x0",
            "  [+] DSC maxSlide patch complete",
        ])

    def test_overflow_dry_run_reports_and_writes_nothing(self):
        original = self.write(build_cache(size=0x17C830000, max_slide=0x20000000))
        result, lines = self.run_patch(dry_run=True)
        self.assertEqual(result, 1)
        self.assertEqual(self.main.read_bytes(), original)
        self.assertIn("would set maxSlide 0x20000000 -> 0x0", lines[1])

    # MARK: - does not need clearing

    def test_fitting_cache_is_unchanged(self):
        original = self.write(build_cache(size=0x140904000, max_slide=0x20000000))
        result, lines = self.run_patch()
        self.assertEqual(result, 0)
        self.assertEqual(self.main.read_bytes(), original)
        self.assertEqual(lines[-1], "      [=] fits: span+maxSlide 0x160904000 <= region 0x180000000; no change")

    def test_exact_region_fit_is_unchanged(self):
        original = self.write(build_cache(size=REGION - 0x20000000, max_slide=0x20000000))
        self.assertEqual(self.run_patch()[0], 0)
        self.assertEqual(self.main.read_bytes(), original)

    def test_force_is_kept_for_hand_use(self):
        original = self.write(build_cache(size=0x140904000, max_slide=0x20000000))
        result, lines = self.run_patch(force=True)
        self.assertEqual(result, 1)
        self.assertEqual(self.main.read_bytes(), zeroed_slide(original))
        self.assertIn("forced: span+maxSlide 0x160904000 fits region 0x180000000 but --force set", lines[1])

    # MARK: - already zero

    def test_rerun_after_clearing_is_a_no_op(self):
        original = self.write(build_cache(size=0x17D504000, max_slide=0x20000000))
        self.assertEqual(self.run_patch()[0], 1)
        patched = self.main.read_bytes()
        self.assertEqual(patched, zeroed_slide(original))
        result, lines = self.run_patch()
        self.assertEqual(result, 0)
        self.assertEqual(self.main.read_bytes(), patched)
        self.assertEqual(lines[-1], "      [=] fits: span+maxSlide 0x17D504000 <= region 0x180000000; no change")

    def test_already_zero_with_force_is_a_no_op(self):
        original = self.write(build_cache(size=0x17D504000, max_slide=0))
        result, lines = self.run_patch(force=True)
        self.assertEqual(result, 0)
        self.assertEqual(self.main.read_bytes(), original)
        self.assertEqual(lines[-1], "      [=] maxSlide already 0; no change")

    def test_already_zero_over_region_is_a_no_op(self):
        original = self.write(build_cache(size=REGION + 0x4000, max_slide=0, span=REGION))
        result, lines = self.run_patch()
        self.assertEqual(result, 0)
        self.assertEqual(self.main.read_bytes(), original)
        self.assertEqual(lines[-1], "      [=] maxSlide already 0; no change")

    # MARK: - invalid header

    def test_invalid_headers_fail_without_writing(self):
        overflow = dict(size=0x17D504000, max_slide=0x20000000)
        cases = {
            "not a dyld shared cache": build_cache(magic=b"dyld_v2  arm64e\x00", **overflow),
            "header is 0x80 bytes": build_cache(length=0x80, **overflow),
            "has no maxSlide field": build_cache(mapping_offset=0xF0, **overflow),
            "no mapping covers the cache header": build_cache(
                mappings=[(START, 0x17D500000, 0x4000)], **overflow),
            "not the cache's lowest mapped address": build_cache(start=START + 0x4000, **overflow),
            "smaller than the 0x17D508000 the cache actually maps": build_cache(
                span=0x17D508000, **overflow),
            "overflows 64 bits": build_cache(
                size=0xFFFFFFFFFFFFC000, max_slide=0x20000000, span=0x4000),
        }
        for fragment, data in cases.items():
            with self.subTest(fragment):
                original = self.write(data)
                with self.assertRaises(RuntimeError) as caught:
                    self.run_patch()
                self.assertIn(fragment, str(caught.exception))
                self.assertEqual(self.main.read_bytes(), original)

    def test_missing_main_chunk_fails(self):
        with self.assertRaises(FileNotFoundError):
            self.run_patch()

    # MARK: - command line

    def run_cli(self, *extra):
        return subprocess.run(
            [sys.executable, "-B", str(ROOT / "scripts/patchers/cfw.py"), "patch-dsc-maxslide",
             str(self.dir), *extra],
            capture_output=True, text=True, timeout=60)

    def test_cli_exit_status_follows_the_decision(self):
        original = self.write(build_cache(size=0x17D504000, max_slide=0x20000000, start=START + 0x4000))
        proc = self.run_cli()
        self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(self.main.read_bytes(), original)

        original = self.write(build_cache(size=0x17D504000, max_slide=0x20000000))
        proc = self.run_cli()
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(self.main.read_bytes(), zeroed_slide(original))


class MaxSlideInstallGateTests(unittest.TestCase):
    """The installers never force maxSlide and never read FORCE_DSC_MAXSLIDE."""

    def test_install_runs_the_check_without_force_on_27_only(self):
        text = (ROOT / "scripts/cfw_install.sh").read_text()
        lines = text.splitlines()
        calls = [i for i, line in enumerate(lines) if "patch-dsc-maxslide" in line and "cfw.py" in line]
        self.assertEqual(len(calls), 1, calls)
        self.assertNotIn("--force", lines[calls[0]])
        labels = [line.strip() for line in lines[:calls[0]] if re.match(r"^\s*[^#\s][^)]*\)\s*$", line)]
        self.assertEqual(labels[-1], "27.*)")

    def test_installers_do_not_read_the_removed_variable(self):
        for name in ("cfw_install.sh", "cfw_install_dev.sh", "cfw_install_jb.sh", "cfw_install_exp.sh"):
            with self.subTest(name):
                text = (ROOT / "scripts" / name).read_text()
                code = [line for line in text.splitlines() if not line.lstrip().startswith("#")]
                self.assertFalse(any("FORCE_DSC_MAXSLIDE" in line for line in code),
                                 f"{name} reads FORCE_DSC_MAXSLIDE")
                self.assertIsNone(re.search(r"patch-dsc-maxslide[^\n]*--force", text), name)


if __name__ == "__main__":
    unittest.main()
