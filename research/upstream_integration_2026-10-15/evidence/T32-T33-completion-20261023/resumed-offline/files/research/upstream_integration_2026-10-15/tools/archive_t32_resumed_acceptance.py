#!/usr/bin/env python3
"""Preserve a finished, separately approved isolated continuation."""
import json
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts'))
import cfw_guest_evidence as evidence

WORK = ROOT / '.build/t32-t33-completion-20261023'
DEST = ROOT / 'research/upstream_integration_2026-10-15/evidence/T32-T33-completion-20261023/resumed-offline'


def main():
    result = json.loads(evidence.read(WORK / 'resumed-offline-acceptance/result.json'))
    if DEST.exists():
        raise ValueError('Preserve the existing archive')
    if result.get('VMStarted') is not False or result.get('securityWindowStarted') is not False:
        raise ValueError('Unexpected execution scope')
    passed = result.get('state') == 'resumed-offline-on-off-on-passed'
    if passed and [row['name'] for row in result['phases']] != ['on', 'off', 'reapplied']:
        raise ValueError('Incomplete success evidence')
    plan = json.loads(evidence.read(WORK / 'resumed-file-acceptance-plan.json'))
    names = ['resumed-file-acceptance-plan.json', 'resumed-file-acceptance-approval.json',
             'human-resumed-offline-approval.json', 'resumed-plan-prepared.json',
             'resumed-frozen-inputs-verified.json', 'resumed-root-execution.log',
             'resumed-auth-result.log', 'candidate-package-r6.json',
             'runtime-observer-recheck.log', 'runtime-foreground-red.log', 'runtime-foreground-green.log']
    paths = [WORK / name for name in names]
    paths.extend((WORK / 'resumed-offline-acceptance').iterdir())
    final_checks = ('resumed-preservation.json', 'resumed-cleanup.json',
                    'resumed-frozen-inputs-after-execution.json', 'resumed-prior-archives-preserved.json')
    for name in final_checks:
        path = WORK / name
        if passed and not path.is_file():
            raise ValueError('Successful archive requires completed preservation checks: ' + name)
        if path.exists():
            paths.append(path)
    if passed:
        preservation = json.loads(evidence.read(WORK / final_checks[0]))
        cleanup = json.loads(evidence.read(WORK / final_checks[1]))
        frozen = json.loads(evidence.read(WORK / final_checks[2]))
        if (preservation.get('executorFinalOriginalFullReadbackPassed') is not True
                or preservation.get('exactThreeFileTransitionsPassed') is not True
                or cleanup.get('targetAttachments') != []
                or cleanup.get('bothProtectedVMProcessesPresent') is not True
                or frozen != dict(count=len(plan['frozenInputs']), allDigestsVerified=True)):
            raise ValueError('Successful archive preservation checks differ')
    history = Path(plan['vm']) / '.cfw-history'
    if history.exists():
        for transaction in history.iterdir():
            paths.extend(path for path in transaction.iterdir()
                         if path.is_file() and path.suffix in ('.json', '.jsonl', '.log'))
    paths.extend(ROOT / name for name in (
        'TASKS.md', 'research/0_binary_patch_comparison.md',
        'research/upstream_integration_2026-10-15/T32_T33_completion_20261023.md',
        'research/upstream_integration_2026-10-15/tasks.json',
        'research/upstream_integration_2026-10-15/local_reconciliation.json',
        'research/upstream_integration_2026-10-15/local_reconciliation.md',
        'research/upstream_integration_2026-10-15/progress.md'))
    paths.extend(Path(__file__).parent / name for name in (
        'execute_t32_resumed_file_acceptance.py', 'prepare_t32_resumed_acceptance_plan.py',
        'test_t32_resumed_file_acceptance.py', 'archive_t32_resumed_acceptance.py',
        'verify_t32_resumed_completion.py', 'verify_t32_prior_archives.py',
        'observe_t32_runtime.py', 'test_t32_runtime_observation.py',
        'finalize_t32_resumed_acceptance.py'))
    records = []
    for source in sorted(set(paths)):
        digest = evidence.digest(source)
        target = DEST / 'files' / source.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        if evidence.digest(target) != digest or evidence.digest(source) != digest:
            raise ValueError('Source changed or archive differs: ' + str(source))
        records.append(dict(origin=str(source.relative_to(ROOT)), path=str(target.relative_to(DEST)),
                            bytes=target.stat().st_size, sha256=digest))
    manifest = dict(schemaVersion=1, accepted=False, runtimeValidated=False,
                    guestOriginQualified=False, VMStarts=0, securityWindows=0,
                    scope='Approved continuation on retained fresh-generation copy; exact three-Mach-O file transitions',
                    result=result, offlineAcceptancePassed=passed,
                    excludes=['VM disks', 'generation source trees', 'candidate archive bytes', 'effect blobs'],
                    count=len(records), files=records)
    evidence.write_new(DEST / 'manifest.json', json.dumps(manifest, indent=2).encode() + b'\n')
    for row in records:
        if evidence.digest(DEST / row['path']) != row['sha256']:
            raise ValueError('Final archive digest differs')
    print(json.dumps(dict(manifest=str(DEST / 'manifest.json'), files=len(records), allDigestsVerified=True)))


if __name__ == '__main__':
    main()
