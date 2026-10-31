"""Independently verify a stopped offline worker and archive its public evidence."""
import json
from pathlib import Path
import shutil

import execute_t33_plist_lifetime_acceptance as current
import finalize_t33_target_binding_acceptance as checks
from finalize_t33_dev_overlay_acceptance import validate_native

OUT = current.runner.ROOT / 'research/upstream_integration_2026-10-15/evidence/T32-T33-completion-20261023/plist-lifetime-outcome-20261025'


def finalize():
    runner = current.runner
    if OUT.exists() or (current.WORK / 'finalization.json').exists():
        raise ValueError('Preserve existing finalization')
    plan = current.validate(checks.read(current.WORK / 'offline-plan.json'))
    digest = runner.base.evidence.digest(current.WORK / 'offline-plan.json')
    runner.configure(digest)
    runner.base.approved(digest)
    runner.base.verify_execution_inputs(); runner.base.verify_inputs(plan)
    runner.previous.unrelated(plan)
    if checks.root_running(checks.read(current.WORK / 'native-root-identity.json')):
        raise ValueError('Original worker still running; no finalization or retry')
    native = checks.read(current.WORK / 'execution/result.json')
    validate_native(native)
    current.verify_host_inputs(plan, current_inputs=False)
    host = checks.read(current.WORK / 'host-input-backup-verification.json')
    if host != dict(passed=True, files=1, planSHA256=digest, scope='complete preserved host marker bytes and original metadata record'):
        raise ValueError('Complete host marker backup verification required')
    checks.WORK = current.WORK
    reports = checks.phases(plan, native)
    if any(row['generationID'] != runner.GENERATION for row in reports.values()):
        raise ValueError('Continuation generation changed')
    if runner.base.target_attachments(plan):
        raise ValueError('Target still attached; no forced cleanup')
    source = runner.base.baseline(plan)
    OUT.mkdir()
    for path in current.WORK.rglob('*'):
        if path.is_file() and path.suffix in ('.json', '.log'):
            target = OUT / 'native' / path.relative_to(current.WORK)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
            if runner.base.evidence.digest(path) != runner.base.evidence.digest(target):
                raise ValueError('Public evidence archive differs')
    manifest = checks.read(current.WORK / 'executor-inputs.json')
    result = dict(state='finalized', planSHA256=digest, accepted=False, runtimeValidated=False,
        VMStarts=0, securityWindows=0, deletionPerformed=False, nativeState=native['state'],
        offlineAcceptancePassed=native['state'] == 'offline-qualified-on-off-on-passed',
        phaseTransactions={phase: row['transactionID'] for phase, row in reports.items()},
        preservation=dict(sourceBackup=source, frozenInputs=len(plan['frozenInputs']),
            executionInputs=len(manifest['files']), retainedDiskIdentities=len(plan['unrelatedDiskIdentities']),
            protectedHostInputBackups=1, privateBackupLimit='root executor fully verified fresh 12-file backup, moved caches and prior failure records; finalizer reads public evidence'),
        error=native.get('error'))
    runner.base.save(OUT / 'outcome.json', result)
    files = [dict(path=str(p.relative_to(OUT)), bytes=p.stat().st_size, sha256=runner.base.evidence.digest(p))
             for p in sorted(OUT.rglob('*')) if p.is_file()]
    runner.base.save(OUT / 'manifest.json', dict(schemaVersion=1, files=files, accepted=False))
    for row in files:
        if runner.base.evidence.digest(OUT / row['path']) != row['sha256']:
            raise ValueError('Final archive readback differs')
    result['manifestSHA256'] = runner.base.evidence.digest(OUT / 'manifest.json')
    runner.base.save(current.WORK / 'finalization.json', result)
    return result


if __name__ == '__main__':
    print(json.dumps(finalize()), flush=True)
