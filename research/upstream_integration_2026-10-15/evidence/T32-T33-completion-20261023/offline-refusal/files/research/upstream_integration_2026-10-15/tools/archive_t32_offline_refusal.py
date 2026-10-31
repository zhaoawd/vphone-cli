#!/usr/bin/env python3
"""Preserve the approved attempt, fail-closed diagnosis and subsequent preparation."""
import json
from pathlib import Path
import shutil
import sys
ROOT=Path(__file__).resolve().parents[3];sys.path.insert(0,str(ROOT/'scripts'))
import cfw_guest_evidence as evidence
WORK=ROOT/'.build/t32-t33-completion-20261023'
DEST=ROOT/'research/upstream_integration_2026-10-15/evidence/T32-T33-completion-20261023/offline-refusal'


def main():
    if DEST.exists():raise ValueError('Preserve prior batch')
    preserved=json.loads(evidence.read(WORK/'offline-refusal-preservation.json'))
    if not preserved['all12PersistentFilesUnchanged'] or preserved['unfinishedTransactions']:
        raise ValueError('Incomplete post-refusal preservation')
    names=['offline-root-execution.log','offline-auth-result.log','offline-refusal-preservation.json',
        'offline-frozen-inputs-after-refusal.json','identity-missing-history.json','identity-metadata-replay.json',
        'identity-checkpoint-replay.json','identity-expected.json','identity-minimal-red.log','identity-minimal-red-r2.log',
        'identity-metadata-red.log','identity-actual-checkpoint-red-r2.log','identity-actual-diagnosis-confirmed.log',
        'identity-v5-green-r1.log','identity-v4-v5-final.log','identity-file-full-green.log','identity-bridge-related-swift.log',
        'release-identity-bridge.log','candidate-build-r5.log','candidate-r5.json','fresh-archive-sources.json',
        'fresh-acceptance-guards.log','fresh-acceptance-guards-r2.log','fresh-plan-prepared.json','fresh-file-acceptance-plan.json',
        'fresh-file-acceptance-approval.json','human-fresh-offline-approval.json']
    paths=[WORK/name for name in names]+list((WORK/'offline-acceptance').iterdir())
    paths.extend(ROOT/name for name in ('sources/FirmwarePatcher/Pipeline/FirmwareGuestDiskIdentity.swift',
        'tests/FirmwarePatcherTests/FirmwareGuestDiskIdentityReplayTests.swift','tests/VPhoneCLITests/CFWFrozenPlanTests.swift',
        'tests/cfw_identity_bridge_fixture.py','tests/cfw_file_identity_bridge_fixture.py','TASKS.md',
        'research/upstream_integration_2026-10-15/T32_T33_completion_20261023.md'))
    paths.extend(Path(__file__).parent/name for name in ('execute_t32_fresh_file_acceptance.py',
        'test_t32_fresh_file_acceptance.py','prepare_t32_fresh_acceptance_plan.py','archive_t32_offline_refusal.py'))
    rows=[]
    for source in sorted(set(paths)):
        if not source.is_file() or source.is_symlink():raise ValueError('Invalid input '+str(source))
        target=DEST/'files'/source.relative_to(ROOT);target.parent.mkdir(parents=True,exist_ok=True)
        digest=evidence.digest(source);shutil.copy2(source,target)
        if evidence.digest(target)!=digest:raise ValueError('Copy differs')
        rows.append(dict(origin=str(source.relative_to(ROOT)),path=str(target.relative_to(DEST)),bytes=target.stat().st_size,sha256=digest))
    result=dict(schemaVersion=1,scope='Original T32 offline attempt refused before staging; required v4 history missing; v5 Swift bridge fix; separately approved isolation preparation',
        accepted=False,VMStarts=0,securityWindows=0,originalVM12PersistentFilesUnchanged=True,
        oldPlanResult='refused before staging; no automatic retry',newPlan='approved; awaiting native administrator authentication',
        oldHistoryMissingCause='unknown',files=rows,count=len(rows))
    evidence.write_new(DEST/'manifest.json',json.dumps(result,indent=2).encode()+b'\n')
    for row in rows:
        if evidence.digest(DEST/row['path'])!=row['sha256']:raise ValueError('Final archive verification differs')
    print(json.dumps(dict(manifest=str(DEST/'manifest.json'),files=len(rows),allDigestsVerified=True)))


if __name__=='__main__':main()
