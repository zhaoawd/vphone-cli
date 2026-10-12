#!/usr/bin/env python3
"""Qualified less producer capture and final read-only filesystem verification."""
import json
import os
from pathlib import Path
import sys
from patchers import component_effects as effects
from patchers import plan_gate as gate


def run(mode, mount, proof_path):
    plan=gate.from_environment()
    if plan.context['variant']!='less': raise ValueError('filesystem proof requires less context')
    transaction=Path(plan.context['filesystemTransaction'])
    mount=Path(mount);proof_path=Path(proof_path)
    if transaction/'work' not in mount.parents or proof_path.parent!=transaction:
        raise ValueError('filesystem proof is outside transaction ownership')
    current=mount
    while current!=transaction:
        if current.is_symlink() or not current.is_dir(): raise ValueError('linked filesystem proof directory')
        current=current.parent
    evidence=Path(os.environ['VPHONE_GUEST_EVIDENCE'])
    if evidence.parent!=transaction: raise ValueError('filesystem operation evidence belongs to another transaction')
    rows=[json.loads(line) for line in gate.strict_bytes(evidence).splitlines() if line]
    store=transaction/'effect-blobs'
    journal=json.loads(gate.strict_bytes(transaction/'journal.json'))
    required={'system:/usr/libexec/mobileactivationd'}
    options=journal.get('options',{})
    if options.get('noBinpack')!='true' or options.get('noVphoned')!='true':
        required.update({'system:/usr/libexec/launchd_cache_loader','system:/System/Library/xpc/launchd.plist'})
    if {row.get('target') for row in rows}!=required:
        raise ValueError('missing or unexpected required nested filesystem target')
    if mode=='capture':
        gate.require_write_context(plan)
        grouped={}
        for row in rows:
            if row.get('phase')!='filesystem-staging' or row.get('declarationID')!='filesystem-less-cryptex_merge':
                raise ValueError('unknown nested filesystem operation')
            gate.authorize(plan,row['declarationID'],row['target'])
            grouped.setdefault(row['target'],[]).append(row)
        for target,group in grouped.items():
            path=mount/target.removeprefix('system:/')
            before=group[-1].get('effect',{}).get('after')
            if before is None: raise ValueError('nested operation lacks preserved effect')
            # This producer stage includes its explicit chmod/signing actions.
            # Their actual changes compose with, but cannot erase, earlier effects.
            final=effects.capture_change(before,path,store)
            effects.verify([r['effect'] for r in group]+[final],path,store)
            previous=gate.FileSnapshot(before['sha256'],{k:before[k] for k in ('mode','uid','gid')})
            gate.append_evidence(plan,group[-1]['declarationID'],target,path,previous,gate.snapshot(path),effect=final)
        rows=[json.loads(line) for line in gate.strict_bytes(evidence).splitlines() if line]
        effects.verify_rows(plan,rows,{'system':mount},store)
        record={'schemaVersion':1,'generationID':plan.record['generationID'],
                'planDigest':plan.record['planSHA256'],'desiredSHA256':plan.raw_sha256,
                'operationsSHA256':effects.digest(evidence),'tree':effects.state(mount)}
        fd=os.open(proof_path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        with os.fdopen(fd,'wb') as out:
            out.write(effects.canonical(record));out.flush();os.fsync(out.fileno())
        directory=os.open(transaction,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
        try: os.fsync(directory)
        finally: os.close(directory)
    elif mode=='verify':
        record=json.loads(gate.strict_bytes(proof_path))
        if record.get('schemaVersion')!=1 or record['generationID']!=plan.record['generationID'] or record['planDigest']!=plan.record['planSHA256'] or record['desiredSHA256']!=plan.raw_sha256 or record['operationsSHA256']!=effects.digest(evidence):
            raise ValueError('filesystem proof context differs')
        effects.verify_rows(plan,rows,{'system':mount},store)
        if effects.state(mount)!=record['tree']: raise ValueError('final encrypted filesystem tree differs from producer proof')
    else: raise ValueError('unknown filesystem proof operation')
    gate.recheck(plan)


if __name__=='__main__':
    if len(sys.argv)!=4: raise SystemExit('usage: verify_component_effects.py capture|verify mount proof')
    run(*sys.argv[1:])
