import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]

SWIFT_PATCHERS = (
    "KernelJBPatchExecPolicyKill.swift",
    "KernelJBPatchIoucSandbox.swift",
    "KernelJBPatchIomfbSwap.swift",
    "KernelJBPatchContainerUpcall.swift",
    "KernelJBPatchDiskImages2.swift",
    "KernelJBPatchFpfsScopedOpen.swift",
    "KernelJBPatchThreadSetState.swift",
    "KernelJBPatchVmMapDelete.swift",
)

PYTHON_PATCHERS = (
    "cfw_patch_iomfb_swapend.py",
    "cfw_patch_iomfb_force_kern.py",
    "cfw_patch_diskimagesiod.py",
)

SWIFT_FORBIDDEN = (
    "operandString",
    "0x5280_0120",
    "0x5280_0101",
    "0x7100_0000",
    "0xD538_D088",
    "0xF941_F908",
    "0xF940_0D08",
    "0x9115_B108",
    "0xF940_0109",
    "0xEB0A_013F",
    "0xD280_0000",
    "0xD65F_03C0",
    "0x5400_0000",
    "0xF280_0000",
)


class KernelPatchGuardrailTests(unittest.TestCase):
    def test_swift_patchers_use_typed_matching_and_computed_encoders(self):
        patch_dir = REPO_ROOT / "sources/FirmwarePatcher/Kernel/JBPatches"
        for filename in SWIFT_PATCHERS:
            text = (patch_dir / filename).read_text()
            for forbidden in SWIFT_FORBIDDEN:
                self.assertNotIn(forbidden, text, f"{filename}: {forbidden}")

    def test_python_patchers_do_not_parse_rendered_operands(self):
        patch_dir = REPO_ROOT / "scripts/patchers"
        for filename in PYTHON_PATCHERS:
            text = (patch_dir / filename).read_text()
            self.assertNotIn(".op_str", text, filename)

    def test_frida_instruction_matchers_decode_instructions(self):
        patch_dir = REPO_ROOT / "sources/FirmwarePatcher/Kernel/JBPatches"
        for filename in ("KernelJBPatchThreadSetState.swift", "KernelJBPatchVmMapDelete.swift"):
            text = (patch_dir / filename).read_text()
            self.assertNotIn("buffer.readU32(at:", text, filename)


if __name__ == "__main__":
    unittest.main()
