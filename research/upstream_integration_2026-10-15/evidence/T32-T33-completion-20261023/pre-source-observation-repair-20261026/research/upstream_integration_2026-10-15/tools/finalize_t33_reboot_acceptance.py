"""Read back a stopped recovery worker; preserve its original first-on producer."""
import json
from pathlib import Path
import shutil

import execute_t33_reboot_acceptance as current
import finalize_t33_target_binding_acceptance as previous

base = current.base
OUT = current.ROOT / 'research/upstream_integration_2026-10-15/evidence/T32-T33-completion-20261023/reboot-recovery-outcome-20261026'


def validate_native(native):
    if (native.get('state') not in ('failed', 'offline-qualified-on-off-on-passed')
            or any(native.get(k) != 0 for k in ('VMStarts', 'securityWindows', 'repeatedFirstOn', 'repeatedUndoWrites'))
            or any(native.get(k) is not False for k in ('deletionPerformed', 'automaticRetry', 'automaticRollback'))
            or native.get('targetAttachments') != [] or 'preservationError' in native
            or native.get('baseline') != dict(files=10, fullReadbackPassed=True)):
        raise ValueError('Native recovery result or preservation incomplete')
    if native['state'] == 'offline-qualified-on-off-on-passed':
        if ('error' in native or native.get('preservation', {}).get('fullReadbackPassed') is not True
                or set(native.get('phaseTransactions', {})) != {'on', 'off', 'reapplied'}
                or native['phaseTransactions']['on'] != current.FIRST
                or native['phaseTransactions']['off'] != current.RECOVERY_ID
                or len(set(native['phaseTransactions'].values())) != 3):
            raise ValueError('Recovery success has incomplete or duplicate phases')


def verify_phases(plan, native):
    result = {}
    for phase in ('on', 'off', 'reapplied'):
        path = current.WORK / 'execution/exp' / (phase + '.json')
        if not path.exists(): continue
        report = current.read(path)
        if report['transactionID'] != native['phaseTransactions'].get(phase) or report['generationID'] != current.GENERATION:
            raise ValueError('Phase association changed')
        if phase == 'on':
            current.verify_first_on(plan, report)
            if base.evidence.digest(path) != plan['firstOnReportSHA256']:
                raise ValueError('Copied first-on report changed')
        else:
            audit = report['independentAudit']; receipt = report['sourceReceipt']
            if (audit.get('passed') is not True or audit.get('originQualified') is not False
                    or audit.get('runtimeValidated') is not False
                    or audit.get('transactionID') != report['transactionID'] or audit.get('generationID') != current.GENERATION
                    or audit.get('currentImageSHA256') != receipt.get('currentImageSHA256')):
                raise ValueError('Actual independent installed-target audit required')
            base.verify_origin(plan, plan['targets'][0], phase, receipt, report['binding'])
        result[phase] = report
    if native['state'] == 'offline-qualified-on-off-on-passed':
        if set(result) != {'on', 'off', 'reapplied'}: raise ValueError('Complete recovery transition required')
        original = current.read(current.WORK / 'execution/exp/originals.json')
        catalog = current.read(current.VM / '.cfw-history' / current.FIRST / 'guest-file-originals.json')
        if original != {name: catalog['members'][name] for name in plan['targets'][0]['targets']}:
            raise ValueError('Restored original proof differs from the frozen first-on catalog')
        transition = base.transition(result['on']['targets'], result['off']['targets'], result['reapplied']['targets'],
            original, plan['targets'][0]['targets'])
        if transition != current.read(current.WORK / 'execution/exp/transition.json') or transition != native.get('transition'):
            raise ValueError('Exact transition changed')
    return result


def finalize():
    if OUT.exists() or (current.WORK / 'finalization.json').exists(): raise ValueError('Preserve existing finalization')
    plan = current.validate(current.read(current.WORK / 'offline-plan.json'))
    digest = base.evidence.digest(current.WORK / 'offline-plan.json'); current.configure(digest)
    base.approved(digest); base.verify_inputs(plan); base.verify_execution_inputs()
    if previous.root_running(current.read(current.WORK / 'native-root-identity.json')):
        raise ValueError('Original recovery worker still running')
    native = current.read(current.WORK / 'execution/result.json'); validate_native(native)
    reports = verify_phases(plan, native)
    current.retained.previous.unrelated(plan)
    if base.target_attachments(plan): raise ValueError('Recovery image remains attached')
    source = base.baseline(plan)
    for row in plan['protectedHostInputs'].values():
        if current.retained.snapshot(Path(row['backup'])) != row['backupState']:
            raise ValueError('Complete preserved host marker carrier changed')
    OUT.mkdir()
    for path in current.WORK.rglob('*'):
        if path.is_file() and path.suffix in ('.json', '.log'):
            destination = OUT / 'native' / path.relative_to(current.WORK)
            destination.parent.mkdir(parents=True, exist_ok=True); shutil.copyfile(path, destination)
            if base.evidence.digest(destination) != base.evidence.digest(path): raise ValueError('Outcome archive differs')
    result = dict(state='finalized', planSHA256=digest, accepted=False, runtimeValidated=False,
        nativeState=native['state'], offlineAcceptancePassed=native['state'] == 'offline-qualified-on-off-on-passed',
        VMStarts=0, securityWindows=0, phaseTransactions={name: row['transactionID'] for name, row in reports.items()},
        originalFirstOnProducer='2.6.2-local.f43043c4c559', reapplicationProducer=plan['candidate']['version'],
        repeatedFirstOn=0, repeatedUndoWrites=0, preservedSourceTransaction=current.INTERRUPTED,
        preservation=dict(sourceBackup=source, frozenInputs=len(plan['frozenInputs']),
            executionInputs=len(current.read(current.WORK / 'executor-inputs.json')['files']),
            rootBackupEvidence=native.get('preservation'),
            limitation='private complete backup and preserved partial transaction were reread by root; finalizer verifies public evidence'),
        error=native.get('error'))
    base.save(OUT / 'outcome.json', result)
    rows = [dict(path=str(p.relative_to(OUT)), sha256=base.evidence.digest(p), bytes=p.stat().st_size)
            for p in sorted(OUT.rglob('*')) if p.is_file()]
    base.save(OUT / 'manifest.json', dict(schemaVersion=1, files=rows, accepted=False))
    for row in rows:
        if base.evidence.digest(OUT / row['path']) != row['sha256']: raise ValueError('Archived outcome readback differs')
    result['manifestSHA256'] = base.evidence.digest(OUT / 'manifest.json')
    base.save(current.WORK / 'finalization.json', result)
    return result


if __name__ == '__main__':
    print(json.dumps(finalize()), flush=True)
