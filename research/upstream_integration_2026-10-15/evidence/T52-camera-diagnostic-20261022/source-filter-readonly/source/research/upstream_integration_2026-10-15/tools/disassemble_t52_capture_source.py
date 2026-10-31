#!/usr/bin/env python3
"""Decode a bounded read-only CMCapture observation; never patches a file."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
from capstone.arm64 import ARM64_OP_IMM, ARM64_OP_REG, ARM64_REG_W0, ARM64_REG_W25


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
    result = dict(image=event['image'], imageUUID=event['uuid'], pid=record['pid'], runID=record['runID'],
                  recordSHA256=hashlib.sha256(args.record.read_bytes()).hexdigest(),
                  fragmentSHA256=hashlib.sha256(data).hexdigest(), fragmentBytes=len(data),
                  filterPC=match['filterPC'], skipPC=match['skipPC'],
                  originalConditionalBranchesPresent=True, accepted=False)
    (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__': main()
