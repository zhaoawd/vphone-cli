#!/usr/bin/env python3
"""Decode a bounded read-only CMCapture observation; never patches a file."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
from capstone.arm64 import ARM64_OP_IMM, ARM64_OP_MEM, ARM64_OP_REG, ARM64_REG_W0, ARM64_REG_W25, ARM64_REG_X1


def dispatch_selectors(event, decoder):
    metadata = event.get('dispatchMetadata', {})
    if 'stubBase64' not in metadata: return {}
    data = base64.b64decode(metadata['stubBase64'], validate=True)
    assert len(data) == metadata['stubBytes'] and len(data) <= 1024 * 1024
    references = {int(row['slot'], 16): row['selector'] for row in metadata['selectorReferences']}
    instructions = list(decoder.disasm(data, int(metadata['stubPC'], 16)))
    result = {}
    for first, second in zip(instructions, instructions[1:]):
        if (first.mnemonic != 'adrp' or second.mnemonic != 'ldr' or
                len(first.operands) != 2 or len(second.operands) != 2): continue
        a, b = first.operands, second.operands
        if (a[0].type != ARM64_OP_REG or a[0].reg != ARM64_REG_X1 or a[1].type != ARM64_OP_IMM or
                b[0].type != ARM64_OP_REG or b[0].reg != ARM64_REG_X1 or b[1].type != ARM64_OP_MEM or
                b[1].mem.base != ARM64_REG_X1 or b[1].mem.index != 0): continue
        selector = references.get(a[1].imm + b[1].mem.disp)
        if selector: result[first.address] = selector
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--record', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args(); args.output.mkdir(exist_ok=False)
    record = json.loads(args.record.read_text())
    event, = [e for e in record['events'] if e['type'] == 'capture_source_readonly']
    assert event['state'] == 'captured_readonly'
    match, = event['matches']
    data = base64.b64decode(match['instructionsBase64'], validate=True)
    decoder = Cs(CS_ARCH_ARM64, CS_MODE_ARM); decoder.detail = True
    selectors = dispatch_selectors(event, decoder)
    instructions = list(decoder.disasm(data, int(match['startPC'], 16)))
    by_pc = {instruction.address: instruction for instruction in instructions}
    pc = int(match['filterPC'], 16); skip = int(match['skipPC'], 16)
    for address, register in [(pc, ARM64_REG_W0), (pc + 4, ARM64_REG_W25)]:
        instruction = by_pc[address]
        assert instruction.mnemonic == 'cbz'
        assert instruction.operands[0].type == ARM64_OP_REG and instruction.operands[0].reg == register
        assert instruction.operands[1].type == ARM64_OP_IMM and instruction.operands[1].imm == skip
    (args.output / 'instructions.asm').write_text(''.join(
        f'{i.address:#x} {i.mnemonic:8} {i.op_str}\n' for i in instructions))
    (args.output / 'annotated.asm').write_text(''.join(
        f'{i.address:#x} {i.mnemonic:8} {i.op_str}' +
        (' // ' + selectors[i.operands[0].imm] if i.mnemonic == 'bl' and i.operands[0].type == ARM64_OP_IMM and i.operands[0].imm in selectors else '') + '\n'
        for i in instructions))
    (args.output / 'selectors.json').write_text(json.dumps({hex(pc): name for pc, name in selectors.items()}, indent=2) + '\n')
    result = dict(image=event['image'], imageUUID=event['uuid'], pid=record['pid'], runID=record['runID'],
                  recordSHA256=hashlib.sha256(args.record.read_bytes()).hexdigest(),
                  fragmentSHA256=hashlib.sha256(data).hexdigest(), fragmentBytes=len(data),
                  filterPC=match['filterPC'], skipPC=match['skipPC'],
                  originalConditionalBranchesPresent=True, decodedSelectorCount=len(selectors), accepted=False)
    (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__': main()
