"""Prepare a named continuation only after successful native readonly inspection."""
import copy
import json
import os
from pathlib import Path

import execute_t33_dev_overlay_acceptance as runner
import retire_t33_dev_overlay_states as retirement

base = runner.base


def inspection_record(value):
    if (value.get('passed') is not True or value.get('diskIdentityPreserved') is not True
            or value.get('fullDiskMatchesOriginalSource') is not True
            or value.get('readonlyPlanVerificationPassed') is not True
            or value.get('generationID') != runner.GENERATION
            or value.get('deletionPerformed') is not False
            or any(value.get(k) != 0 for k in ('VMStarts', 'securityWindows', 'CFWWrites'))
            or 'error' in value):
        raise ValueError('Successful complete native readonly inspection required')
    return value


def main():
    checked = inspection_record(json.loads(base.evidence.read(runner.READONLY)))
    old_work = runner.BASE / 'exp-signing-acceptance-20261025-r2'
    old = json.loads(base.evidence.read(old_work / 'offline-plan.json'))
    final = json.loads(base.evidence.read(old_work / 'finalization.json'))
    if final['nativeState'] != 'failed' or final['preservation']['targetAttachments'] != []:
        raise ValueError('Previous attempt was not safely finalized')
    if checked['currentBootFiles']['Disk.img']['sha256'] != old['sourceBootFiles']['Disk.img']['sha256']:
        raise ValueError('Readonly disk proof differs from original source')
    candidate_path = runner.BASE / 'candidate-exp-dev-overlay-20261025-r2.json'
    candidate = json.loads(base.evidence.read(candidate_path))
    target = dict(vm=str(runner.VM), mode='reuse-unpublished-exp-generation', variant='exp',
        generationID=runner.GENERATION, targets=list(runner.previous.TARGETS),
        declarations=['system-systemversion-cfw-build_version'], beforeWriteBackup=str(runner.BACKUP),
        currentBootFiles=checked['currentBootFiles'], expectedBinding=checked['expectedBinding'],
        scratchTrees=checked['scratchTrees'], priorFailedTransactions=checked['priorFailedTransactions'])
    target.update(runner.commands(target['currentBootFiles']['launchpad.json']['sha256']))
    target['historyRecords'] = runner.history(target)
    plan = {k: copy.deepcopy(old[k]) for k in ('sourceBackup', 'sourceBootFiles', 'pythonRuntime',
        'minimumInitialFreeBytes', 'minimumEachCFWFreeBytes', 'expectedPrebootTarget',
        'unexpectedPrebootPolicy', 'signatureAcceptance', 'unrelatedDiskIdentities')}
    # t33t is now the selected write target, never an unrelated preserved disk.
    plan['unrelatedDiskIdentities'].pop(str((runner.VM / 'Disk.img').relative_to(runner.ROOT)), None)
    inputs = dict(old['frozenInputs'])
    # Old candidates/reports remain pinned evidence; add the final repaired package.
    paths = [runner.READONLY, candidate_path, Path(candidate['archive']), Path(__file__),
             Path(runner.__file__), old_work / 'finalization.json']
    paths += [p for p in Path(candidate['bundle']).rglob('*') if p.is_file()]
    for path in paths:
        path = path.resolve(strict=True)
        inputs[str(path)] = base.evidence.digest(path)
    plan.update(schemaVersion=1, scope='single unpublished EXP generation dev-overlay continuation',
        candidate=candidate, targets=[target], frozenInputs=inputs, reuseLockedPythonRuntime=True,
        VMStarts=0, normalGUIBoots=0, securityWindows=0, automaticRetry=False, automaticRollback=False,
        additionalDeletionAllowed=False, regularCFWRepeated=False, runtimeValidated=False,
        priorFailedPlanSHA256=base.evidence.digest(old_work / 'offline-plan.json'),
        readonlyInspectionSHA256=base.evidence.digest(runner.READONLY),
        runtimeProbeCommand=[str(Path(plan['pythonRuntime']['venv']) / 'bin/python3'),
            str(Path(candidate['bundle']) / 'Contents/Resources/scripts/check_python_runtime.py'), '--locked', '--json'],
        preserve=['all existing VMs, disks, backups and failed history',
                  'complete pre-write boot, binding and desired-plan backup',
                  'three existing rebuildable cache trees moved to the named backup without deletion'],
        cleanup=['formal normal-unmount cleanup of new transaction mounts only'],
        authorization='not approved; four named old-state retirements, new Store installation, rebinding and this single CFW sequence require confirmation')
    retirement.configure()
    sizes = {row['path']:row['allocatedBytes'] for row in checked['retirementCandidates']}
    rows = []
    removed = {}
    for name in retirement.NAMES:
        path = runner.ROOT / name
        row = dict(path=name, rootIdentity={k:v for k,v in retirement.storage.metadata(path).items()
            if k in ('dev','ino','mode','uid','gid')}, diskMetadata=retirement.storage.metadata(path/'Disk.img'),
            allocatedBytes=sizes[str(path)], failedTransactionRecords={})
        if (path/'.cfw-history').exists():
            for record in (path/'.cfw-history').glob('*/transaction.json'):
                if json.loads(base.evidence.read(record))['status'] != 'failed':
                    raise ValueError('Retirement candidate has a non-failed transaction')
                row['failedTransactionRecords'][str(record.relative_to(path))] = runner.snapshot(record)
        disk = str((path/'Disk.img').relative_to(runner.ROOT))
        if disk in plan['unrelatedDiskIdentities']:
            removed[disk] = plan['unrelatedDiskIdentities'].pop(disk)
        rows.append(row)
    plan['retirement'] = dict(retirementTargets=rows, removedPreservedDiskIdentities=removed,
        requiresExplicitDeletionApproval=True, fullDiskBackup=False,
        preservedArchivePolicy='complete inventory plus small experiment records, not restorable VM backups')
    plan['preserve'][0] = 'all existing VMs, disks, backups and failed history except the four explicit retirement roots'
    retirement.validate_scope(plan)
    runner.validate(plan)
    for path in (runner.WORK, runner.BACKUP, runner.CLI.parents[3]):
        if os.path.lexists(path):
            raise ValueError('Preserve existing output or Store: ' + str(path))
    base.verify_inputs(plan); runner.previous.unrelated(plan)
    info = os.statvfs(runner.ROOT)
    plan['observedAvailableBytes'] = info.f_bavail * info.f_frsize
    plan['initialCapacityPassed'] = plan['observedAvailableBytes'] >= plan['minimumInitialFreeBytes']
    runner.WORK.mkdir()
    base.save(runner.WORK / 'offline-plan.json', plan)
    print(json.dumps(dict(state='prepared-not-approved', planSHA256=base.evidence.digest(runner.WORK / 'offline-plan.json'),
        frozenInputs=len(inputs), capacityPassed=plan['initialCapacityPassed'],
        availableBytes=plan['observedAvailableBytes'], VMStarts=0, securityWindows=0, deletionPerformed=False)))


if __name__ == '__main__':
    main()
