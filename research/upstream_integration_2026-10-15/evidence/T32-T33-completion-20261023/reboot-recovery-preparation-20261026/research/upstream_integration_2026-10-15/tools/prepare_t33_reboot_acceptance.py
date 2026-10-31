"""Freeze a concrete recovery sequence; this creates no VM recovery authority."""
import copy
import json
import os
from pathlib import Path
import shutil
import stat

import execute_t33_reboot_acceptance as current

base = current.base


def inherited_private(path, old):
    """Old native full hash plus current metadata; root must reread before writes."""
    info = path.lstat()
    actual = dict(bytes=info.st_size, dev=info.st_dev, ino=info.st_ino, mtime_ns=info.st_mtime_ns,
        mode=stat.S_IMODE(info.st_mode), uid=info.st_uid, gid=info.st_gid)
    if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
            or any(old[k] != value for k, value in actual.items() if k != 'dev')):
        raise ValueError('Private desired-plan metadata changed beyond the observed reboot device number')
    return dict(actual, sha256=old['sha256'])


def main():
    old = current.read(current.OLD_WORK / 'offline-plan.json')
    if base.evidence.digest(current.OLD_WORK / 'offline-plan.json') != current.OLD_PLAN_SHA:
        raise ValueError('Historical plan changed')
    candidate = current.read(current.CANDIDATE)
    replay_dir = current.BASE / 'reboot-real-identity-preflight-20261026'
    replay = current.read(replay_dir / 'result.json')
    if (any(replay.get(k) is not True for k in ('passed', 'pythonPublicationReplayPassed',
            'swiftIdentityReplayPassed', 'ordinaryUnregisteredLookupStillRefuses'))
            or any(replay.get(k) != value for k, value in dict(completeImagesRead=4, registrationInstalled=False,
                published=False, transactionWrites=0, VMStarts=0, accepted=False).items())):
        raise ValueError('Actual readonly four-image and dual-language history replay required')
    if any(p.exists() for p in (current.WORK, current.BACKUP, current.PRESERVED, current.NEW_WORK)):
        raise ValueError('Preserve existing recovery preparation or output')
    print('Reading current boot files and retained source backup completely', flush=True)
    with current.locked_pending():
        boot = {name: current.retained.snapshot(current.VM / name) for name in old['sourceBootFiles'] | {'launchpad.json': {}}}
        boot['.firmware-desired-plan.json'] = inherited_private(current.VM / '.firmware-desired-plan.json',
            old['targets'][0]['currentBootFiles']['.firmware-desired-plan.json'])
        binding = current.read(current.VM / 'launchpad.json')
        failed = {name: current.retained.snapshot(current.VM / '.cfw-history' / name / 'transaction.json')
                  for name in sorted(current.FAILED)}
        scratch = {name: base.effects.state(current.VM / name) for name in current.retained.SCRATCH}
        marker = current.retained.snapshot(current.VM / '.ssh_forward')
        diagnostic = current.retained.snapshot(current.VM / '.vphone-runtime.json') if (current.VM / '.vphone-runtime.json').exists() else None
    source = Path(old['sourceBackup'])
    source_files = {name: current.retained.snapshot(source / name) for name in old['sourceBootFiles']}
    for name, row in source_files.items():
        if any(row[k] != old['sourceBootFiles'][name][k] for k in row if k != 'dev'):
            raise ValueError('Retained source changed beyond the observed reboot device number: ' + name)
    unrelated = {}
    for name, expected in old['unrelatedDiskIdentities'].items():
        info = (current.ROOT / name).stat()
        if info.st_ino != expected['ino'] or info.st_size != expected['size']:
            raise ValueError('Preserved unrelated disk changed')
        unrelated[name] = dict(dev=info.st_dev, ino=info.st_ino, size=info.st_size)
    rows = current.read(replay_dir / 'swift-replay.json')['members']
    aliases = [['Disk.img', str(current.NEW_WORK.relative_to(current.VM) / 'Disk.img'),
                str(current.NEW_WORK.relative_to(current.VM) / 'Disk.img.previous'),
                '.cfw-history/' + current.RECOVERY_ID + '/Disk.img',
                '.cfw-history/' + current.RECOVERY_ID + '/Disk.img.previous'],
        ['.cfw-history/' + current.FIRST + '/Disk.img'],
        ['.cfw-history/' + current.FIRST + '/guest-postimage.img'],
        [str(current.PENDING.relative_to(current.VM) / 'Disk.img'), str(current.PRESERVED.relative_to(current.VM) / 'Disk.img')]]
    members = [dict(row, paths=paths) for row, paths in zip(rows, aliases, strict=True)]
    import cfw_reboot_identity as identity
    volume = identity._volume_uuid(current.VM)
    identity.RequalifiedIdentity(current.VM, volume, members)  # Structural validation only, no root registration.
    scripts = Path(candidate['bundle']) / 'Contents/Resources/scripts'
    modules = {str(p.relative_to(scripts)): base.evidence.digest(p) for p in scripts.rglob('*.py')}
    target = dict(vm=str(current.VM), mode='recover-observed-undo-and-reapply', variant='exp', generationID=current.GENERATION,
        targets=current.retained.previous.TARGETS, declarations=['system-systemversion-cfw-build_version'],
        currentBootFiles=boot, expectedBinding=binding, failedHistoryRecords=failed, scratchTrees=scratch)
    plan = {k: copy.deepcopy(old[k]) for k in ('pythonRuntime', 'minimumInitialFreeBytes', 'minimumEachCFWFreeBytes',
        'expectedPrebootTarget', 'unexpectedPrebootPolicy', 'signatureAcceptance')}
    plan.update(schemaVersion=1, scope='single explicit recovered Undo publication followed by one exact EXP reapplication',
        candidate=candidate, targets=[target], sourceBackup=str(source), sourceBootFiles=source_files,
        unrelatedDiskIdentities=unrelated, priorInterruptedPlanSHA256=current.OLD_PLAN_SHA,
        recovery=current.expected_recovery(), requalificationMembers=members, volumeUUID=volume,
        readonlyReplayDirectory=str(replay_dir), installedModuleSHA256=modules,
        diagnosticHostInput=diagnostic,
        firstOnReportSHA256=base.evidence.digest(current.OLD_WORK / 'execution/exp/on.json'),
        boundBeforeRecovery=dict(binding, bundle=candidate['version']),
        reuseLockedPythonRuntime=True, VMStarts=0, normalGUIBoots=0, securityWindows=0,
        repeatedFirstOn=0, repeatedUndoWrites=0, automaticRetry=False, automaticRollback=False,
        additionalDeletionAllowed=False, regularCFWRepeated=False, runtimeValidated=False,
        privateDesiredPlanEvidence='prior native full readback plus current device-only requalification; mandatory fresh root full readback',
        authorization='not approved; new Store installation, exact recovery registration, retained source move, recovered publication and reapply require confirmation',
        preservedSourcePolicy='retain every old partial file byte-for-byte and keep its staged/unsealed state; never invoke its writer or finish',
        preallocatedIDMeaning='identifier allocated by this plan; actual started_at records execution time',
        preserve=['all remaining VMs, backups and history', 'fresh full 12-file current boot/binding/desired backup',
                  'existing caches moved to the new backup', 'existing empty SSH marker bytes and original uid/gid record'],
        retiredEvidenceLimit='cleanup96cd retired old hnTJT23g effect-blobs and old DSC history; no complete replay claim',
        cleanup=['normal unmount and detach of only this invocation; failures preserve transaction and evidence'])
    plan.update(current.commands(candidate, boot['launchpad.json']['sha256']))
    plan['runtimeProbeCommand'] = [str(Path(plan['pythonRuntime']['venv']) / 'bin/python3'),
        str(scripts / 'check_python_runtime.py'), '--locked', '--json']
    # Include all source, candidate, diagnostic and executor inputs. Old manifests
    # remain historical artifacts; new manifests bind the repaired sources.
    paths = {Path(p) for p in old['frozenInputs']}
    paths |= {p for p in Path(candidate['bundle']).rglob('*') if p.is_file()}
    paths |= {current.CANDIDATE, Path(candidate['archive']), current.OLD_WORK / 'offline-plan.json',
              current.OLD_WORK / 'execution/exp/on.json'}
    paths |= {current.VM / '.cfw-history' / current.FIRST / name for name in
              ('transaction.json', 'guest-publication.json', 'guest-file-originals.json', 'guest-plan.json')}
    paths |= {p for p in replay_dir.rglob('*') if p.is_file()}
    paths |= set(Path(__file__).parent.glob('*t33*reboot*.py'))
    paths.add(Path(__file__).with_name('run_t33_recovered_undo.py'))
    paths.add(Path(__file__).with_name('test_t33_recovered_undo_worker.py'))
    paths |= set((current.ROOT / 'scripts').glob('*.py')) | set((current.ROOT / 'scripts/patchers').glob('*.py'))
    paths |= {current.ROOT / p for p in ('tests/test_cfw_reboot_identity.py', 'tests/test_guest_reboot_recovery.py',
        'sources/FirmwarePatcher/Pipeline/FirmwareRebootIdentity.swift', 'sources/FirmwarePatcher/Pipeline/FirmwareGuestDiskIdentity.swift',
        'tests/cfw_reboot_mixed_identity_fixture.py', 'tests/VPhoneCLITests/CFWRebootIdentityBridgeTests.swift',
        'tests/VPhoneCLITests/CFWOriginIdentityBridgeTests.swift', 'tests/FirmwarePatcherTests/FirmwareRebootIdentityTests.swift')}
    paths |= {current.BASE / name for name in ('reboot-final-python-full-20261026.log',
        'reboot-preallocated-id-tests-r2-20261026.log', 'reboot-mixed-device-chain-final-r2-20261026.log',
        'reboot-native-parent-device-red-20261026.log', 'reboot-worker-executor-tests-final-r3-20261026.log',
        'reboot-candidate-package-r2-20261026.log')}
    inputs = {str(p.resolve(strict=True)): base.evidence.digest(p.resolve(strict=True)) for p in paths}
    current.WORK.mkdir(); host = current.WORK / 'host-input-backup'; host.mkdir(mode=0o700)
    shutil.copy2(current.VM / '.ssh_forward', host / '.ssh_forward')
    if current.retained.snapshot(current.VM / '.ssh_forward') != marker:
        raise ValueError('Host marker changed during preparation')
    plan['protectedHostInputs'] = {'.ssh_forward': dict(current=marker, backup=str(host / '.ssh_forward'),
        backupState=current.retained.snapshot(host / '.ssh_forward'),
        ownershipPolicy='original uid/gid are recorded separately from the user-owned archive carrier')}
    inputs[str(host / '.ssh_forward')] = base.evidence.digest(host / '.ssh_forward')
    plan['frozenInputs'] = inputs
    info = os.statvfs(current.ROOT)
    plan['observedAvailableBytes'] = info.f_bavail * info.f_frsize
    plan['initialCapacityPassed'] = plan['observedAvailableBytes'] >= plan['minimumInitialFreeBytes']
    current.validate(plan); current.verify_first_on(plan, current.read(current.OLD_WORK / 'execution/exp/on.json'))
    base.baseline(plan); current.retained.previous.unrelated(plan); base.verify_inputs(plan)
    cli = Path(plan['installedCLI'])
    if cli.parents[3].exists() or (current.VM / '.cfw-reboot-identity.json').exists():
        raise ValueError('Existing Store candidate or recovery registration; preparation cannot replace it')
    base.save(current.WORK / 'offline-plan.json', plan)
    print(json.dumps(dict(state='prepared-not-approved', planSHA256=base.evidence.digest(current.WORK / 'offline-plan.json'),
        frozenInputs=len(inputs), candidate=candidate['version'], initialCapacityPassed=plan['initialCapacityPassed'])))


if __name__ == '__main__':
    main()
