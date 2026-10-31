"""One new approval after source-observation refusal; reuse verified disk backups."""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import subprocess
import time

import execute_t33_reboot_acceptance as previous

base = previous.base
retained = previous.retained
ROOT = previous.ROOT; BASE = previous.BASE; VM = previous.VM; GENERATION = previous.GENERATION
FIRST = previous.FIRST; INTERRUPTED = previous.INTERRUPTED; RECOVERY_ID = previous.RECOVERY_ID
WORK = BASE / 'exp-source-identity-acceptance-20261026'
BACKUP = BASE / 't33t-before-source-identity-20261026'
CANDIDATE = BASE / 'candidate-exp-source-identity-20261026.json'
EMPTY_DESTINATION = previous.PRESERVED.parent / '2e489523-empty-work-20261026'
PRIOR_SHA = '2e48952320c7b10206b3ff8e3eecdf891d0c194f984979d8a2f7d44b01c324cb'
PRIMARY_SHA = 'b15ab16b9ca6a440d704ae32aa58f5edc0602a034f451577b848ce00c1354ad3'
read = previous.read
verify_first_on = previous.verify_first_on


def configure(digest):
    base.WORK = WORK; base.APPROVED_SHA256 = digest; base.EXECUTOR_INPUTS = 'executor-inputs.json'


def validate(plan):
    target, = plan['targets']; candidate = read(CANDIDATE)
    if (plan['candidate'] != candidate or plan['priorFailedPlanSHA256'] != PRIOR_SHA
            or plan['primaryRegistrationSHA256'] != PRIMARY_SHA
            or plan['retainedBackup'] != str(previous.BACKUP)
            or plan['emptyWorkDestination'] != str(EMPTY_DESTINATION)
            or plan['recovery'] != previous.expected_recovery()
            or target['vm'] != str(VM) or target['generationID'] != GENERATION or target['variant'] != 'exp'
            or target['mode'] != 'resume-after-source-observation-refusal'
            or target['targets'] != retained.previous.TARGETS
            or target['declarations'] != ['system-systemversion-cfw-build_version']
            or candidate['targetRulesSHA256'] != retained.previous.RULES
            or plan['minimumInitialFreeBytes'] != 75 << 30 or plan['minimumEachCFWFreeBytes'] != 50 << 30
            or set(target['currentBootFiles']) != set(plan['sourceBootFiles']) | {'launchpad.json', '.firmware-desired-plan.json'}
            or target['currentBootFiles']['Disk.img']['sha256'] != previous.CURRENT_SHA
            or target['currentBootFiles']['.firmware-desired-plan.json']['sha256'] != previous.DESIRED_SHA
            or target['expectedBinding'] != dict(bundle='2.6.2-local.73b536cbb70c', guestEnvironment='2.6.2-local.f43043c4c559')
            or set(target['failedHistoryRecords']) != previous.FAILED
            or plan['reuseLockedPythonRuntime'] is not True
            or plan['boundBeforeRecovery'] != dict(target['expectedBinding'], bundle=candidate['version'])
            or any(plan[k] != 0 for k in ('VMStarts', 'normalGUIBoots', 'securityWindows', 'repeatedFirstOn',
                                        'repeatedUndoWrites', 'repeatedPrimaryRegistration', 'repeatedW7Move'))
            or any(plan[k] is not False for k in ('automaticRetry', 'automaticRollback', 'additionalDeletionAllowed', 'regularCFWRepeated'))):
        raise ValueError('Source-observation continuation scope changed')
    expected = previous.commands(candidate, target['currentBootFiles']['launchpad.json']['sha256'])
    if any(plan.get(k) != v for k, v in expected.items()): raise ValueError('Continuation command changed')
    preflight = read(Path(plan['packagedPreflightDirectory']) / 'result.json')
    if (any(preflight.get(k) is not True for k in ('passed', 'completeFourImageReadbacksPassed',
            'completeParentPublicationPassed', 'productionCompleteUndoPreviewPassed', 'rebuiltIndexByteIdentical',
            'preservedUndoSourceVerified')) or plan['sourceMembers'] != preflight['sourceMembers']
            or len(plan['sourceMembers']) != 2 or plan['emptyWork'] != preflight['emptyFailedWork']
            or target['currentBootFiles'] != preflight['currentBootFiles']
            or plan['smallBackupFiles'] != preflight['currentHostFiles']
            or plan['volumeUUID'] != preflight['volumeUUID']
            or plan['installedModuleSHA256'] != preflight['candidateModulesSHA256']
            or set(plan['smallBackupFiles']) != {'launchpad.json', '.vphone-runtime.json', '.ssh_forward', '.cfw-reboot-identity.json'}):
        raise ValueError('Complete packaged Undo/source preflight required')
    if plan['firstOnReportSHA256'] != base.evidence.digest(previous.OLD_WORK / 'execution/exp/on.json'):
        raise ValueError('Preserved first-on report changed')
    if set(plan['protectedHostInputs']) != {'.ssh_forward'}:
        raise ValueError('Preserved host marker required')
    marker = plan['protectedHostInputs']['.ssh_forward']
    keys = {'sha256', 'bytes', 'dev', 'ino', 'mtime_ns', 'mode', 'uid', 'gid'}
    if (marker.get('backup') != str(WORK / 'host-input-backup/.ssh_forward')
            or marker.get('ownershipPolicy') != 'original uid/gid are recorded separately from the user-owned archive carrier'
            or marker.get('current') != plan['smallBackupFiles']['.ssh_forward']
            or set(marker.get('current', {})) != keys or set(marker.get('backupState', {})) != keys
            or any(marker['current'][k] != marker['backupState'][k] for k in keys - {'dev', 'ino', 'uid', 'gid'})):
        raise ValueError('Full SSH marker content and original metadata record required')
    return plan


@contextlib.contextmanager
def locked_empty(plan):
    import vm_lock
    import cfw_source_identity as source_identity
    if VM.resolve(strict=True) != VM:
        raise ValueError('Exact recovery VM path required')
    fd = os.open(VM, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    before = os.environ.get(vm_lock.FD_ENV)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB); os.environ[vm_lock.FD_ENV] = str(fd); vm_lock.check_inherited(VM)
        empty = previous.NEW_WORK
        if (list(VM.glob('.cfw_disk.*')) != [empty] or list(empty.iterdir())
                or source_identity.metadata(empty.lstat()) != plan['emptyWork']['metadata']
                or (VM / '.firmware-desired-pending.json').exists()):
            raise ValueError('Retained failed work is not the exact empty directory')
        yield
    finally:
        if before is None: os.environ.pop(vm_lock.FD_ENV, None)
        else: os.environ[vm_lock.FD_ENV] = before
        os.close(fd)


def verify_old_backup():
    old = read(previous.WORK / 'offline-plan.json')
    if base.evidence.digest(previous.WORK / 'offline-plan.json') != PRIOR_SHA:
        raise ValueError('Retained backup plan changed')
    return previous.verify_preservation(old)


def verify_small(plan):
    for name, expected in plan['smallBackupFiles'].items():
        actual = retained.snapshot(BACKUP / name)
        if any(actual[k] != expected[k] for k in ('sha256', 'bytes', 'mtime_ns', 'mode', 'uid', 'gid')):
            raise ValueError('Small continuation backup changed: ' + name)


def preserve_and_register(plan, digest):
    import cfw_reboot_identity as disk_identity
    import cfw_source_identity as source_identity
    from patchers import guest_undo
    with locked_empty(plan):
        target, = plan['targets']
        if {name: retained.snapshot(VM / name) for name in target['currentBootFiles']} != target['currentBootFiles']:
            raise ValueError('Current boot/binding/desired state changed')
        if read(VM / 'launchpad.json') != target['expectedBinding']:
            raise ValueError('Host/guest binding changed before preservation')
        previous.verify_host_inputs(plan)
        base.txn.require_unheld(VM / 'Disk.img', os.getpid(), 'source-observation continuation')
        if base.evidence.digest(VM / disk_identity.REGISTRATION) != PRIMARY_SHA:
            raise ValueError('Existing four-image registration changed')
        physical = disk_identity.load_registered(VM, GENERATION, plan['volumeUUID'])
        if physical is None: raise ValueError('Existing image association unavailable')
        physical.verify_files(disk_identity._volume_uuid(VM))
        verify_old_backup()
        BACKUP.mkdir(mode=0o700)
        for name, expected in plan['smallBackupFiles'].items():
            if retained.snapshot(VM / name) != expected: raise ValueError('Host input changed before preservation')
            base.clone_file(VM / name, BACKUP / name)
        verify_small(plan)
        parent = base.txn.committed_guest_evidence(VM)
        if parent is None or parent[1]['id'] != FIRST: raise ValueError('Preserved first-on parent changed')
        saved = guest_undo.saved_plan(parent[0], GENERATION)
        registration = source_identity.register_sources(saved, digest, plan['sourceMembers'])
        # Real registered-reader preview and preserved-source validation run
        # before creating a new transaction or exchanging any disk.
        preview = guest_undo.preview(VM, GENERATION, target['declarations'], _committed=parent)
        from patchers import guest_recovery
        guest_recovery.verify_source(VM, previous.PRESERVED, plan['recovery'], preview, parent)
        base.txn.move_exclusive(previous.NEW_WORK, EMPTY_DESTINATION)
        base.evidence.sync_directory(EMPTY_DESTINATION.parent); base.evidence.sync_directory(VM)
        if list(EMPTY_DESTINATION.iterdir()): raise ValueError('Preserved failed-work directory is not empty')
        base.save(WORK / 'execution/source-registration.json', dict(sha256=registration, planSHA256=digest,
            primaryRegistrationUnchanged=True, preservedEmptyDirectory=str(EMPTY_DESTINATION),
            productionRegisteredPreviewPassed=True, preservedSourceVerified=True))


def execute(plan, digest):
    configure(digest)
    if os.geteuid() != 0: raise ValueError('Native administrator authentication required')
    base.approved(digest); base.verify_inputs(plan); base.verify_execution_inputs(); base.require_capacity(plan)
    (WORK / 'native-execution.claim').mkdir(mode=0o700)
    identity = subprocess.check_output(['/bin/ps', '-p', str(os.getpid()), '-o', 'uid=,lstart='], text=True,
                                      env=dict(os.environ, LC_ALL='C')).strip()
    base.save(WORK / 'native-root-identity.json', dict(pid=os.getpid(), uidAndStart=identity))
    out = WORK / 'execution'; out.mkdir(mode=0o755)
    result = dict(state='failed', VMStarts=0, securityWindows=0, deletionPerformed=False,
        repeatedFirstOn=0, repeatedUndoWrites=0, repeatedPrimaryRegistration=0, repeatedW7Move=0,
        automaticRetry=False, automaticRollback=False, phaseTransactions={})
    env = base.runtime_environment(plan); times = {}
    def step(name, action):
        print('Starting ' + name, flush=True); start = time.monotonic(); value = action()
        times[name] = time.monotonic() - start; base.save(out / (name + '-timing.json'), dict(seconds=times[name])); return value
    try:
        validate(plan); retained.previous.unrelated(plan)
        cli = Path(plan['installedCLI'])
        import cfw_source_identity as source_identity
        if any(os.path.lexists(p) for p in (BACKUP, EMPTY_DESTINATION, cli.parents[3], VM / source_identity.REGISTRATION)):
            raise ValueError('Existing continuation output, Store or source registration; no replay')
        if base.target_attachments(plan): raise ValueError('Target image attached')
        step('source-backup', lambda: base.baseline(plan))
        step('preserve-and-register', lambda: preserve_and_register(plan, digest))
        base.run(plan['runtimeProbeCommand'], out / 'runtime-probe.log', env)
        if read(out / 'runtime-probe.log').get('ok') is not True: raise ValueError('Locked Python runtime refused')
        candidate = plan['candidate']; local = Path(candidate['bundle']) / 'Contents/MacOS/vphone-cli'
        base.run([local, 'core-bundle', 'install', '--version', candidate['version'], '--archive', candidate['archive'],
                  '--sha256', candidate['archiveSHA256']], out / 'store-install.log', env)
        base.run([cli, 'core-bundle', 'verify', '--version', candidate['version']], out / 'store-verify.log', env)
        if base.evidence.digest(cli) != candidate['cliSHA256']: raise ValueError('Installed CLI differs')
        base.run(plan['bindingCommand'], out / 'bind.log', env, identity=plan['sourceBootFiles']['config.plist'])
        if read(VM / 'launchpad.json') != plan['boundBeforeRecovery']: raise ValueError('Unrelated component origins changed')
        exp = out / 'exp'; exp.mkdir()
        first = read(previous.OLD_WORK / 'execution/exp/on.json'); verify_first_on(plan, first)
        base.save(exp / 'on.json', first); result['phaseTransactions']['on'] = FIRST
        python = str(Path(plan['pythonRuntime']['venv']) / 'bin/python3'); scripts = cli.parent.parent / 'Resources/scripts'
        base.approved(digest); base.verify_inputs(plan); base.verify_execution_inputs(); base.require_capacity(plan, initial=False)
        step('recovered-undo', lambda: base.run([python, scripts / 'vm_lock.py', VM, 'cfw-record', '--', python, '-B',
            Path(__file__).with_name('run_t33_recovered_undo.py'), '--plan', WORK / 'offline-plan.json', '--sha256', digest], exp / 'off.log', env))
        off, _ = step('off-audit', lambda: base.inspect_phase(plan, plan['targets'][0], GENERATION, 'off'))
        if off['transactionID'] != RECOVERY_ID: raise ValueError('Different recovered publication')
        with base.audit.locked_vm(VM):
            archive, record, checkpoint, final = base.txn.committed_guest_evidence(VM)
            originals = base.file_originals.load(base.guest_undo.saved_plan(archive, GENERATION), archive / base.evidence.STORE)['members']
        base.verify_restored(plan['targets'][0], originals)
        base.save(exp / 'originals.json', {name: originals[name] for name in plan['targets'][0]['targets']})
        base.save(exp / 'off.json', off); result['phaseTransactions']['off'] = RECOVERY_ID
        base.approved(digest); base.verify_inputs(plan); base.verify_execution_inputs(); base.require_capacity(plan, initial=False)
        step('reapply', lambda: base.run(plan['installCommand'], exp / 'reapplied.log', env))
        reapplied, _ = step('reapply-audit', lambda: base.inspect_phase(plan, plan['targets'][0], GENERATION, 'reapplied'))
        base.save(exp / 'reapplied.json', reapplied); result['phaseTransactions']['reapplied'] = reapplied['transactionID']
        transition = base.transition(first['targets'], off['targets'], reapplied['targets'], originals, plan['targets'][0]['targets'])
        base.save(exp / 'transition.json', transition); result.update(state='offline-qualified-on-off-on-passed', transition=transition)
    except Exception as error: result['error'] = str(error)
    finally:
        try:
            result['baseline'] = base.baseline(plan); retained.previous.unrelated(plan)
            base.verify_inputs(plan); base.verify_execution_inputs()
            result['preservation'] = verify_old_backup()
            if BACKUP.exists():
                verify_small(plan)
                result['smallBackupFiles'] = len(plan['smallBackupFiles'])
            if base.evidence.digest(VM / '.cfw-reboot-identity.json') != PRIMARY_SHA:
                raise ValueError('Existing image registration changed')
            source_path = VM / source_identity.REGISTRATION
            if source_path.exists():
                from patchers import guest_undo
                source_record = json.loads(source_identity.registered_bytes(source_path))
                if (source_record['approvedPlanSHA256'] != digest or source_record['members'] != plan['sourceMembers']):
                    raise ValueError('New source registration changed')
                current_plan = guest_undo.saved_plan(previous.PRESERVED, GENERATION)
                source_identity.decode(source_record, VM, GENERATION).verify_files(current_plan, plan['volumeUUID'])
                result['sourceRegistrationSHA256'] = base.evidence.digest(source_path)
            if EMPTY_DESTINATION.exists():
                if list(EMPTY_DESTINATION.iterdir()): raise ValueError('Retained empty work changed')
                result['preservedEmptyWork'] = str(EMPTY_DESTINATION)
            result['targetAttachments'] = base.target_attachments(plan)
            if result['targetAttachments']: raise ValueError('Attachment retained; no forced cleanup')
        except Exception as error: result.update(state='failed', preservationError=str(error))
        result['timings'] = times; base.save(out / 'result.json', result); print(json.dumps(result), flush=True)
    return 0 if result['state'] == 'offline-qualified-on-off-on-passed' else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__); group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--prepare-executor', action='store_true'); group.add_argument('--execute-approved-plan')
    args = parser.parse_args(); plan = validate(read(WORK / 'offline-plan.json')); digest = base.evidence.digest(WORK / 'offline-plan.json')
    configure(digest)
    if args.prepare_executor:
        base.verify_inputs(plan); files = base.execution_inputs(plan)
        for path in Path(__file__).parent.glob('*t33*source*.py'): files[str(path)] = base.evidence.digest(path)
        for name in ('execute_t33_reboot_acceptance.py', 'execute_t33_dev_overlay_acceptance.py',
                     'execute_t33_target_binding_acceptance.py', 'finalize_t33_target_binding_acceptance.py', 'run_t33_recovered_undo.py'):
            path = Path(__file__).with_name(name); files[str(path)] = base.evidence.digest(path)
        base.save(WORK / 'executor-inputs.json', dict(planSHA256=digest, files=files))
        print(json.dumps(dict(planSHA256=digest, inputs=len(files), state='prepared-not-approved'))); return 0
    if args.execute_approved_plan != digest: raise ValueError('Wrong continuation digest')
    return execute(plan, digest)


if __name__ == '__main__':
    raise SystemExit(main())
