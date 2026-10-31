#!/usr/bin/env python3
"""Archive the completed isolated attempt without changing its source evidence."""
import json
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts'))
import cfw_guest_evidence as evidence

WORK = ROOT / '.build/t32-t33-completion-20261023'
DEST = ROOT / 'research/upstream_integration_2026-10-15/evidence/T32-T33-completion-20261023/fresh-offline'


def main():
    result = json.loads(evidence.read(WORK / 'fresh-offline-acceptance/result.json'))
    if DEST.exists():
        raise ValueError('Preserve the existing archive')
    if result.get('VMStarted') is not False or result.get('securityWindowStarted') is not False:
        raise ValueError('Unexpected execution scope')
    passed = result.get('state') == 'fresh-offline-on-off-on-passed'
    if passed and [row['name'] for row in result['phases']] != ['on', 'off', 'reapplied']:
        raise ValueError('Incomplete success evidence')
    names = ['fresh-file-acceptance-plan.json', 'fresh-file-acceptance-approval.json',
             'human-fresh-offline-approval.json', 'fresh-archive-sources.json',
             'fresh-root-execution.log', 'fresh-auth-result.log', 'candidate-r5.json',
             'fresh-progress-observations.jsonl']
    paths = [WORK / name for name in names]
    paths.extend((WORK / 'fresh-offline-acceptance').iterdir())
    for name in ('fresh-original-preservation.json', 'fresh-frozen-inputs-after-execution.json',
                 'fresh-failure-cleanup.json'):
        if (WORK / name).exists():
            paths.append(WORK / name)
    plan = json.loads(evidence.read(WORK / 'fresh-file-acceptance-plan.json'))
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
        'research/upstream_integration_2026-10-15/progress.md'))
    paths.extend(Path(__file__).parent / name for name in (
        'execute_t32_fresh_file_acceptance.py', 'prepare_t32_fresh_acceptance_plan.py',
        'test_t32_fresh_file_acceptance.py', 'archive_t32_fresh_acceptance.py'))
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
                    scope='Separately approved fresh-generation isolated three-Mach-O acceptance attempt',
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
