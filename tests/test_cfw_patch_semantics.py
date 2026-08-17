import unittest
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.patchers.cfw_asm import MOV_X0_1, RET, _cs, asm, asm_at
from scripts.patchers.cfw_patch_diskimagesiod import _classify_imp_prefix
from scripts.patchers.cfw_patch_iomfb_force_kern import _is_dispatch_trampoline
from scripts.patchers.cfw_patch_lockdown_mode import _find_error_gate
from scripts.patchers.cfw_patch_xpc_lwcr import _find_consistency_check


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
    def test_imp_prefix_accepts_ios_27_beta_5_callee_saved_frame(self):
        ios_27_beta_5_prefix = bytes.fromhex(
            "7f2303d5"  # pacibsp
            "f657bda9"  # stp x22, x21, [sp, #-0x30]!
            "f44f01a9"  # stp x20, x19, [sp, #0x10]
            "fd7b02a9"  # stp x29, x30, [sp, #0x20]
            "fd830091"  # add x29, sp, #0x20
        )
        self.assertEqual(_classify_imp_prefix(ios_27_beta_5_prefix, 0), "patchable")

    def test_imp_prefix_rejects_frame_record_outside_allocated_stack(self):
        invalid_prefix = (
            bytes.fromhex("7f2303d5")
            + asm("stp x22, x21, [sp, #-0x30]!")
            + asm("stp x29, x30, [sp, #0x40]")
            + asm("add x29, sp, #0x40")
        )
        self.assertEqual(_classify_imp_prefix(invalid_prefix, 0), "unexpected")

    def test_imp_prefix_rejects_non_spill_before_frame_record(self):
        invalid_prefix = (
            bytes.fromhex("7f2303d5")
            + asm("stp x22, x21, [sp, #-0x30]!")
            + asm("nop")
            + asm("stp x29, x30, [sp, #0x20]")
            + asm("add x29, sp, #0x20")
        )
        self.assertEqual(_classify_imp_prefix(invalid_prefix, 0), "unexpected")

    def test_imp_prefix_rejects_frame_store_without_stack_writeback(self):
        invalid_prefix = (
            bytes.fromhex("7f2303d5")
            + asm("stp x29, x30, [sp, #-0x10]")
        )
        self.assertEqual(_classify_imp_prefix(invalid_prefix, 0), "unexpected")

    def test_imp_prefix_classification_fails_closed(self):
        self.assertEqual(_classify_imp_prefix(MOV_X0_1 + RET, 0), "already-patched")
        self.assertEqual(
            _classify_imp_prefix(bytes.fromhex("7f2303d5") + asm("stp x29, x30, [sp, #-0x10]!"), 0),
            "patchable",
        )
        self.assertEqual(_classify_imp_prefix(asm("nop") + asm("nop"), 0), "unexpected")
        self.assertEqual(_classify_imp_prefix(b"\x00\x01", 0), "unexpected")


class XPCLWCRTests(unittest.TestCase):
    def test_consistency_check_recognizes_unpatched_sequence(self):
        unpatched = (
            asm("bl #0x40")
            + asm("ldr w8, [x1]")
            + asm("cmp w8, #0")
            + asm("cset w8, ne")
            + asm("eor w9, w0, w8")
            + asm("tbz w9, #0, #0x40")
            + asm("ret")
        )
        found = _find_consistency_check(list(_cs.disasm(unpatched, 0)))
        self.assertIsNotNone(found)
        self.assertEqual(found[0], "unpatched")

    def test_consistency_check_recognizes_already_patched_sequence(self):
        patched = (
            asm("bl #0x40")
            + asm("ldr w8, [x1]")
            + asm("cmp w8, #0")
            + asm("cset w0, eq")
            + asm("nop")
            + asm("nop")
            + asm("ret")
        )
        found = _find_consistency_check(list(_cs.disasm(patched, 0)))
        self.assertIsNotNone(found)
        self.assertEqual(found[0], "already-patched")

    def test_consistency_check_rejects_patched_shape_with_wrong_data_flow(self):
        unrelated = (
            asm("bl #0x40")
            + asm("ldr w9, [x1]")
            + asm("cmp w8, #0")
            + asm("cset w0, eq")
            + asm("nop")
            + asm("nop")
            + asm("ret")
        )
        self.assertIsNone(_find_consistency_check(list(_cs.disasm(unrelated, 0))))


class LockdownModeTests(unittest.TestCase):
    def test_error_gate_recognizes_unpatched_sequence(self):
        unpatched = asm("bl #0x40") + asm("cmn w0, #1") + asm("b.eq #0x40") + asm("ret")
        found = _find_error_gate(list(_cs.disasm(unpatched, 0)))
        self.assertIsNotNone(found)
        self.assertEqual(found[0], "unpatched")

    def test_error_gate_recognizes_already_patched_sequence(self):
        patched = asm("bl #0x40") + asm("cmn w0, #1") + asm("nop") + asm("ret")
        found = _find_error_gate(list(_cs.disasm(patched, 0)))
        self.assertIsNotNone(found)
        self.assertEqual(found[0], "already-patched")

    def test_error_gate_rejects_nop_without_preceding_call(self):
        unrelated = asm("cmn w0, #1") + asm("nop") + asm("ret")
        self.assertIsNone(_find_error_gate(list(_cs.disasm(unrelated, 0))))


if __name__ == "__main__":
    unittest.main()
