#!/usr/bin/env python3
"""Preserve the consumed short-path runtime and its exact executed inputs."""
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / '.build/t32-t33-completion-20261023/short-runtime'
DEST = ROOT / 'research/upstream_integration_2026-10-15/evidence/T32-T33-completion-20261023/short-runtime-outcome'


def main():
    if DEST.exists():
        raise ValueError('Preserve existing runtime archive')
    safety = json.loads((WORK / 'runtime-safety.json').read_text())
    preservation = json.loads((WORK / 'runtime-preservation.json').read_text())
    plan = json.loads((WORK / 'runtime-plan.json').read_text())
    if not safety['passed'] or not safety['normalShutdownVerified']:
        raise ValueError('Independent safety and normal shutdown evidence required')
    if preservation['frozenInputsVerified'] != len(plan['frozenTools']):
        raise ValueError('Frozen input verification incomplete')
    inputs = [p for p in WORK.rglob('*') if p.is_file() and '__pycache__' not in p.parts]
    inputs.extend(Path(p) for p in plan['frozenTools'] if '/tools/' in p)
    inputs.extend(ROOT / p for p in [
        'TASKS.md', 'research/0_binary_patch_comparison.md',
        'research/upstream_integration_2026-10-15/T32_T33_completion_20261023.md',
        'research/upstream_integration_2026-10-15/tasks.json',
        'research/upstream_integration_2026-10-15/local_reconciliation.json',
        'research/upstream_integration_2026-10-15/progress.md',
        'research/upstream_integration_2026-10-15/local_reconciliation.md',
        'research/upstream_integration_2026-10-15/tools/verify_t32_completed_runtime.py',
        'research/upstream_integration_2026-10-15/tools/archive_t32_short_runtime.py',
    ])
    for source in inputs:
        if source.is_symlink() or not source.is_file():
            raise ValueError('Invalid archive source: ' + str(source))
    # Executed observer and all frozen research tools must still match the plan.
    for source in inputs:
        expected = plan['frozenTools'].get(str(source))
        if expected and hashlib.sha256(source.read_bytes()).hexdigest() != expected:
            raise ValueError('Executed source changed before archival: ' + str(source))
    DEST.mkdir(parents=True)
    records = []
    for source in sorted(set(inputs)):
        target = DEST / 'files' / source.relative_to(ROOT)
        target.parent.mkdir(parents=True, exist_ok=True)
        data = source.read_bytes()
        shutil.copy2(source, target)
        digest = hashlib.sha256(data).hexdigest()
        if target.read_bytes() != data:
            raise ValueError('Archive copy differs')
        records.append(dict(path=str(target.relative_to(DEST)), origin=str(source.relative_to(ROOT)),
                            sha256=digest, bytes=len(data)))
    manifest = dict(schemaVersion=1, scope='Consumed short-path GUI diagnostic; unlock timeout and AA.gl EPERM',
                    accepted=False, runtimeValidated=False, patchCausalityValidated=False,
                    GUIAPIReady=True, normalShutdownVerified=True, cleanupPassed=True,
                    displayObserved=False, rawGigalockerSaved=False,
                    VMStarts=1, securityWindows=1, windowAttachments=1,
                    helperSeconds=safety['secondsToHelperExit'], frozenInputsVerified=len(plan['frozenTools']),
                    originalVMFilesFullReadback=preservation['originalVMFilesFullReadback'],
                    count=len(records), files=records)
    path = DEST / 'manifest.json'
    path.write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(dict(manifest=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                          files=len(records), allDigestsVerified=True)))


if __name__ == '__main__':
    main()
