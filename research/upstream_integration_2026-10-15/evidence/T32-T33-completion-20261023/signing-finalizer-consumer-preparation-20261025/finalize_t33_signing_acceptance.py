"""Wait for the named EXP worker, then verify and archive its public reports."""
import json
from pathlib import Path
import shutil
import time

import execute_t33_signing_acceptance as entry
import finalize_t33_target_binding_acceptance as checks

runner = entry.runner
ROOT = runner.ROOT
WORK = entry.WORK
PLAN = 'b2f587bee45825e50f997f289d2a08724eb42acf958ceb8673db0b6b02e627c9'
OUT = ROOT / 'research/upstream_integration_2026-10-15/evidence/T32-T33-completion-20261023/signing-outcome-20261025'


def configure():
    runner.WORK = WORK
    runner.VM = entry.VM
    runner.configure(PLAN)
    checks.WORK = WORK


def validate_native(native):
    if (native.get('state') not in ('failed', 'offline-qualified-on-off-on-passed')
            or any(native.get(key) != 0 for key in ('VMStarts', 'securityWindows'))
            or native.get('originalVMWritten') is not False
            or native.get('baseline') != dict(files=10, fullReadbackPassed=True)
            or native.get('targetAttachments') != []
            or 'preservationOrCleanupError' in native):
        raise ValueError('Native result lacks offline scope or preservation evidence')


def preserve(plan):
    runner.base.approved(PLAN)
    runner.base.verify_inputs(plan)
    runner.base.verify_execution_inputs()
    runner.unrelated(plan)
    if runner.base.target_attachments(plan):
        raise ValueError('Target disk is still attached; no forced cleanup')
    return dict(sourceBackup=runner.base.baseline(plan), frozenInputsVerified=len(plan['frozenInputs']),
        executionInputsVerified=len(checks.read(WORK / 'executor-inputs.json')['files']),
        preservedDiskIdentitiesVerified=len(plan['unrelatedDiskIdentities']), targetAttachments=[])


def finalize():
    configure()
    plan = runner.validate(checks.read(WORK / 'offline-plan.json'))
    native = checks.read(WORK / 'execution/result.json')
    validate_native(native)
    reports = checks.phases(plan, native)
    preservation = preserve(plan)
    OUT.mkdir()
    paths = [WORK / name for name in ('offline-plan.json', 'approval.json', 'user-approval-20261025.json',
        'executor-inputs.json', 'native-launch-request.json', 'native-root-identity.json', 'root-execution.log')]
    paths += [p for p in (WORK / 'execution').rglob('*') if p.is_file() and p.suffix in ('.json', '.log')]
    for path in paths:
        destination = OUT / 'native' / path.relative_to(WORK)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)
        if runner.base.evidence.digest(path) != runner.base.evidence.digest(destination):
            raise ValueError('Archived native report differs')
    result = dict(state='finalized', nativeState=native['state'], accepted=False, runtimeValidated=False,
        offlineAcceptancePassed=native['state'] == 'offline-qualified-on-off-on-passed',
        planSHA256=PLAN, VMStarts=0, securityWindows=0, preservation=preservation,
        phaseTransactions={phase: row['transactionID'] for phase, row in reports.items()}, error=native.get('error'))
    runner.base.save(OUT / 'outcome.json', result)
    files = [dict(path=str(p.relative_to(OUT)), sha256=runner.base.evidence.digest(p), bytes=p.stat().st_size)
             for p in sorted(OUT.rglob('*')) if p.is_file()]
    runner.base.save(OUT / 'manifest.json', dict(schemaVersion=1, files=files, accepted=False))
    for row in files:
        if runner.base.evidence.digest(OUT / row['path']) != row['sha256']:
            raise ValueError('Final archive readback differs')
    result['manifestSHA256'] = runner.base.evidence.digest(OUT / 'manifest.json')
    runner.base.save(WORK / 'finalization.json', result)
    return result


def main():
    if OUT.exists() or (WORK / 'finalization.json').exists():
        raise ValueError('Preserve existing finalization; no replay')
    identity = checks.read(WORK / 'native-root-identity.json')
    inputs = checks.read(WORK / 'finalizer-inputs.json')['files']
    for name, expected in inputs.items():
        if runner.base.evidence.digest(Path(name)) != expected:
            raise ValueError('Finalizer input changed before wait: ' + name)
    deadline = time.monotonic() + 86400
    while checks.root_running(identity):
        if time.monotonic() >= deadline:
            raise ValueError('Read-only wait expired; native worker was not interrupted')
        time.sleep(30)
    for name, expected in inputs.items():
        if runner.base.evidence.digest(Path(name)) != expected:
            raise ValueError('Finalizer input changed while waiting: ' + name)
    print(json.dumps(finalize()), flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        runner.base.save(WORK / 'finalization-stopped.json',
            dict(state='stopped', error=str(error), nativeRetried=False))
        raise
