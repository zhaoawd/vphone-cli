"""Read and archive a stopped continuation; cannot retry it or accept runtime behavior."""
import json
from pathlib import Path
import shutil

import execute_t33_dev_overlay_acceptance as runner
import finalize_t33_target_binding_acceptance as checks
import retire_t33_dev_overlay_states as retirement

OUT = runner.ROOT / 'research/upstream_integration_2026-10-15/evidence/T32-T33-completion-20261023/dev-overlay-outcome-20261025'


def validate_native(native):
    if (native.get('state') not in ('failed', 'offline-qualified-on-off-on-passed')
            or any(native.get(key) != 0 for key in ('VMStarts', 'securityWindows'))
            or native.get('originalVMWritten') is not False or native.get('deletionPerformed') is not False
            or native.get('baseline') != dict(files=10, fullReadbackPassed=True)
            or native.get('targetAttachments') != [] or native.get('beforeWriteBackupVerified') is not True
            or 'preservationOrCleanupError' in native):
        raise ValueError('Native continuation lacks preservation/offline evidence')


def finalize():
    if OUT.exists() or (runner.WORK / 'finalization.json').exists():
        raise ValueError('Preserve existing finalization; no replay')
    plan = runner.validate(checks.read(runner.WORK / 'offline-plan.json'))
    digest = runner.base.evidence.digest(runner.WORK / 'offline-plan.json'); runner.configure(digest)
    retirement.validate_scope(plan); retirement.approval(digest)
    manifest = checks.read(runner.WORK / 'executor-inputs.json')
    runner.base.verify_execution_inputs(); runner.base.verify_inputs(plan); runner.previous.unrelated(plan)
    identity = checks.read(runner.WORK / 'native-root-identity.json')
    if checks.root_running(identity):
        raise ValueError('Original worker is still running; do not start another')
    retired = checks.read(runner.WORK / 'retirement/result.json')
    if (retired.get('state') != 'completed' or retired.get('planSHA256') != digest
            or retired.get('removed') != list(retirement.NAMES)
            or retired.get('sourceBaselineBefore') != dict(files=10, fullReadbackPassed=True)
            or retired.get('sourceBaselineAfter') != dict(files=10, fullReadbackPassed=True)):
        raise ValueError('Retirement incomplete; preserve partial result')
    if any((runner.ROOT / name).exists() for name in retirement.NAMES):
        raise ValueError('Retired state reappeared')
    pipeline = checks.read(runner.WORK / 'retirement/pipeline-result.json')
    reports = {}; native = None
    if pipeline.get('nativeStarted'):
        native = checks.read(runner.WORK / 'execution/result.json'); validate_native(native)
        checks.WORK = runner.WORK
        reports = checks.phases(plan, native)
        if any(row['generationID'] != runner.GENERATION for row in reports.values()):
            raise ValueError('Continuation used another generation')
    elif pipeline.get('state') != 'awaiting-capacity':
        raise ValueError('Unexpected pipeline state')
    if runner.base.target_attachments(plan):
        raise ValueError('Target still attached; no forced cleanup')
    source = runner.base.baseline(plan)
    OUT.mkdir()
    paths = [p for p in runner.WORK.rglob('*') if p.is_file() and p.suffix in ('.json', '.log')]
    for path in paths:
        target = OUT / 'native' / path.relative_to(runner.WORK)
        target.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(path, target)
        if runner.base.evidence.digest(path) != runner.base.evidence.digest(target):
            raise ValueError('Archived public record differs')
    result = dict(state='finalized', planSHA256=digest, accepted=False, runtimeValidated=False,
        VMStarts=0, securityWindows=0, retiredPaths=list(retirement.NAMES),
        nativeState=native['state'] if native else 'not-started-capacity',
        offlineAcceptancePassed=bool(native and native['state']=='offline-qualified-on-off-on-passed'),
        phaseTransactions={phase:row['transactionID'] for phase,row in reports.items()},
        preservation=dict(sourceBackup=source, frozenInputs=len(plan['frozenInputs']),
            executionInputs=len(manifest['files']), retainedDiskIdentities=len(plan['unrelatedDiskIdentities']),
            privateBackupLimit='root executor verified complete 12-file backup and three cache trees; this finalizer reads public evidence'),
        error=native.get('error') if native else None)
    runner.base.save(OUT/'outcome.json', result)
    files = [dict(path=str(p.relative_to(OUT)), bytes=p.stat().st_size, sha256=runner.base.evidence.digest(p))
             for p in sorted(OUT.rglob('*')) if p.is_file()]
    runner.base.save(OUT/'manifest.json', dict(schemaVersion=1, files=files, accepted=False))
    for row in files:
        if runner.base.evidence.digest(OUT/row['path']) != row['sha256']:
            raise ValueError('Final evidence archive readback differs')
    result['manifestSHA256'] = runner.base.evidence.digest(OUT/'manifest.json')
    runner.base.save(runner.WORK/'finalization.json', result)
    return result


if __name__ == '__main__':
    print(json.dumps(finalize()), flush=True)
