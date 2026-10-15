"""Conditional IOMFB algorithm against small signed, on-disk DSC fixtures."""
import contextlib
import hashlib
import io
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.patchers import cfw_patch_iomfb_force_kern as iomfb
from scripts.patchers.cfw_asm import asm_at, _cs


class ConditionalIOMFBTests(unittest.TestCase):
    BASE = 0x180000000
    PAGE = 4096
    CODE_SIZE = 4 * PAGE
    HASH_OFFSET = CODE_SIZE + 20 + 44

    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='iomfb-conditional-')
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.path = self.root / 'dyld_shared_cache_arm64e'
        self.symbols = {}
        self.sites = {}
        self.data = bytearray(self.CODE_SIZE)
        self.data[:16] = b'dyld_v1   arm64e'.ljust(16, b'\0')
        struct.pack_into('<II', self.data, 16, 0x100, 1)
        struct.pack_into('<QQQII', self.data, 0x100, self.BASE, self.CODE_SIZE, 0, 7, 5)
        cd_length = 44 + 4 * 32
        struct.pack_into('<QQ', self.data, 0x28, self.CODE_SIZE, 20 + cd_length)
        cd = bytearray(cd_length)
        struct.pack_into('>IIIIIIIII', cd, 0, 0xFADE0C02, cd_length, 0x20001,
                         0, 44, 0, 0, 4, self.CODE_SIZE)
        cd[36:40] = bytes([32, 2, 0, 12])
        self.data.extend(struct.pack('>IIIII', 0xFADE0CC0, 20 + cd_length, 1, 0, 20))
        self.data.extend(cd)
        for i, (suffix, offset) in enumerate(zip(iomfb.REQUIRED, (0x1100, 0x1200, 0x1ff8))):
            address = self.BASE + offset
            kern = self.BASE + 0x3000 + i * 0x20
            virt = self.BASE + 0x3100 + i * 0x20
            fail = address + 0x40  # not the unsafe pub+16 fallback
            self.sites[suffix] = (address, kern, virt, fail)
            self.symbols['_IOMobileFramebuffer' + suffix] = address
            self.symbols['_kern_' + suffix] = kern
            self.symbols['_virt_' + suffix] = virt
            self.data[offset:offset+16] = self.original(address, fail)
        self.path.write_bytes(self.data)
        self.resign()
        self.output = io.StringIO()
        redirect = contextlib.redirect_stdout(self.output)
        redirect.__enter__(); self.addCleanup(redirect.__exit__, None, None, None)

    @staticmethod
    def original(address, fail):
        return asm_at(f'cbz x0, #{fail}; ldr x8, [x0, #0x28]; cbz x8, #{fail}; br x8', address)

    @staticmethod
    def current(address, kern, virt, fail):
        return asm_at(f'cbz x0, #{fail}; ldr w16, [x0, #0x14]; cbnz w16, #{kern}; b #{virt}', address)

    def replace(self, address, data):
        with self.path.open('r+b') as stream:
            stream.seek(address - self.BASE); stream.write(data)

    def resign(self):
        data = bytearray(self.path.read_bytes())
        for page in range(4):
            data[self.HASH_OFFSET+page*32:self.HASH_OFFSET+(page+1)*32] = hashlib.sha256(
                data[page*self.PAGE:(page+1)*self.PAGE]).digest()
        self.path.write_bytes(data)

    def apply(self, **kwargs):
        with patch.object(iomfb, '_all_symbols', return_value=self.symbols):
            return iomfb.patch_iomfb_force_kern(str(self.root), **kwargs)

    def assert_unchanged_refusal(self, message):
        before = self.path.read_bytes()
        with self.assertRaisesRegex((ValueError, RuntimeError), message):
            self.apply()
        self.assertEqual(self.path.read_bytes(), before)

    def assert_signatures(self):
        data = self.path.read_bytes()
        for page in range(4):
            self.assertEqual(data[self.HASH_OFFSET+page*32:self.HASH_OFFSET+(page+1)*32],
                             hashlib.sha256(data[page*self.PAGE:(page+1)*self.PAGE]).digest())

    def test_original_routes_preserves_null_target_and_repeated_input(self):
        self.assertEqual(self.apply(), 3)
        data = self.path.read_bytes()
        for address, kern, virt, fail in self.sites.values():
            raw = data[address-self.BASE:address-self.BASE+16]
            self.assertEqual(raw, self.current(address, kern, virt, fail))
            insns = list(_cs.disasm(raw, address))
            self.assertEqual([insn.mnemonic for insn in insns], ['cbz', 'ldr', 'cbnz', 'b'])
            self.assertEqual(insns[0].operands[1].imm, fail)
            self.assertEqual(insns[2].operands[1].imm, kern)
            self.assertEqual(insns[3].operands[0].imm, virt)
        self.assert_signatures()  # SetLayer straddles two signing pages.
        self.assertEqual(self.apply(), 0)
        self.assertEqual(self.path.read_bytes(), data)

    def test_mixed_original_and_current(self):
        site = self.sites['SwapBegin']
        self.replace(site[0], self.current(*site)); self.resign()
        self.assertEqual(self.apply(), 2)
        self.assert_signatures()

    def test_current_sites_repair_stale_signature(self):
        self.apply()
        with self.path.open('r+b') as stream:
            stream.seek(self.HASH_OFFSET+2*32); stream.write(b'\0'*32)
        self.assertEqual(self.apply(), 0)
        self.assert_signatures()

    def test_dry_run_has_no_instruction_or_signature_write(self):
        before = self.path.read_bytes()
        self.assertEqual(self.apply(dry_run=True), 3)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertIn('no migration/publication authority', self.output.getvalue())

    def test_real_cfw_cli_dry_run_uses_conditional_algorithm_without_writes(self):
        binary = self.root / 'ipsw'
        output = '\n'.join(f'0x{address:x}: (IOMFB) {name}' for name, address in self.symbols.items())
        binary.write_text(f'#!{sys.executable}\nprint({output!r})\n')
        binary.chmod(0o755)
        before = self.path.read_bytes()
        result = subprocess.run([sys.executable, str(Path(__file__).resolve().parents[1] /
                                'scripts/patchers/cfw.py'), 'patch-iomfb-force-kern',
                                 str(self.root), '--dry-run'], capture_output=True, text=True,
                                env=dict(os.environ, PATH=str(self.root)+os.pathsep+os.environ['PATH']))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('ISOLATED diagnostic only: conditional force-kern', result.stdout)
        self.assertIn('conditional IOMFB: 3 writes', result.stdout)
        self.assertEqual(self.path.read_bytes(), before)

    def test_legacy_site_refuses_entire_mixed_set(self):
        address, kern, _, _ = self.sites['SwapSetLayer']
        self.replace(address, asm_at(f'b #{kern}', address))
        self.assert_unchanged_refusal('legacy unconditional.*trusted Undo')

    def test_legacy_outside_new_virt_set_also_refuses(self):
        address, kern = self.BASE+0x2400, self.BASE+0x3200
        self.symbols.update(_IOMobileFramebufferSwapOther=address, _kern_SwapOther=kern)
        self.replace(address, asm_at(f'b #{kern}; nop; nop; nop', address))
        self.assert_unchanged_refusal('legacy unconditional')

    def test_unknown_optional_complete_triple_refuses(self):
        address = self.BASE + 0x2400
        self.symbols.update(_IOMobileFramebufferSwapOther=address,
                            _kern_SwapOther=self.BASE+0x3200, _virt_SwapOther=self.BASE+0x3300)
        self.replace(address, asm_at('nop; nop; nop; ret', address))
        self.assert_unchanged_refusal('unknown dispatcher')

    def test_source_excluded_swap_signal_is_untouched(self):
        address = self.BASE + 0x2400
        self.symbols.update(_IOMobileFramebufferSwapSignal=address,
                            _kern_SwapSignal=self.BASE+0x3200, _virt_SwapSignal=self.BASE+0x3300)
        raw = asm_at('nop; nop; nop; ret', address)
        self.replace(address, raw); self.resign()
        self.assertEqual(self.apply(), 3)
        self.assertEqual(self.path.read_bytes()[0x2400:0x2410], raw)
        self.assertIn('source-excluded non-dispatch operation', self.output.getvalue())

    def test_legacy_swap_signal_is_not_silently_excluded(self):
        address, kern = self.BASE+0x2400, self.BASE+0x3200
        self.symbols.update(_IOMobileFramebufferSwapSignal=address,
                            _kern_SwapSignal=kern, _virt_SwapSignal=self.BASE+0x3300)
        self.replace(address, asm_at(f'b #{kern}; nop; nop; ret', address))
        self.assert_unchanged_refusal('legacy unconditional')

    def test_conflicting_symbol_lookup_refuses(self):
        output = '0x1000: (IOMFB) _kern_SwapBegin\n0x2000: (IOMFB) _kern_SwapBegin\n'
        with patch.object(iomfb.shutil, 'which', return_value='/unused/ipsw'), \
             patch.object(iomfb.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, output)):
            with self.assertRaisesRegex(ValueError, 'conflicting IOMFB symbol'):
                iomfb._all_symbols(str(self.path), iomfb.IOMFB)

    def test_missing_required_virt_refuses_before_any_write(self):
        del self.symbols['_virt_SwapSetLayer']
        self.assert_unchanged_refusal('missing required')

    def test_partial_current_wrong_load_or_branch_refused(self):
        address, kern, virt, fail = self.sites['SwapSetLayer']
        for code in (
            f'cbz x0, #{fail}; ldr w17, [x0, #0x14]; cbnz w17, #{kern}; b #{virt}',
            f'cbz x0, #{fail}; ldr w16, [x0, #0x18]; cbnz w16, #{kern}; b #{virt}',
            f'cbz x0, #{fail}; ldr w16, [x0, #0x14]; cbnz w16, #{virt}; b #{kern}',
            f'cbz w0, #{fail}; ldr w16, [x0, #0x14]; cbnz w16, #{kern}; b #{virt}',
        ):
            with self.subTest(code=code):
                self.replace(address, asm_at(code, address))
                self.assert_unchanged_refusal('unknown dispatcher')

    def test_branch_encoding_out_of_range_refuses_all(self):
        # Supply an RX mapping far enough away to exceed CBNZ's range.
        far = self.BASE + 0x200000
        self.symbols['_kern_SwapSetLayer'] = far
        original_mappings = iomfb.DSCChunks.mappings
        with patch.object(iomfb.DSCChunks, 'mappings',
                          lambda chunks: original_mappings(chunks) + [(far, far+4, 0, 5, str(self.path))]):
            self.assert_unchanged_refusal('encoding is out of range')

    def test_missing_signature_refuses_before_writes(self):
        self.replace(self.BASE+0x28, b'\0'*16)
        self.assert_unchanged_refusal('no supported CodeDirectory')

    def test_truncated_signature_slot_refuses_before_writes(self):
        data = self.path.read_bytes(); self.path.write_bytes(data[:self.HASH_OFFSET+2*32+12])
        self.assert_unchanged_refusal('short IOMFB signature')

    def test_overlapping_or_nonexecutable_sites_refuse(self):
        self.symbols['_IOMobileFramebufferSwapSetLayer'] = self.sites['SwapBegin'][0]
        # With identical siblings this is otherwise a valid duplicate span.
        self.symbols['_kern_SwapSetLayer'] = self.sites['SwapBegin'][1]
        self.symbols['_virt_SwapSetLayer'] = self.sites['SwapBegin'][2]
        self.assert_unchanged_refusal('overlapping IOMFB')
        self.symbols['_IOMobileFramebufferSwapSetLayer'] = self.BASE + self.CODE_SIZE - 8
        self.assert_unchanged_refusal('not uniquely executable')

    def test_null_branch_inside_rewrite_refuses(self):
        address, _, _, _ = self.sites['SwapEnd']
        self.replace(address, self.original(address, address+8))
        self.assert_unchanged_refusal('invalid null-connection')

    def test_signature_failure_is_not_reported_success(self):
        with patch.object(iomfb, 'reattest_modified_pages', return_value=[]):
            with self.assertRaisesRegex(RuntimeError, 'page hash differs'):
                self.apply()
        self.assertNotIn('algorithm complete', self.output.getvalue())

    def test_changed_classified_bytes_refuse_before_writer(self):
        original = iomfb._signature_pages
        def mutate(chunks, sites):
            result = original(chunks, sites)
            address = self.sites['SwapSetLayer'][0]
            self.replace(address, asm_at('nop', address))
            return result
        with patch.object(iomfb, '_signature_pages', side_effect=mutate), \
             patch.object(iomfb.DSCChunks, 'write_at_vma') as writer:
            with self.assertRaisesRegex(ValueError, 'input changed after preflight'):
                self.apply()
            writer.assert_not_called()


if __name__ == '__main__':
    unittest.main()
