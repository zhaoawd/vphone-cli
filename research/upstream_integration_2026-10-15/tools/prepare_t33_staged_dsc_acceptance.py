"""Freeze a new plan after finalized failure and real-resource preflight.

The private desired-plan hash is inherited from the verified native record;
its identity is checked here, and complete rereading is mandatory at root
preflight before any backup, Store installation or rebinding.
"""
import copy
import json
import os
from pathlib import Path
import stat

import execute_t33_staged_dsc_acceptance as current

runner = current.runner
base = runner.base


def inherited_private(path, expected):
    info = path.lstat()
    actual = dict(bytes=info.st_size, dev=info.st_dev, ino=info.st_ino,
        mtime_ns=info.st_mtime_ns, mode=stat.S_IMODE(info.st_mode), uid=info.st_uid, gid=info.st_gid)
    if info.st_nlink != 1 or not stat.S_ISREG(info.st_mode) or any(expected[k] != v for k, v in actual.items()):
        raise ValueError('Private input identity differs from verified native proof')
    return dict(expected)


def main():
    current.configure()
    old_work = runner.BASE / 'exp-dev-overlay-acceptance-20261025'
    old = json.loads(base.evidence.read(old_work / 'offline-plan.json'))
    final = json.loads(base.evidence.read(old_work / 'finalization.json'))
    if final['nativeState'] != 'failed' or final['phaseTransactions']:
        raise ValueError('Previous attempt did not stop before publication')
    native = json.loads(base.evidence.read(old_work / 'execution/result.json'))
    if (native.get('beforeWriteBackupVerified') is not True or native.get('targetAttachments') != []
            or 'preservationOrCleanupError' in native):
        raise ValueError('Previous native preservation incomplete')
    preflight_path = runner.BASE / 'staged-dsc-real-resource-20261025/result.json'
    preflight = json.loads(base.evidence.read(preflight_path))
    if (preflight.get('passed') is not True or preflight.get('realResources') is not True
            or preflight.get('normallyDetached') is not True
            or any(preflight.get(k) is not True for k in
                ('sourceClonePreserved', 'sourceIdentityPreserved', 'sourceSHA256Preserved'))):
        raise ValueError('Real-resource preflight incomplete')
    candidate_path = runner.BASE / 'candidate-exp-staged-dsc-20261025.json'
    candidate = json.loads(base.evidence.read(candidate_path))
    target = copy.deepcopy(old['targets'][0])
    target['beforeWriteBackup'] = str(current.BACKUP)
    print('Reading current boot files including complete Disk.img', flush=True)
    with base.audit.locked_vm(runner.VM):
        base.txn.require_unheld(runner.VM / 'Disk.img', os.getpid(), 'staged DSC preparation')
        target['currentBootFiles'] = {name: runner.snapshot(runner.VM / name)
            for name in old['sourceBootFiles'] | {'launchpad.json': {}}}
        target['currentBootFiles']['.firmware-desired-plan.json'] = inherited_private(
            runner.VM / '.firmware-desired-plan.json', old['targets'][0]['currentBootFiles']['.firmware-desired-plan.json'])
        if target['currentBootFiles']['Disk.img']['sha256'] != old['sourceBootFiles']['Disk.img']['sha256']:
            raise ValueError('Current complete disk differs from retained source')
        target['expectedBinding'] = json.loads(base.evidence.read(runner.VM / 'launchpad.json'))
        if (target['expectedBinding'] != dict(old['targets'][0]['expectedBinding'], bundle=old['candidate']['version'])):
            raise ValueError('Current binding differs from native finalization')
        target['priorFailedTransactions'] = ['20261025T021021Z-hnTJT23g', '20261025T043518Z-1urmPFY7']
        target['historyRecords'] = runner.history(target)
        if base.txn.committed_guest_evidence(runner.VM) is not None:
            raise ValueError('Published guest cannot use this continuation')
        target['scratchTrees'] = {name: base.effects.state(runner.VM / name)
            for name in runner.SCRATCH if (runner.VM / name).exists()}
    target.update(runner.commands(target['currentBootFiles']['launchpad.json']['sha256']))
    plan = {k: copy.deepcopy(old[k]) for k in ('sourceBackup', 'sourceBootFiles', 'pythonRuntime',
        'minimumInitialFreeBytes', 'minimumEachCFWFreeBytes', 'expectedPrebootTarget',
        'unexpectedPrebootPolicy', 'signatureAcceptance', 'unrelatedDiskIdentities')}
    paths = [Path(p) for p in old['frozenInputs']]
    paths += [candidate_path, Path(candidate['archive']), Path(__file__), Path(current.__file__),
              old_work / 'finalization.json', preflight_path]
    paths += [p for p in Path(candidate['bundle']).rglob('*') if p.is_file()]
    # Each new plan freezes current files; prior frozen manifests remain historical records.
    inputs = {str(p.resolve(strict=True)): base.evidence.digest(p.resolve(strict=True)) for p in paths}
    plan.update(schemaVersion=1, scope='single unpublished EXP staged guest DSC continuation',
        candidate=candidate, targets=[target], frozenInputs=inputs, reuseLockedPythonRuntime=True,
        VMStarts=0, normalGUIBoots=0, securityWindows=0, automaticRetry=False, automaticRollback=False,
        additionalDeletionAllowed=False, regularCFWRepeated=False, runtimeValidated=False,
        priorFailedPlanSHA256=base.evidence.digest(old_work / 'offline-plan.json'),
        realResourcePreflightSHA256=base.evidence.digest(preflight_path),
        privateDesiredPlanEvidence='prior native full readback plus unchanged lstat; mandatory fresh root full readback before writes',
        runtimeProbeCommand=[str(Path(plan['pythonRuntime']['venv']) / 'bin/python3'),
            str(Path(candidate['bundle']) / 'Contents/Resources/scripts/check_python_runtime.py'), '--locked', '--json'],
        preserve=['all remaining VMs, disks, backups and failed records',
                  'fresh complete 12-file boot, binding and desired-plan backup',
                  'existing rebuildable caches moved into this new backup without deletion'],
        retiredEvidenceLimit='old hnTJT23g effect-blobs and old DSC CFW history already retired under cleanup 96cd7a4f; no complete replay claim',
        cleanup=['normal unmount of this new transaction only'],
        authorization='not approved; new Store installation, binding and this one offline CFW sequence require confirmation')
    current.validate(plan)
    for path in (current.WORK, current.BACKUP, runner.CLI.parents[3]):
        if os.path.lexists(path):
            raise ValueError('Preserve existing output or Store')
    print('Verifying retained source, frozen inputs and unrelated disk identities', flush=True)
    base.baseline(plan); base.verify_inputs(plan); runner.previous.unrelated(plan)
    info = os.statvfs(runner.ROOT)
    plan['observedAvailableBytes'] = info.f_bavail * info.f_frsize
    plan['initialCapacityPassed'] = plan['observedAvailableBytes'] >= plan['minimumInitialFreeBytes']
    current.WORK.mkdir()
    base.save(current.WORK / 'offline-plan.json', plan)
    print(json.dumps(dict(state='prepared-not-approved', planSHA256=base.evidence.digest(current.WORK / 'offline-plan.json'),
        frozenInputs=len(inputs), capacityPassed=plan['initialCapacityPassed'], availableBytes=plan['observedAvailableBytes'])))


if __name__ == '__main__':
    main()
