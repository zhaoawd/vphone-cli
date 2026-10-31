"""Freeze a new continuation without replacing the prior registration or backups."""
import copy
import json
import os
from pathlib import Path
import shutil
import stat

import execute_t33_source_acceptance as current

base = current.base
PREFLIGHT = current.BASE / 'source-identity-packaged-preflight-20261026'


def metadata_unchanged(path, expected):
    info = path.lstat()
    actual = dict(bytes=info.st_size, dev=info.st_dev, ino=info.st_ino, mtime_ns=info.st_mtime_ns,
        mode=stat.S_IMODE(info.st_mode), uid=info.st_uid, gid=info.st_gid)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or any(actual[k] != expected[k] for k in actual):
        raise ValueError('Input changed after native complete preflight: ' + str(path))


def main():
    old = current.read(current.previous.WORK / 'offline-plan.json')
    if base.evidence.digest(current.previous.WORK / 'offline-plan.json') != current.PRIOR_SHA:
        raise ValueError('Prior failed plan changed')
    final = current.read(current.previous.WORK / 'finalization.json')
    if final['nativeState'] != 'failed' or final['offlineAcceptancePassed'] is not False:
        raise ValueError('Prior stopped execution has not been independently finalized')
    replay = current.read(PREFLIGHT / 'result.json')
    if (any(replay.get(k) is not True for k in ('passed', 'completeFourImageReadbacksPassed',
            'completeParentPublicationPassed', 'productionCompleteUndoPreviewPassed',
            'rebuiltIndexByteIdentical', 'preservedUndoSourceVerified'))
            or any(replay.get(k) != value for k, value in dict(sourceRegistrationInstalled=False,
                transactionWrites=0, VMStarts=0, accepted=False).items())):
        raise ValueError('Complete readonly packaged production preflight required')
    candidate = current.read(current.CANDIDATE)
    commands = current.previous.commands(candidate, replay['currentBootFiles']['launchpad.json']['sha256'])
    if any(os.path.lexists(p) for p in (current.WORK, current.BACKUP, current.EMPTY_DESTINATION,
            Path(commands['installedCLI']).parents[3], current.VM / '.cfw-reboot-source-identity.json')):
        raise ValueError('Existing preparation, Store or source registration; no replacement')
    boot = replay['currentBootFiles']; host = replay['currentHostFiles']
    for name, expected in (boot | host).items(): metadata_unchanged(current.VM / name, expected)
    binding = current.read(current.VM / 'launchpad.json')
    source_files = {name: current.retained.snapshot(Path(old['sourceBackup']) / name) for name in old['sourceBootFiles']}
    if source_files != old['sourceBootFiles']:
        raise ValueError('Retained original source backup changed')
    target = dict(vm=str(current.VM), mode='resume-after-source-observation-refusal', variant='exp',
        generationID=current.GENERATION, targets=current.retained.previous.TARGETS,
        declarations=['system-systemversion-cfw-build_version'], currentBootFiles=boot, expectedBinding=binding,
        failedHistoryRecords=old['targets'][0]['failedHistoryRecords'], scratchTrees=old['targets'][0]['scratchTrees'])
    plan = {k: copy.deepcopy(old[k]) for k in ('pythonRuntime', 'minimumInitialFreeBytes', 'minimumEachCFWFreeBytes',
        'expectedPrebootTarget', 'unexpectedPrebootPolicy', 'signatureAcceptance', 'unrelatedDiskIdentities')}
    plan.update(schemaVersion=1, scope='register two exact generation source observations; recover existing Undo result and reapply EXP once',
        candidate=candidate, targets=[target], sourceBackup=old['sourceBackup'], sourceBootFiles=source_files,
        priorFailedPlanSHA256=current.PRIOR_SHA, primaryRegistrationSHA256=current.PRIMARY_SHA,
        retainedBackup=str(current.previous.BACKUP), smallBackup=str(current.BACKUP), smallBackupFiles=host,
        sourceMembers=replay['sourceMembers'], volumeUUID=replay['volumeUUID'],
        packagedPreflightDirectory=str(PREFLIGHT), installedModuleSHA256=replay['candidateModulesSHA256'],
        emptyWork=replay['emptyFailedWork'], emptyWorkDestination=str(current.EMPTY_DESTINATION),
        recovery=current.previous.expected_recovery(),
        firstOnReportSHA256=base.evidence.digest(current.previous.OLD_WORK / 'execution/exp/on.json'),
        boundBeforeRecovery=dict(binding, bundle=candidate['version']), reuseLockedPythonRuntime=True,
        VMStarts=0, normalGUIBoots=0, securityWindows=0, repeatedFirstOn=0, repeatedUndoWrites=0,
        repeatedPrimaryRegistration=0, repeatedW7Move=0, automaticRetry=False, automaticRollback=False,
        additionalDeletionAllowed=False, regularCFWRepeated=False, runtimeValidated=False,
        currentBootEvidence='native complete packaged preflight plus unchanged metadata; mandatory fresh root full readback before writes',
        authorization='not approved; new Store installation, exact source registration and one remaining recovered Undo/reapply require confirmation',
        preserve=['reuse verified 12-file complete backup and both retained caches from prior execution',
            'fresh four-file small host backup including primary registry and original SSH ownership',
            'all 5343 retained W7 files and all four failed transaction records',
            'move the exact empty failed work directory to a new retained path without deletion'],
        preservedSourcePolicy='no W7 writer, no historical observation rewrite, no replacement of primary image registration',
        retiredEvidenceLimit='cleanup96cd retired old hnTJT23g effect-blobs and old DSC history; no complete replay claim')
    plan.update(commands)
    scripts = Path(candidate['bundle']) / 'Contents/Resources/scripts'
    plan['runtimeProbeCommand'] = [str(Path(plan['pythonRuntime']['venv']) / 'bin/python3'),
        str(scripts / 'check_python_runtime.py'), '--locked', '--json']
    paths = {Path(p) for p in old['frozenInputs']}
    paths |= {p for p in Path(candidate['bundle']).rglob('*') if p.is_file()}
    paths |= {p for p in PREFLIGHT.rglob('*') if p.is_file()}
    paths |= set(Path(__file__).parent.glob('*t33*source*.py'))
    paths |= {current.CANDIDATE, Path(candidate['archive']), current.previous.WORK / 'offline-plan.json',
        current.previous.WORK / 'finalization.json', current.previous.WORK / 'execution/preserved-source-before.json',
        current.previous.WORK / 'execution/result.json', current.VM / '.cfw-reboot-identity.json'}
    paths |= set((current.ROOT / 'scripts').glob('*.py')) | set((current.ROOT / 'scripts/patchers').glob('*.py'))
    paths |= {current.ROOT / name for name in ('tests/test_cfw_source_identity.py', 'tests/test_generation_source_reboot.py')}
    paths |= {current.BASE / name for name in ('source-identity-python-full-20261026.log',
        'source-identity-candidate-package-20261026.log', 'source-identity-continuation-tests-20261026.log')}
    inputs = {str(p.resolve(strict=True)): base.evidence.digest(p.resolve(strict=True)) for p in paths}
    current.WORK.mkdir(); carrier = current.WORK / 'host-input-backup'; carrier.mkdir(mode=0o700)
    shutil.copy2(current.VM / '.ssh_forward', carrier / '.ssh_forward')
    if current.retained.snapshot(current.VM / '.ssh_forward') != host['.ssh_forward']:
        raise ValueError('SSH marker changed during preparation')
    plan['protectedHostInputs'] = {'.ssh_forward': dict(current=host['.ssh_forward'], backup=str(carrier / '.ssh_forward'),
        backupState=current.retained.snapshot(carrier / '.ssh_forward'),
        ownershipPolicy='original uid/gid are recorded separately from the user-owned archive carrier')}
    inputs[str(carrier / '.ssh_forward')] = base.evidence.digest(carrier / '.ssh_forward')
    plan['frozenInputs'] = inputs
    info = os.statvfs(current.ROOT); plan['observedAvailableBytes'] = info.f_bavail * info.f_frsize
    plan['initialCapacityPassed'] = plan['observedAvailableBytes'] >= plan['minimumInitialFreeBytes']
    current.validate(plan); current.verify_first_on(plan, current.read(current.previous.OLD_WORK / 'execution/exp/on.json'))
    current.retained.previous.unrelated(plan); base.verify_inputs(plan)
    base.save(current.WORK / 'offline-plan.json', plan)
    print(json.dumps(dict(state='prepared-not-approved', planSHA256=base.evidence.digest(current.WORK / 'offline-plan.json'),
        frozenInputs=len(inputs), candidate=candidate['version'], initialCapacityPassed=plan['initialCapacityPassed'])))


if __name__ == '__main__':
    main()
