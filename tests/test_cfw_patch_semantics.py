import unittest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.patchers.cfw_asm import MOV_X0_1, RET, asm, asm_at
from scripts.patchers.cfw_patch_diskimagesiod import _classify_imp_prefix
from scripts.patchers.cfw_patch_iomfb_force_kern import _is_dispatch_trampoline


class FakeChunks:
    def __init__(self, base, data):
        self.base = base
        self.data = data

    def bytes_at_vma(self, va, size):
        offset = va - self.base
        return self.data[offset:offset + size]


class IOMFBForceKernTests(unittest.TestCase):
    def test_typed_dispatch_trampoline_requires_consistent_registers(self):
        base = 0x1000
        valid = (
            asm_at("cbz x0, #0x1040", base)
            + asm("ldr x8, [x0, #0x28]")
            + asm_at("cbz x8, #0x1040", base + 8)
            + asm("br x8")
        )
        self.assertTrue(_is_dispatch_trampoline(FakeChunks(base, valid), base))

        wrong_base = (
            asm_at("cbz x0, #0x1040", base)
            + asm("ldr x8, [x1, #0x28]")
            + asm_at("cbz x8, #0x1040", base + 8)
            + asm("br x8")
        )
        self.assertFalse(_is_dispatch_trampoline(FakeChunks(base, wrong_base), base))

        wrong_test = (
            asm_at("cbz x0, #0x1040", base)
            + asm("ldr x8, [x0, #0x28]")
            + asm_at("cbz x9, #0x1040", base + 8)
            + asm("br x8")
        )
        self.assertFalse(_is_dispatch_trampoline(FakeChunks(base, wrong_test), base))


class DiskImagesIODTests(unittest.TestCase):
    def test_imp_prefix_classification_fails_closed(self):
        self.assertEqual(_classify_imp_prefix(MOV_X0_1 + RET, 0), "already-patched")
        self.assertEqual(
            _classify_imp_prefix(bytes.fromhex("7f2303d5") + asm("stp x29, x30, [sp, #-0x10]!"), 0),
            "patchable",
        )
        self.assertEqual(_classify_imp_prefix(asm("nop") + asm("nop"), 0), "unexpected")
        self.assertEqual(_classify_imp_prefix(b"\x00\x01", 0), "unexpected")


if __name__ == "__main__":
    unittest.main()
