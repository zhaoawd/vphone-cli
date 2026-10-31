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
import shutil

import execute_t33_plist_lifetime_acceptance as current

runner = current.runner
base = runner.base


def inherited_private(path, expected):
    info = path.lstat()
    actual = dict(bytes=info.st_size, dev=info.st_dev, ino=info.st_ino,
        mtime_ns=info.st_mtime_ns, mode=stat.S_IMODE(info.st_mode), uid=info.st_uid, gid=info.st_gid)
    if info.st_nlink != 1 or not stat.S_ISREG(info.st_mode) or any(expected[k] != v for k, v in actual.items()):
        raise ValueError('Private input identity differs from verified native proof')
    return dict(expected)


def diagnostic_evidence(chronology, chains):
    journal = 'f8f2d9963fef16e250663c956b515e702fd2c63470bd31229568706136d01be3'
    if (chronology.get('historicalRows') != 33482
            or chronology.get('changedRows') != [33459,33460,33461,33467,33468,33469]
            or any(chronology.get(key) is not True for key in (
                'originalFailureReproduced', 'modeledChronologyChecksPassed',
                'modeledRequiredProducerCoverageComplete', 'observedBeforeAfterStatesUnchanged',
                'originalJournalPreserved'))
            or chronology.get('originalJournalSHA256') != journal
            or chronology.get('verifierSHA256') != base.evidence.digest(runner.ROOT / 'scripts/patchers/component_transport.py')
            or any(chronology.get(key) is not False for key in ('finalDiskReadPerformed', 'accepted'))):
        raise ValueError('Complete unmodified-journal chronology model required')
    if (chains.get('checkedChains') != 119 or chains.get('failedChains') != 0
            or chains.get('originalJournalSHA256') != journal
            or chains.get('originalJournalPreserved') is not True
            or chains.get('failures') != [] or chains.get('accepted') is not False
            or chains.get('finalDiskReadPerformed') is not False
            or chains.get('guestMetadataReadbackPerformed') is not False):
        raise ValueError('All retained byte and signature chain checks required')


def main():
    current.configure()
    old_work = runner.BASE / 'exp-bootstrap-acceptance-20261025'
    old = json.loads(base.evidence.read(old_work / 'offline-plan.json'))
    final = json.loads(base.evidence.read(old_work / 'finalization.json'))
    if final['nativeState'] != 'failed' or final['phaseTransactions']:
        raise ValueError('Previous attempt did not stop before publication')
    native = json.loads(base.evidence.read(old_work / 'execution/result.json'))
    if (native.get('beforeWriteBackupVerified') is not True or native.get('targetAttachments') != []
            or 'preservationOrCleanupError' in native):
        raise ValueError('Previous native preservation incomplete')
    preflight_path = runner.BASE / 'bootstrap-flatten-real-resource-20261025/result.json'
    preflight = json.loads(base.evidence.read(preflight_path))
    if (preflight.get('passed') is not True or preflight.get('realBootstrap') is not True
            or preflight.get('packageResourcePreserved') is not True
            or preflight.get('unrecordedMarkerMutationRejected') is not True
            or preflight.get('exactArchiveMembers') != 6528):
        raise ValueError('Complete real bootstrap preflight required')
    candidate_path = runner.BASE / 'candidate-exp-plist-lifetime-20261025.json'
    candidate = json.loads(base.evidence.read(candidate_path))
    chronology_path = runner.BASE / 'transport-chronology-analysis-20261025.json'
    chains_path = runner.BASE / 'recorded-effect-chains-20261025.json'
    diagnostic_evidence(json.loads(base.evidence.read(chronology_path)), json.loads(base.evidence.read(chains_path)))
    packaged = Path(candidate['bundle']) / 'Contents/Resources/scripts/cfw_install_exp.sh'
    if base.evidence.digest(packaged) != base.evidence.digest(runner.ROOT / 'scripts/cfw_install_exp.sh'):
        raise ValueError('Packaged EXP script differs from tested source')
    target = copy.deepcopy(old['targets'][0])
    target['beforeWriteBackup'] = str(current.BACKUP)
    print('Reading current boot files including complete Disk.img', flush=True)
    with base.audit.locked_vm(runner.VM):
        base.txn.require_unheld(runner.VM / 'Disk.img', os.getpid(), 'plist lifetime preparation')
        target['currentBootFiles'] = {name: runner.snapshot(runner.VM / name)
            for name in old['sourceBootFiles'] | {'launchpad.json': {}}}
        target['currentBootFiles']['.firmware-desired-plan.json'] = inherited_private(
            runner.VM / '.firmware-desired-plan.json', old['targets'][0]['currentBootFiles']['.firmware-desired-plan.json'])
        if target['currentBootFiles']['Disk.img']['sha256'] != old['sourceBootFiles']['Disk.img']['sha256']:
            raise ValueError('Current complete disk differs from retained source')
        target['expectedBinding'] = json.loads(base.evidence.read(runner.VM / 'launchpad.json'))
        if (target['expectedBinding'] != dict(old['targets'][0]['expectedBinding'], bundle=old['candidate']['version'])):
            raise ValueError('Current binding differs from native finalization')
        target['priorFailedTransactions'] = ['20261025T021021Z-hnTJT23g', '20261025T043518Z-1urmPFY7', '20261025T100633Z-Bvlz2q7C', '20261025T114952Z-zhZ5OOCf']
        target['historyRecords'] = runner.history(target)
        if base.txn.committed_guest_evidence(runner.VM) is not None:
            raise ValueError('Published guest cannot use this continuation')
        target['scratchTrees'] = {name: base.effects.state(runner.VM / name)
            for name in runner.SCRATCH if (runner.VM / name).exists()}
        host_flag = runner.snapshot(runner.VM / '.ssh_forward')
    target.update(runner.commands(target['currentBootFiles']['launchpad.json']['sha256']))
    plan = {k: copy.deepcopy(old[k]) for k in ('sourceBackup', 'sourceBootFiles', 'pythonRuntime',
        'minimumInitialFreeBytes', 'minimumEachCFWFreeBytes', 'expectedPrebootTarget',
        'unexpectedPrebootPolicy', 'signatureAcceptance', 'unrelatedDiskIdentities')}
    paths = [Path(p) for p in old['frozenInputs']]
    paths += [candidate_path, Path(candidate['archive']), Path(__file__), Path(current.__file__),
              old_work / 'finalization.json', preflight_path]
    paths += [p for p in Path(candidate['bundle']).rglob('*') if p.is_file()]
    paths += [runner.BASE / name for name in (
        'transport-input-replay-20261025.json', 'transport-continuity-scan-20261025.json',
        'transport-chronology-analysis-20261025.json', 'recorded-effect-chains-20261025.json',
        'exp-plist-lifetime-red-20261025.log', 'exp-plist-lifetime-green-20261025.log',
        'exp-plist-lifetime-python-20261025.log', 'exp-plist-lifetime-package-20261025.log',
        'exp-plist-lifetime-executor-tests-final-20261025.log', 'exp-plist-lifetime-consumer-tests-20261025.log')]
    paths += [Path(__file__).with_name(name) for name in (
        'build_t33_plist_lifetime_candidate.py', 'probe_t33_transport_input.py',
        'analyze_t33_transport_chronology.py', 'verify_t33_recorded_effect_chains.py')]
    paths += [runner.ROOT / 'tests/test_exp_plist_staging_lifetime.py']
    # Each new plan freezes current files; prior frozen manifests remain historical records.
    inputs = {str(p.resolve(strict=True)): base.evidence.digest(p.resolve(strict=True)) for p in paths}
    plan.update(schemaVersion=1, scope='single unpublished EXP plist staging lifetime continuation',
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
    plan['protectedHostInputs'] = {'.ssh_forward': dict(current=host_flag,
        backup=str(current.WORK / 'host-input-backup/.ssh_forward'),
        ownershipPolicy=current.HOST_ARCHIVE_POLICY,
        backupState=dict(host_flag, ino=-1))}
    plan['preserve'].append('complete existing SSH host marker content and metadata in the frozen preparation backup')
    current.validate(plan)
    for path in (current.BACKUP, runner.CLI.parents[3]):
        if os.path.lexists(path):
            raise ValueError('Preserve existing output or Store')
    if current.WORK.exists():
        raise ValueError('Preserve existing preparation; no replay')
    print('Verifying retained source, frozen inputs and unrelated disk identities', flush=True)
    base.baseline(plan); base.verify_inputs(plan); runner.previous.unrelated(plan)
    info = os.statvfs(runner.ROOT)
    plan['observedAvailableBytes'] = info.f_bavail * info.f_frsize
    plan['initialCapacityPassed'] = plan['observedAvailableBytes'] >= plan['minimumInitialFreeBytes']
    flags = current.WORK / 'host-input-backup'
    current.WORK.mkdir(); flags.mkdir(mode=0o700)
    shutil.copy2(runner.VM / '.ssh_forward', flags / '.ssh_forward')
    if runner.snapshot(runner.VM / '.ssh_forward') != host_flag:
        raise ValueError('Host marker changed during preparation')
    plan['protectedHostInputs']['.ssh_forward']['backupState'] = runner.snapshot(flags / '.ssh_forward')
    plan['hostArchivePreparationResumed'] = False
    inputs[str(flags / '.ssh_forward')] = base.evidence.digest(flags / '.ssh_forward')
    current.validate(plan); current.verify_host_inputs(plan)
    base.save(current.WORK / 'offline-plan.json', plan)
    print(json.dumps(dict(state='prepared-not-approved', planSHA256=base.evidence.digest(current.WORK / 'offline-plan.json'),
        frozenInputs=len(inputs), capacityPassed=plan['initialCapacityPassed'], availableBytes=plan['observedAvailableBytes'])))


if __name__ == '__main__':
    main()
