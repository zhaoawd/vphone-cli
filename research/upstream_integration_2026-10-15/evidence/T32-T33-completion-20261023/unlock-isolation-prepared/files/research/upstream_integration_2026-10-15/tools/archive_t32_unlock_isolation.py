#!/usr/bin/env python3
"""Archive unexecuted observer correction and the separately prepared plan."""
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[3]
BASE = ROOT / '.build/t32-t33-completion-20261023'
RESEARCH = ROOT / 'research/upstream_integration_2026-10-15'
DEST = RESEARCH / 'evidence/T32-T33-completion-20261023/unlock-isolation-prepared'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if DEST.exists():
        raise ValueError('Preserve existing evidence')
    plan_path = BASE / 'display-runtime/runtime-plan.json'
    expected = '2f85665429b501a7502f9941f1eef95ab8c9f5f19ede503d02b8d4576c5e4ee1'
    if sha(plan_path) != expected:
        raise ValueError('Prepared plan differs')
    plan = json.loads(plan_path.read_text())
    for path, digest in plan['frozenTools'].items():
        if sha(Path(path)) != digest:
            raise ValueError('Frozen input differs: ' + path)
    # Compare archives with their own manifests, including the exact observer
    # executed before the correction. No older source or verdict is rewritten.
    archives = []
    for manifest_path in sorted((RESEARCH / 'evidence/T32-T33-completion-20261023').glob('*/manifest.json')):
        manifest = json.loads(manifest_path.read_text())
        for row in manifest['files']:
            path = manifest_path.parent / row['path']
            if sha(path) != row['sha256'] or path.stat().st_size != row['bytes']:
                raise ValueError('Preserved archive differs: ' + str(path))
        archives.append(dict(manifest=str(manifest_path.relative_to(ROOT)),
                             sha256=sha(manifest_path), files=len(manifest['files'])))
    inputs = [BASE / name for name in ['unlock-isolation-red.log', 'unlock-isolation-green.log',
        'runtime-observer-final.log', 'display-runtime-preparation.log']]
    inputs.extend(p for p in (BASE / 'display-runtime').rglob('*')
                  if p.is_file() and 'pre-runtime-backup' not in p.parts and '__pycache__' not in p.parts)
    inputs.extend(RESEARCH / 'tools' / name for name in ['observe_t32_runtime.py',
        'test_t32_unlock_isolation.py', 'test_t32_runtime_observation.py',
        'test_t32_runtime_preflight.py', 't32_runtime_preflight.py',
        'prepare_t32_display_runtime.py', 'verify_t32_completed_runtime.py',
        'archive_t32_short_runtime.py', 'archive_t32_unlock_isolation.py'])
    inputs.extend(RESEARCH / name for name in ['T32_T33_completion_20261023.md',
        'progress.md', 'local_reconciliation.md', 'tasks.json', 'local_reconciliation.json'])
    inputs.extend(ROOT / name for name in ['TASKS.md', 'research/0_binary_patch_comparison.md'])
    DEST.mkdir(parents=True)
    rows = []
    for source in sorted(set(inputs)):
        if source.is_symlink() or not source.is_file():
            raise ValueError('Invalid evidence source')
        target = DEST / 'files' / source.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        data = source.read_bytes()
        shutil.copy2(source, target)
        if target.read_bytes() != data:
            raise ValueError('Archive copy differs')
        rows.append(dict(path=str(target.relative_to(DEST)), origin=str(source.relative_to(ROOT)),
                         bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
    record = dict(schemaVersion=1, scope='Unlock failure isolation and unapproved display continuation',
        accepted=False, runtimeValidated=False, patchCausalityValidated=False,
        correctionExecutedInVM=False, observerAndSocketTests=8, unlockIsolationTests=3,
        redReproductionPreserved=True, preparedPlanSHA256=expected, frozenToolsVerified=len(plan['frozenTools']),
        VMStarts=0, securityWindows=0, approvalGranted=False, priorArchivesVerified=archives,
        count=len(rows), files=rows)
    path = DEST / 'manifest.json'
    path.write_text(json.dumps(record, indent=2) + '\n')
    print(json.dumps(dict(manifest=str(path), sha256=sha(path), files=len(rows),
                          priorArchives=len(archives), allDigestsVerified=True)))


if __name__ == '__main__':
    main()
