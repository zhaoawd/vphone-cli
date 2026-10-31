#!/usr/bin/env python3
"""Archive the single consumed runtime approval without rewriting older batches."""
import hashlib
import json
from pathlib import Path
import shutil

ROOT=Path(__file__).resolve().parents[3]
WORK=ROOT/'.build/t32-t33-followup-20261023'
DEST=ROOT/'research/upstream_integration_2026-10-15/evidence/T32-T33-followup-20261023/runtime-approved'


def main():
    if (DEST/'manifest.json').exists():raise ValueError('Completed runtime evidence must be preserved')
    result=json.loads((WORK/'runtime-observation/result.json').read_text())
    safety=json.loads((WORK/'runtime-safety.json').read_text())
    if not safety['VMStopped'] or not all(safety['processesAbsent'].values()) or not safety['debugserverAbsent']:
        raise ValueError('Runtime cleanup has not been independently checked')
    inputs=[WORK/name for name in ['runtime-plan.json','runtime-plan-sha256.txt','runtime-approval.json',
        'runtime-backup.json','executed-runtime-observer.py','root-start-auth.log','root-window-start.log',
        'runtime-observation-execution.log','runtime-safety.json','runtime-preservation.json',
        'runtime-preservation-execution.log','observation-phase-red.log','observation-phase-green.log']]
    inputs.extend(p for directory in ['boot-window','runtime-observation'] for p in (WORK/directory).iterdir() if p.is_file())
    inputs.extend(ROOT/name for name in ['TASKS.md','research/0_binary_patch_comparison.md'])
    inputs.extend(ROOT/'research/upstream_integration_2026-10-15'/name for name in [
        'T32_T33_installed_effects_20261023.md','progress.md','tasks.json','local_reconciliation.json',
        'tools/observe_t32_runtime.py','tools/test_t32_runtime_observation.py',
        'tools/start_t32_observation_window.py','tools/verify_t32_runtime_preservation.py',
        'tools/archive_t32_runtime_observation.py'])
    for source in inputs:
        if not source.is_file() or source.is_symlink():raise ValueError('Invalid evidence input: '+str(source))
    expected={DEST/'files'/source.relative_to(ROOT) for source in inputs}
    if DEST.exists():
        existing={p for p in DEST.rglob('*') if p.is_file()}
        if not existing.issubset(expected):raise ValueError('Unexpected files in incomplete archive')
    DEST.mkdir(exist_ok=True);records=[]
    for source in sorted(set(inputs)):
        if source.is_symlink():raise ValueError('Linked evidence input')
        target=DEST/'files'/source.relative_to(ROOT);target.parent.mkdir(parents=True,exist_ok=True)
        digest=hashlib.sha256(source.read_bytes()).hexdigest()
        if not target.exists():shutil.copy2(source,target)
        if hashlib.sha256(target.read_bytes()).hexdigest()!=digest:raise ValueError('Copy differs')
        records.append(dict(origin=str(source.relative_to(ROOT)),path=str(target.relative_to(DEST)),
                            bytes=target.stat().st_size,sha256=digest))
    manifest=dict(schemaVersion=1,scope='One approved T32 GUI boot; failed AA.gl observation and normal shutdown',
                  accepted=False,runtimeValidated=False,patchCausalityValidated=False,
                  result=result['state'],rawGigalockerSaved=False,normalGUIBoots=1,
                  normalShutdown=True,windowAttachments=1,windowSeconds=safety['secondsToHelperExit'],
                  postRuntimeAudit='awaiting_system_authentication',
                  executedObserver='files/.build/t32-t33-followup-20261023/executed-runtime-observer.py',
                  currentObserverIsUnexecutedCorrection=True,count=len(records),files=records)
    (DEST/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    for row in records:
        path=DEST/row['path']
        if path.stat().st_size!=row['bytes'] or hashlib.sha256(path.read_bytes()).hexdigest()!=row['sha256']:
            raise ValueError('Archive verification failed')
    print(json.dumps(dict(manifest=str(DEST/'manifest.json'),files=len(records),allDigestsVerified=True)))


if __name__=='__main__':main()
