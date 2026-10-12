#!/usr/bin/env python3
"""Read-only mount wrapper analysis, from current Mach-O strings and Capstone.

Accepts a decompressed kernel. Does not patch or write the input image.
Symbol names inferred from strings are explicitly labelled in the output.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct

from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
from capstone.arm64 import ARM64_OP_IMM, ARM64_OP_REG


def inspect(data):
    assert struct.unpack_from('<I', data)[0] == 0xFEEDFACF, 'requires Mach-O 64'
    segments, code = [], []
    command = 32
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        kind, size = struct.unpack_from('<II', data, command)
        if kind == 0x19:
            _, _, name, va, vsize, offset, fsize, maxprot, initprot, count, _ = struct.unpack_from('<II16sQQQQiiII', data, command)
            segments.append((va, offset, fsize))
            if initprot & 4 and count == 0:
                code.append((va, offset, fsize))
            for i in range(count):
                section = command + 72 + i * 80
                section_name, segment_name, address, length, file_offset = struct.unpack_from('<16s16sQQI', data, section)
                if section_name.rstrip(b'\0') == b'__text':
                    code.append((address, file_offset, length))
        assert size >= 8
        command += size

    def file_offset(va):
        va &= (1 << 64) - 1
        for base, offset, size in segments:
            if base <= va < base + size:
                return offset + va - base
        raise ValueError(f'unmapped VA {va:#x}')

    def virtual_address(offset):
        for va, base, size in segments:
            if base <= offset < base + size:
                return va + offset - base
        raise ValueError(f'unmapped offset {offset:#x}')

    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    md.skipdata = True
    detail = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    detail.detail = True

    def instructions(offset, size):
        return list(detail.disasm(data[offset:offset + size], virtual_address(offset)))

    def function_start(offset):
        # Kernel arm64e functions have a PAC entry; this is an analysis anchor,
        # not a symbol lookup or a replacement for a verified symbol dataset.
        for pos in range(offset - offset % 4, max(0, offset - 0x3000), -4):
            ins = instructions(pos, 4)
            if ins and ins[0].mnemonic in ('pacibsp', 'paciasp'):
                return pos
        return None

    strings = []
    position = 0
    while (position := data.find(b'mount_common()', position)) >= 0:
        strings.append(virtual_address(position))
        position += 1
    xrefs = []
    for va, offset, size in code:
        for address, _, mnemonic, _ in md.disasm_lite(data[offset:offset + size], va):
            if mnemonic != 'adrp':
                continue
            off = file_offset(address)
            ins = instructions(off, 24)
            if not ins or len(ins[0].operands) != 2:
                continue
            adr = ins[0].operands
            if adr[0].type != ARM64_OP_REG or adr[1].type != ARM64_OP_IMM:
                continue
            page = adr[1].imm & ((1 << 64) - 1)
            if not any(target >> 12 == page >> 12 for target in strings):
                continue
            for following in ins[1:]:
                ops = following.operands
                if (following.mnemonic == 'add' and len(ops) == 3
                        and ops[1].type == ARM64_OP_REG and ops[1].reg == adr[0].reg
                        and ops[2].type == ARM64_OP_IMM and page + ops[2].imm in strings):
                    xrefs.append({'adrp': off, 'add': file_offset(following.address), 'function': function_start(off)})

    wrappers = []
    for common in sorted({row['function'] for row in xrefs if row['function'] is not None}):
        common_va = virtual_address(common)
        start, end = max(0, common - 0x5000), min(len(data), common + 0x5000)
        callers = set()
        for ins in instructions(start, end - start):
            if ins.mnemonic == 'bl' and ins.operands[0].type == ARM64_OP_IMM and (ins.operands[0].imm & ((1 << 64) - 1)) == common_va:
                callers.add(function_start(file_offset(ins.address)))
        for caller in sorted(c for c in callers if c is not None and c != common):
            body = instructions(caller, 0x1200)
            for index, ins in enumerate(body[1:], 1):
                if ins.mnemonic in ('pacibsp', 'paciasp'):
                    body = body[:index]
                    break
            flags, states = [], []
            for index, ins in enumerate(body):
                ops = ins.operands
                if (ins.mnemonic == 'tbnz' and len(ops) == 3 and ops[1].type == ARM64_OP_IMM
                        and ops[1].imm == 5 and ops[2].type == ARM64_OP_IMM):
                    target = instructions(file_offset(ops[2].imm), 4)
                    if target and target[0].mnemonic == 'mov' and len(target[0].operands) == 2 and target[0].operands[1].type == ARM64_OP_IMM and target[0].operands[1].imm == 1:
                        flags.append(ins)
                if ins.mnemonic == 'ldrb' and index + 1 < len(body):
                    branch = body[index + 1]
                    bops = branch.operands
                    if (branch.mnemonic in ('tbz', 'tbnz') and len(bops) == 3
                            and bops[0].reg == ops[0].reg and bops[1].type == ARM64_OP_IMM and bops[1].imm == 6):
                        states.append(ins)
            if len(flags) == len(states) == 1:
                wrappers.append({'function_offset': hex(caller), 'mount_common_offset': hex(common),
                                 'flag_gate_offset': hex(file_offset(flags[0].address)),
                                 'state_load_offset': hex(file_offset(states[0].address)),
                                 'disassembly': [f'{ins.address:#018x}: {ins.mnemonic} {ins.op_str}' for ins in body]})
    return {'sha256': hashlib.sha256(data).hexdigest(), 'string_vas': [hex(va) for va in strings],
            'string_xrefs': xrefs, 'wrappers': wrappers,
            'symbol_identity': 'inferred from current-image strings and call flow; symbol dataset unavailable'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kernel', type=Path)
    args = parser.parse_args()
    result = inspect(args.kernel.read_bytes())
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if len(result['wrappers']) == 1 else 1)
