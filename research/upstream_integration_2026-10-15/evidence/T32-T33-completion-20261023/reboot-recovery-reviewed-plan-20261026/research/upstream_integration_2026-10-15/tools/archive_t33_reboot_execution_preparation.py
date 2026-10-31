"""Archive the actual readonly replay and the exact unapproved continuation plan."""
import json
import os
from pathlib import Path
import shutil

import execute_t33_reboot_acceptance as current

base = current.base
OUT = current.ROOT / 'research/upstream_integration_2026-10-15/evidence/T32-T33-completion-20261023/reboot-recovery-reviewed-plan-20261026'


def main():
    if OUT.exists(): raise ValueError('Preserve existing reviewed plan archive')
    plan = current.validate(current.read(current.WORK / 'offline-plan.json'))
    digest = base.evidence.digest(current.WORK / 'offline-plan.json'); current.configure(digest)
    base.verify_inputs(plan); base.verify_execution_inputs(); current.retained.previous.unrelated(plan)
    if base.target_attachments(plan): raise ValueError('Target remains attached')
    for path in (current.WORK / 'approval.json', current.WORK / 'native-launch.claim',
                 current.WORK / 'native-execution.claim', current.BACKUP, current.PRESERVED,
                 current.NEW_WORK, current.VM / '.cfw-reboot-identity.json', Path(plan['installedCLI']).parents[3]):
        if os.path.lexists(path): raise ValueError('This archive requires an unapproved, unexecuted plan')
    paths = {p for p in current.WORK.rglob('*') if p.is_file()}
    paths |= {p for p in Path(plan['readonlyReplayDirectory']).rglob('*') if p.is_file()}
    paths |= {current.BASE / 'reboot-real-identity-preflight-20261026.log',
        current.BASE / 'reboot-acceptance-preparation-20261026.log',
        current.BASE / 'reboot-final-continuation-tests-20261026.log', current.CANDIDATE,
        current.OLD_WORK / 'execution/exp/on.json', current.OLD_WORK / 'offline-plan.json', Path(__file__)}
    paths |= set(Path(__file__).parent.glob('*t33*reboot*.py'))
    paths |= {Path(__file__).with_name(name) for name in ('run_t33_recovered_undo.py', 'test_t33_recovered_undo_worker.py')}
    paths |= {current.ROOT / 'research/upstream_integration_2026-10-15' / name for name in
        ('T32_T33_reboot_recovery_execution_review_20261026.md', 'T32_T33_reboot_recovery_20261026.md')}
    OUT.mkdir(); rows = []
    for source in sorted(paths):
        relative = source.relative_to(current.ROOT); target = OUT / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        before = base.evidence.digest(source); shutil.copyfile(source, target)
        if base.evidence.digest(source) != before or base.evidence.digest(target) != before:
            raise ValueError('Reviewed preparation archive differs')
        rows.append(dict(path=str(relative), sha256=before, bytes=target.stat().st_size))
    volume = os.statvfs(current.ROOT)
    result = dict(state='prepared-not-approved', planSHA256=digest, candidate=plan['candidate']['version'],
        readonlyReplay=current.read(Path(plan['readonlyReplayDirectory']) / 'result.json'),
        frozenInputs=len(plan['frozenInputs']), executionInputs=len(current.read(current.WORK / 'executor-inputs.json')['files']),
        availableBytes=volume.f_bavail * volume.f_frsize, minimumInitialBytes=plan['minimumInitialFreeBytes'],
        minimumEachCFWBytes=plan['minimumEachCFWFreeBytes'], beforeWriteBackupFiles=len(plan['targets'][0]['currentBootFiles']),
        priorPartialSourceStatus='staged-unsealed-unpublished-and-unchanged',
        preservedFirstOnTransaction=current.FIRST, preservedFirstOnProducer='2.6.2-local.f43043c4c559',
        repeatedFirstOn=0, repeatedUndoWrites=0, automaticRetry=False, automaticRollback=False,
        additionalDeletionAllowed=False, candidateInstalled=False, registrationInstalled=False,
        published=False, VMStarts=0, securityWindows=0, runtimeValidated=False, accepted=False)
    base.save(OUT / 'reviewed-preparation.json', result)
    path = OUT / 'reviewed-preparation.json'; rows.append(dict(path='reviewed-preparation.json', sha256=base.evidence.digest(path), bytes=path.stat().st_size))
    base.save(OUT / 'manifest.json', dict(schemaVersion=1, files=rows, accepted=False))
    for row in rows:
        if base.evidence.digest(OUT / row['path']) != row['sha256']: raise ValueError('Archive readback differs')
    print(json.dumps(dict(result, archiveFiles=len(rows), manifestSHA256=base.evidence.digest(OUT / 'manifest.json'))))


if __name__ == '__main__':
    main()
