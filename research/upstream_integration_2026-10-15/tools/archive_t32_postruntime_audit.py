#!/usr/bin/env python3
"""Preserve the strict post-runtime mismatch and independent mount cleanup."""
import hashlib
import json
from pathlib import Path
import shutil

ROOT=Path(__file__).resolve().parents[3]
RESEARCH=ROOT/'research/upstream_integration_2026-10-15'
WORK=ROOT/'.build/t32-t33-followup-20261023'
DEST=RESEARCH/'evidence/T32-T33-followup-20261023/post-runtime-readonly'


def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if DEST.exists():raise ValueError('Preserve completed or partial evidence; use a separate new archive')
    report=json.loads((WORK/'post-runtime-audit.json').read_text())
    preserved=json.loads((WORK/'post-runtime-preservation.json').read_text())
    if not (report['cleanup']['imageDetached'] and report['cleanup']['mountsReleased']
            and preserved['auditImageIdentityStable'] and not preserved['targetImageAttached']):
        raise ValueError('Independent readonly cleanup proof is incomplete')
    prior={}
    for relative in ['T32-T33-followup-20261023','T32-T33-followup-20261023/runtime-approved',
                     'T32-T33-new-vm-20261018/dsc-on-off-on-20261020-resume']:
        folder=RESEARCH/'evidence'/relative;entries=json.loads((folder/'manifest.json').read_text())['files']
        if isinstance(entries,dict):entries=[dict(path=name,**row) for name,row in entries.items()]
        for row in entries:
            source=folder/row['path']
            if source.stat().st_size!=row['bytes'] or digest(source)!=row['sha256']:
                raise ValueError('Prior archive changed: '+str(source))
        prior[relative]=len(entries)
    names=['post-runtime-audit.json','post-runtime-audit-execution.log','runtime-audit-comparison.json',
           'post-runtime-preservation.json','readonly-auth-redisplay.json','readonly-auth-retry-result.json',
           'runtime-preservation.json','runtime-plan.json','runtime-approval.json']
    inputs=[WORK/name for name in names]
    inputs.extend(RESEARCH/name for name in ['T32_T33_installed_effects_20261023.md','progress.md',
        'tasks.json','local_reconciliation.json','tools/archive_t32_postruntime_audit.py'])
    inputs.extend(ROOT/name for name in ['TASKS.md','research/0_binary_patch_comparison.md',
        'scripts/cfw_verify_effects.py','scripts/patchers/installed_effects.py'])
    for source in inputs:
        if source.is_symlink() or not source.is_file():raise ValueError('Invalid evidence input: '+str(source))
    DEST.mkdir();records=[]
    for source in sorted(set(inputs)):
        target=DEST/'files'/source.relative_to(ROOT);target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(source,target);expected=digest(source)
        if digest(target)!=expected:raise ValueError('Evidence copy differs')
        records.append(dict(origin=str(source.relative_to(ROOT)),path=str(target.relative_to(DEST)),
                            bytes=target.stat().st_size,sha256=expected))
    manifest=dict(schemaVersion=1,scope='Post-runtime independent readonly installed-effect audit',
                  state=report['state'],passed=report['passed'],accepted=False,runtimeValidated=False,
                  patchCausalityValidated=False,originQualified=False,writeAuthorized=False,
                  rawGigalockerSaved=False,mountsReleased=True,priorArchivesReverified=prior,
                  count=len(records),files=records)
    (DEST/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    for row in records:
        target=DEST/row['path']
        if digest(target)!=row['sha256'] or target.stat().st_size!=row['bytes']:
            raise ValueError('Completed archive check failed')
    print(json.dumps(dict(manifest=str(DEST/'manifest.json'),files=len(records),prior=prior,allDigestsVerified=True)))


if __name__=='__main__':main()
