#!/usr/bin/env python3
"""Read real T32/T33 DSC publication and Undo evidence under the VM lock.

Run through scripts/vm_lock.py VM fw-receipts -- PYTHON THIS_SCRIPT ... .
Does not mount, boot or write the guest. Complete live-image equality is required
before recording the immediate installed/restored observation. Semantic checks
use the instruction location revealed by the independent readonly diagnostic.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts'))
import cfw_disk_txn as transaction
import cfw_guest_evidence as evidence
from patchers import component_effects as effects, guest_undo
from patchers import cfw_patch_iomfb_swapend as swap

DECLARATION = 'dyld-boot-iomfb_swapend'


def instruction(path, diagnostic):
    with path.open('rb') as stream:
        stream.seek(diagnostic['fileOffset']); raw = stream.read(4)
    decoded = list(swap._cs.disasm(raw, int(diagnostic['instructionAddress'], 16)))
    if len(decoded) != 1 or decoded[0].size != 4:
        raise ValueError('saved SwapEnd instruction does not decode exactly')
    operand = swap._mov_reg_imm(decoded[0])
    if operand is None or operand[0] != 'w3':
        raise ValueError('saved SwapEnd instruction is not the revealed size operand')
    return dict(register=operand[0], value=operand[1], bytes=raw.hex(),
                mnemonic=decoded[0].mnemonic, operands=decoded[0].op_str)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vm', required=True, type=Path)
    parser.add_argument('--phase', required=True, choices=('installed', 'restored'))
    parser.add_argument('--source-diagnostic', required=True, type=Path)
    parser.add_argument('--installed-proof', type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    vm, out = args.vm.resolve(strict=True), args.out.resolve()
    if vm != ROOT / 'vm-t32-t33-dsc-20261018':
        raise ValueError('DSC acceptance is scoped to the explicitly selected independent VM')
    if (args.phase == 'restored') != (args.installed_proof is not None):
        raise ValueError('restored observation requires the earlier installed proof')
    transaction.require_lock(vm)
    out.mkdir(parents=True, exist_ok=False)
    result = dict(schemaVersion=1, state='running', vm=str(vm), phase=args.phase,
                  runtimeValidated=False, graphicsValidated=False)
    def save(): (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    save()
    try:
        diagnostic_raw = args.source_diagnostic.resolve(strict=True).read_bytes()
        diagnostic = json.loads(diagnostic_raw)
        if (diagnostic.get('diagnosticOnly') is not True or diagnostic.get('readOnly') is not True
                or diagnostic.get('symbol') != swap.SWAPEND_SYMBOL):
            raise ValueError('original DSC observation is not the readonly semantic diagnostic')
        (out / 'source-diagnostic.json').write_bytes(diagnostic_raw)
        result['sourceDiagnosticSHA256'] = hashlib.sha256(diagnostic_raw).hexdigest()
        committed = transaction.committed_guest_evidence(vm)
        if committed is None: raise ValueError('missing committed guest publication')
        archive, record, checkpoint, final = committed
        if record['version'] != 4 or checkpoint['schemaVersion'] != 2:
            raise ValueError('new acceptance requires v4 publication evidence')
        if checkpoint['currentImageSHA256'] != checkpoint['imageSHA256']:
            raise ValueError('immediate DSC observation requires the unbooted publication image')
        result.update(transactionID=record['id'], generationID=checkpoint['generationID'],
                      imageSHA256=checkpoint['imageSHA256'], currentRawImageMatchesPublication=True)
        for name in (transaction.RECORD, evidence.CHECKPOINT, evidence.UNDO, evidence.FINAL):
            (out / name).write_bytes(evidence.read(archive / name))
        member = diagnostic['member']
        source_sha = diagnostic['memberSHA256']
        if args.phase == 'installed':
            if record.get('operation') is not None: raise ValueError('expected an installation journal')
            preview = guest_undo.preview(vm, checkpoint['generationID'], [DECLARATION], _committed=committed)
            # The production verifier above qualifies this checkpoint; preview
            # supplies historical candidates only and grants no write authority.
            (out / 'preview.json').write_text(json.dumps(preview, indent=2) + '\n')
            matches = [item for item in preview['entries'] if guest_undo.member_name(item['target']) == member]
            if len(matches) != 1: raise ValueError('SwapEnd has no unique qualified DSC suffix')
            selected = matches[0]
            if (selected['restoredSHA256'] != source_sha or not selected['restoresFirstOriginal']
                    or preview['writeAuthorized'] is not False or preview['runtimeValidated'] is not False):
                raise ValueError('SwapEnd candidate differs from independently observed original')
            original = effects.blob(archive / evidence.STORE, source_sha)
            installed = effects.blob(archive / evidence.STORE, selected['currentSHA256'])
            original_instruction, installed_instruction = instruction(original, diagnostic), instruction(installed, diagnostic)
            if (original_instruction['value'] != diagnostic['sourceSize']
                    or installed_instruction['value'] != diagnostic['targetSize']):
                raise ValueError('actual preserved DSC instructions differ from the revealed source/target values')
            original_pages, installed_pages = guest_undo.verify_code_pages(original), guest_undo.verify_code_pages(installed)
            if original_pages != diagnostic['verifiedCodePages'] or installed_pages != original_pages:
                raise ValueError('complete DSC CodeDirectory page count differs')
            result.update(declaration=DECLARATION, member=member, originalSHA256=source_sha,
                installedSHA256=selected['currentSHA256'], originalInstruction=original_instruction,
                installedInstruction=installed_instruction, verifiedOriginalCodePages=original_pages,
                verifiedInstalledCodePages=installed_pages)
        else:
            earlier_raw = args.installed_proof.resolve(strict=True).read_bytes()
            earlier = json.loads(earlier_raw)
            (out / 'installed-proof.json').write_bytes(earlier_raw)
            if (earlier.get('state') != 'passed' or earlier.get('vm') != str(vm)
                    or earlier.get('phase') != 'installed' or earlier['generationID'] != checkpoint['generationID']
                    or earlier['originalSHA256'] != source_sha or record.get('operation') != guest_undo.OPERATION):
                raise ValueError('Undo observation differs from the earlier installed generation/member')
            request = json.loads(evidence.read(archive / guest_undo.REQUEST))
            receipt = json.loads(evidence.read(archive / guest_undo.RECEIPTS))
            applied = json.loads(evidence.read(archive / guest_undo.APPLIED))
            if (request['parentTransactionID'] != earlier['transactionID']
                    or receipt['removedDeclarations'] != [DECLARATION]
                    or receipt['guestOrigin']['state'] != 'unknown' or receipt['runtimeValidated'] is not False):
                raise ValueError('Undo publication does not remove the selected parent effect with unknown origin')
            selected = [item for item in applied['entries'] if guest_undo.member_name(item['target']) == member]
            outputs = [item for item in final['outputs'] if guest_undo.member_name_or_none(item['target']) == member]
            if (len(selected) != 1 or len(outputs) != 1 or selected[0]['beforeSHA256'] != earlier['installedSHA256']
                    or selected[0]['afterSHA256'] != source_sha or outputs[0]['state']['sha256'] != source_sha):
                raise ValueError('actual Undo application/final readback differs from the original member')
            restored = effects.blob(archive / evidence.STORE, source_sha)
            restored_instruction = instruction(restored, diagnostic)
            restored_pages = guest_undo.verify_code_pages(restored)
            if restored_instruction['value'] != diagnostic['sourceSize'] or restored_pages != diagnostic['verifiedCodePages']:
                raise ValueError('restored DSC instruction or full code pages differ from original')
            for name in guest_undo.FILES: (out / name).write_bytes(evidence.read(archive / name))
            result.update(declaration=DECLARATION, member=member, originalSHA256=source_sha,
                parentTransactionID=request['parentTransactionID'], restoredInstruction=restored_instruction,
                verifiedRestoredCodePages=restored_pages, guestOrigin='unknown')
        result['state'] = 'passed'
    except Exception as error:
        result.update(state='failed', error=f'{type(error).__name__}: {error}')
        raise
    finally: save()
    print(json.dumps(result))


if __name__ == '__main__': main()
