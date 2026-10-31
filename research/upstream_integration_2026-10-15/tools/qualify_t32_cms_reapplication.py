#!/usr/bin/env python3
"""Qualify saved reapplication evidence without changing the failed exact-byte result."""
import importlib.util
import json
import os
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[3]
WORK=ROOT/'.build/t32-t33-completion-20261023'
sys.path.insert(0,str(ROOT/'scripts'))
import cfw_disk_txn as txn
import cfw_guest_evidence as evidence
import cfw_verify_effects as audit
from verify_t32_cms_reapplication import compare


def main():
    native=json.loads(evidence.read(WORK/'resumed-file-acceptance-plan.json'))
    finalization=json.loads(evidence.read(WORK/'resumed-finalization.json'))
    if finalization['state']!='native-failure-archived':raise ValueError('Preserve native failure first')
    manifest_path=Path(finalization['archive'])
    if evidence.digest(manifest_path)!=finalization['archiveSHA256']:raise ValueError('Archive differs')
    manifest=json.loads(evidence.read(manifest_path))
    for row in manifest['files']:
        if evidence.digest(manifest_path.parent/row['path'])!=row['sha256']:raise ValueError('Archived evidence differs')
    vm=Path(native['vm']);on=json.loads(evidence.read(WORK/'resumed-offline-acceptance/on.json'))
    off=json.loads(evidence.read(WORK/'resumed-offline-acceptance/off.json'))
    originals=json.loads(evidence.read(vm/'.cfw-history'/on['transactionID']/'guest-file-originals.json'))['members']
    print('Checking current publication and saved signing chains',flush=True)
    with audit.locked_vm(vm):
        txn.require_unheld(vm/'Disk.img',os.getpid(),'qualification disk')
        archive,record,checkpoint,final=txn.committed_guest_evidence(vm)
        if record['id']!='20261023T093802Z-XHDHXIve' or checkpoint['generationID']!=native['generationID']:
            raise ValueError('Current generation/publication differs')
        targets={row['target']:row['state'] for row in final['outputs'] if row['target'] in native['targets']}
        if set(targets)!=set(native['targets']):raise ValueError('Incomplete target set')
        def signing_rows(history):
            result={}
            for line in evidence.read(history/'guest-changes.jsonl').splitlines():
                row=json.loads(line)
                if row['target'] in targets and row.get('effect',{}).get('operation')=='sign':
                    if row['target'] in result:raise ValueError('Ambiguous signer operation')
                    result[row['target']]=row
            if set(result)!=set(targets):raise ValueError('Missing signer operations')
            return result
        first_history=vm/'.cfw-history'/on['transactionID']
        first_signers=signing_rows(first_history);last_signers=signing_rows(archive);comparisons={}
        for target,state in targets.items():
            first=on['targets'][target];restored=off['targets'][target]
            if restored!=originals[target]['state'] or first==restored:raise ValueError('Exact original restoration failed')
            if {k:v for k,v in state.items() if k!='sha256'}!={k:v for k,v in first.items() if k!='sha256'}:
                raise ValueError('Installed metadata differs')
            a,b=first_signers[target],last_signers[target]
            if (a['beforeSHA256']!=b['beforeSHA256']
                    or a['effect']['signerArguments']!=b['effect']['signerArguments']):
                raise ValueError('Signing input or arguments differ')
            left=first_history/'effect-blobs'/first['sha256'];right=archive/'effect-blobs'/state['sha256']
            if evidence.digest(left)!=first['sha256'] or evidence.digest(right)!=state['sha256']:
                raise ValueError('Saved signed file differs')
            comparison=compare(left,right)
            if not comparison['qualifiedSignatureTimeDifference']:raise ValueError('Unexpected comparison')
            comparison.update(exactOriginalRestoration=True,installedMetadataEqual=True,
                              signingInputSHA256=a['beforeSHA256'],signingArgumentsEqual=True)
            comparisons[target]=comparison
    print('Checking complete original VM preservation and 342 frozen inputs',flush=True)
    path=Path(__file__).with_name('execute_t32_resumed_file_acceptance.py')
    spec=importlib.util.spec_from_file_location('native_readback',path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    module.verify_files(Path(native['sourceVM']),native['originalBootSHA256'],native['originalBootIdentity'])
    for path,digest in native['frozenInputs'].items():
        if evidence.digest(Path(path))!=digest:raise ValueError('Frozen input differs: '+path)
    report=dict(state='signature-time-qualified-reapplication',comparisons=comparisons,
        transactionID=record['id'],generationID=checkpoint['generationID'],
        publicationSHA256=checkpoint['imageSHA256'],VM=str(vm),
        originalFilesFullReadback=len(native['originalBootSHA256']),frozenInputsVerified=len(native['frozenInputs']),
        archivedFilesVerified=len(manifest['files']),nativeFailureArchive=str(manifest_path),
        nativeFailureArchiveSHA256=finalization['archiveSHA256'],
        exactWholeFileReapplicationPassed=False,nativeAcceptanceResultChanged=False,
        currentDiskPublicationVerified=True,currentInstalledReadbackPerformed=False,
        VMStarts=0,securityWindows=0,VMWritten=False,trustedGuestOriginQualified=False,
        runtimeValidated=False,accepted=False)
    evidence.write_new(WORK/'qualified-signature-reapplication.json',json.dumps(report,indent=2).encode()+b'\n')
    print(json.dumps(dict(state=report['state'],targets=len(comparisons),accepted=False)),flush=True)

if __name__=='__main__':main()
