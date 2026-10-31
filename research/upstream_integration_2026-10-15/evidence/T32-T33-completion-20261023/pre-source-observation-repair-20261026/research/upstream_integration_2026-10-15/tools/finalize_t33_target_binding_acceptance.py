"""Observe the existing root worker and archive its result without retrying it."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

import execute_t33_target_binding_acceptance as runner

ROOT = runner.ROOT
WORK = runner.WORK
CLEANUP = ROOT / 'research/evidence/t32-t33-retirement-20261025'
OUT = ROOT / 'research/upstream_integration_2026-10-15/evidence/T32-T33-completion-20261023/target-binding-outcome-20261025'
PLAN = 'dd2799d50f0a3fbaa0edfe9af16e247f0c8b6cd8b9ea76e64ed99a8211b5a5bc'
OLD = 'b3b98f370e384a3659dea2428651cb033566e01a8641897651038a3701f8805b'


def read(path):
    return json.loads(runner.base.evidence.read(path))


def root_running(identity):
    result = subprocess.run(['/bin/ps', '-p', str(identity['pid']), '-o', 'uid=,lstart='],
        capture_output=True, text=True, env=dict(os.environ, LC_ALL='C'))
    if result.returncode == 1 and not result.stdout.strip() and not result.stderr.strip():
        return False
    if result.returncode != 0 or result.stderr.strip() or result.stdout.strip() != identity['uidAndStart']:
        raise ValueError('Root worker identity changed or could not be read; do not restart it')
    return True


def validate_cleanup(cleanup, plan):
    if (cleanup.get('state') != 'completed' or cleanup.get('amendedPlanSHA256') != PLAN
            or cleanup.get('removed') != plan['retirementAmendment']['authorizedRetirementPaths']
            or cleanup.get('sourceBaselineBefore') != dict(files=10, fullReadbackPassed=True)
            or cleanup.get('sourceBaselineAfter') != dict(files=10, fullReadbackPassed=True)
            or any(cleanup.get(key) != 0 for key in ('VMStarts', 'CFWWrites', 'securityWindows'))):
        raise ValueError('Cleanup did not complete its approved scope and preservation checks')


def phases(plan, native):
    target = plan['targets'][0]
    result = {}
    for phase in ('on', 'off', 'reapplied'):
        path = WORK / 'execution/exp' / (phase + '.json')
        if not path.exists():
            continue
        row = read(path)
        runner.base.verify_origin(plan, target, phase, row['sourceReceipt'], row['binding'])
        audit = row['independentAudit']
        if (audit['passed'] is not True or row['generationID'] != audit['generationID']
                or row['transactionID'] != audit['transactionID']
                or set(row['targets']) != set(target['targets'])):
            raise ValueError('Saved phase lacks complete target audit evidence')
        result[phase] = row
    if native['state'] == 'offline-qualified-on-off-on-passed':
        if set(result) != {'on', 'off', 'reapplied'}:
            raise ValueError('Native success lacks all three phase reports')
        if len({row['generationID'] for row in result.values()}) != 1:
            raise ValueError('Generation changed between phases')
        if result['on']['targets'] != result['reapplied']['targets']:
            raise ValueError('Reapplication differs from complete first-on state')
        transition = read(WORK / 'execution/exp/transition.json')
        if (transition.get('passed') is not True or transition.get('runtimeValidated') is not False
                or transition.get('scope') != 'complete file bytes and mode/uid/gid'
                or set(transition.get('targets', [])) != set(target['targets'])):
            raise ValueError('Missing strict transition report')
    return result


def preserve(plan, native):
    runner.configure(PLAN)
    runner.base.approved(PLAN)
    runner.base.verify_inputs(plan); runner.base.verify_execution_inputs()
    runner.unrelated(plan)
    if runner.base.evidence.digest(WORK / 'offline-plan.json.before-retirement-20261025') != OLD:
        raise ValueError('Old approved plan was not preserved exactly')
    original = read(WORK / 'executor-inputs.json.before-retirement-20261025')
    active = read(WORK / 'executor-inputs.json')
    if original['files'] != active['files'] or original['planSHA256'] != OLD or active['planSHA256'] != PLAN:
        raise ValueError('Amendment changed frozen execution files')
    for name, expected in read(CLEANUP / 'cleanup-inputs.json')['files'].items():
        path = Path(name)
        if path.parent == WORK and path.name in ('offline-plan.json', 'approval.json', 'executor-inputs.json'):
            path = path.with_name(path.name + '.before-retirement-20261025')
        if runner.base.evidence.digest(path) != expected:
            raise ValueError('Cleanup input or preserved original changed: ' + str(path))
    for name in plan['retirementAmendment']['authorizedRetirementPaths']:
        if os.path.lexists(ROOT / name):
            raise ValueError('Retired target remains or reappeared')
    if native is not None:
        if (native.get('VMStarts') != 0 or native.get('securityWindows') != 0
                or native.get('originalVMWritten') is not False
                or native.get('baseline') != dict(files=10, fullReadbackPassed=True)
                or native.get('targetAttachments') != [] or 'preservationOrCleanupError' in native):
            raise ValueError('Native preservation/offline scope failed')
    if runner.base.target_attachments(plan):
        raise ValueError('Target image attachment remains')
    source = runner.base.baseline(plan)
    return dict(sourceBackup=source, frozenInputsVerified=len(plan['frozenInputs']),
        executionInputsVerified=len(active['files']), preservedDiskIdentitiesVerified=len(plan['unrelatedDiskIdentities']),
        retiredTargetsAbsent=4, targetAttachments=[],
        privateArchiveLimit='Root worker read back the 0600 small-record archive; this user finalizer does not read that archive')


def archive(native, cleanup, pipeline, reports, preservation):
    OUT.mkdir()
    paths = [p for p in CLEANUP.iterdir() if p.is_file() and p.suffix in ('.json', '.log')]
    paths += [WORK / name for name in ('offline-plan.json', 'approval.json', 'executor-inputs.json',
        'offline-plan.json.before-retirement-20261025', 'approval.json.before-retirement-20261025',
        'executor-inputs.json.before-retirement-20261025', 'root-execution.log') if (WORK / name).is_file()]
    paths += [p for p in (WORK / 'execution').rglob('*') if p.is_file() and p.suffix in ('.json', '.log')]
    for path in paths:
        relative = path.relative_to(CLEANUP) if CLEANUP in path.parents else path.relative_to(WORK)
        destination = OUT / ('cleanup' if CLEANUP in path.parents else 'native') / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)
        if runner.base.evidence.digest(path) != runner.base.evidence.digest(destination):
            raise ValueError('Archived public evidence differs')
    result = dict(state='finalized', nativeState=native['state'] if native else 'not-started-capacity',
        cleanupState=cleanup['state'], pipeline=pipeline, offlineAcceptancePassed=bool(native and
            native['state'] == 'offline-qualified-on-off-on-passed'), accepted=False, runtimeValidated=False,
        VMStarts=0, securityWindows=0, planSHA256=PLAN, preservation=preservation,
        phaseTransactions={phase: row['transactionID'] for phase, row in reports.items()},
        error=native.get('error') if native else None)
    runner.base.save(OUT / 'outcome.json', result)
    files = [dict(path=str(p.relative_to(OUT)), bytes=p.stat().st_size, sha256=runner.base.evidence.digest(p))
             for p in sorted(OUT.rglob('*')) if p.is_file()]
    runner.base.save(OUT / 'manifest.json', dict(schemaVersion=1, accepted=False, files=files))
    result['manifestSHA256'] = runner.base.evidence.digest(OUT / 'manifest.json')
    runner.base.save(CLEANUP / 'finalization.json', result)
    return result


def main():
    source_sha = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    if OUT.exists() or (CLEANUP / 'finalization.json').exists():
        raise ValueError('Preserve existing finalization; no replay')
    identity = read(CLEANUP / 'native-root-identity.json')
    deadline = time.monotonic() + 86400
    while root_running(identity):
        if time.monotonic() >= deadline:
            raise ValueError('Read-only wait expired; native worker was not interrupted')
        time.sleep(30)
    if hashlib.sha256(Path(__file__).read_bytes()).hexdigest() != source_sha:
        raise ValueError('Read-only finalizer source changed while waiting')
    plan = runner.validate(read(WORK / 'offline-plan.json'))
    cleanup = read(CLEANUP / 'result.json'); validate_cleanup(cleanup, plan)
    pipeline = read(CLEANUP / 'pipeline-result.json')
    native = read(WORK / 'execution/result.json') if pipeline.get('nativeStarted') else None
    reports = phases(plan, native) if native else {}
    result = archive(native, cleanup, pipeline, reports, preserve(plan, native))
    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        runner.base.save(CLEANUP / 'finalization-stopped.json', dict(state='stopped', error=str(error), nativeRetried=False))
        raise
