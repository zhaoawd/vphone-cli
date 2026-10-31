"""Continue the interrupted f430 acceptance once, after a new explicit approval."""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import subprocess
import time
from unittest.mock import patch

import execute_t33_dev_overlay_acceptance as retained

base = retained.base
ROOT = retained.ROOT
BASE = retained.BASE
VM = retained.VM
GENERATION = retained.GENERATION
WORK = BASE / 'exp-reboot-recovery-acceptance-20261026'
BACKUP = BASE / 't33t-before-reboot-recovery-20261026'
CANDIDATE = BASE / 'candidate-exp-reboot-recovery-20261026.json'
OLD_WORK = BASE / 'exp-plist-lifetime-acceptance-20261025'
OLD_PLAN_SHA = '4376d79c942fe26e04a8014d1de6d88c8bc5a49e61c58b49127cfa98e0d14dd7'
FIRST = '20261025T132920Z-adMN63qO'
INTERRUPTED = '20261025T144138Z-W7aZSh3x'
RECOVERY_ID = '20261026T000000Z-reboot20261026'
NEW_WORK = VM / '.cfw_disk.reboot20261026'
PENDING = VM / '.cfw_disk.W7aZSh3x'
PRESERVED = VM / '.cfw-recovery-sources' / INTERRUPTED
CURRENT_SHA = '104c89afb70841172e6eb8bd0991c4d1b7b72fde763731af4c8258b5ba301358'
RESTORED_SHA = 'bdebbae8f46128d2ac9bb57c4fb3a61c6aba8ab120d8607f56f81b60e2a792ef'
DESIRED_SHA = '3badc4d1963fc2d2e56e99a31ebb30d5912ea189f2f5a21348f8b0a4771c74ce'
RECORD_SHA = '9f98451c4be8c4d4d71c8677d36759bac78ad4d1e27467f5de915024b6296c27'
FAILED = {'20261025T021021Z-hnTJT23g', '20261025T043518Z-1urmPFY7',
          '20261025T100633Z-Bvlz2q7C', '20261025T114952Z-zhZ5OOCf'}


def read(path):
    return json.loads(base.evidence.read(path))


def configure(digest):
    base.WORK = WORK; base.APPROVED_SHA256 = digest; base.EXECUTOR_INPUTS = 'executor-inputs.json'


def expected_recovery():
    return dict(sourceTransactionID=INTERRUPTED, pendingSource=str(PENDING), preservedSource=str(PRESERVED),
        newWork=str(NEW_WORK), transactionID=RECOVERY_ID, recordSHA256=RECORD_SHA,
        imageSHA256=RESTORED_SHA, parentImageSHA256=CURRENT_SHA, desiredSHA256=DESIRED_SHA,
        repeatedUndoWrites=0, partialSourceMustRemainUnsealed=True)


def commands(candidate, binding_sha):
    cli = Path('/Library/Application Support/vphone-launchpad/Bundles') / candidate['version'] / 'VPhone.bundle/Contents/MacOS/vphone-cli'
    common = [VM.name, '--library-root', str(VM.parent)]
    return dict(installedCLI=str(cli),
        bindingCommand=[str(cli), 'vm', 'bind-core-bundle', *common, '--version', candidate['version'],
                        '--expected-binding-sha256', binding_sha],
        installCommand=[str(cli), 'cfw', 'install', *common, '--variant', 'exp', '--qualify-origin',
                        '--keep-artifacts', '--work-parent', '/private/tmp', '--spoof-build', '23Z999999'])


def validate(plan):
    candidate = read(CANDIDATE); target, = plan['targets']
    if (plan['candidate'] != candidate or plan['priorInterruptedPlanSHA256'] != OLD_PLAN_SHA
            or target['vm'] != str(VM) or target['generationID'] != GENERATION
            or target['mode'] != 'recover-observed-undo-and-reapply' or target['variant'] != 'exp'
            or target['targets'] != retained.previous.TARGETS
            or target['declarations'] != ['system-systemversion-cfw-build_version']
            or set(target['currentBootFiles']) != set(plan['sourceBootFiles']) | {'launchpad.json', '.firmware-desired-plan.json'}
            or target['currentBootFiles']['Disk.img']['sha256'] != CURRENT_SHA
            or target['currentBootFiles']['.firmware-desired-plan.json']['sha256'] != DESIRED_SHA
            or set(target['failedHistoryRecords']) != FAILED
            or plan['recovery'] != expected_recovery()
            or candidate['targetRulesSHA256'] != retained.previous.RULES
            or plan['minimumInitialFreeBytes'] != 75 << 30 or plan['minimumEachCFWFreeBytes'] != 50 << 30
            or any(plan[k] != 0 for k in ('VMStarts', 'normalGUIBoots', 'securityWindows', 'repeatedFirstOn', 'repeatedUndoWrites'))
            or any(plan[k] is not False for k in ('automaticRetry', 'automaticRollback', 'additionalDeletionAllowed', 'regularCFWRepeated'))
            or plan['reuseLockedPythonRuntime'] is not True):
        raise ValueError('Reboot recovery scope changed')
    wanted = commands(candidate, target['currentBootFiles']['launchpad.json']['sha256'])
    if any(plan.get(key) != value for key, value in wanted.items()):
        raise ValueError('Recovery command changed')
    if plan['boundBeforeRecovery'] != dict(target['expectedBinding'], bundle=candidate['version']):
        raise ValueError('Recovery host binding must retain the first-on guest producer')
    if target['expectedBinding'] != dict(bundle='2.6.2-local.f43043c4c559', guestEnvironment='2.6.2-local.f43043c4c559'):
        raise ValueError('First-on binding changed')
    allowed = [
        ['Disk.img', str(NEW_WORK.relative_to(VM) / 'Disk.img'), str(NEW_WORK.relative_to(VM) / 'Disk.img.previous'),
         '.cfw-history/' + RECOVERY_ID + '/Disk.img', '.cfw-history/' + RECOVERY_ID + '/Disk.img.previous'],
        ['.cfw-history/' + FIRST + '/Disk.img'],
        ['.cfw-history/' + FIRST + '/guest-postimage.img'],
        [str(PENDING.relative_to(VM) / 'Disk.img'), str(PRESERVED.relative_to(VM) / 'Disk.img')]]
    replay = read(Path(plan['readonlyReplayDirectory']) / 'swift-replay.json')
    rows = replay['members']
    expected = [dict(row, paths=paths) for row, paths in zip(rows, allowed, strict=True)]
    if plan['requalificationMembers'] != expected or len(rows) != 4:
        raise ValueError('Recovery registration must name the exact four reread images and rename paths')
    if set(plan['protectedHostInputs']) != {'.ssh_forward'}:
        raise ValueError('Preserved host marker required')
    marker = plan['protectedHostInputs']['.ssh_forward']
    keys = {'sha256', 'bytes', 'dev', 'ino', 'mtime_ns', 'mode', 'uid', 'gid'}
    if (marker.get('backup') != str(WORK / 'host-input-backup/.ssh_forward')
            or marker.get('ownershipPolicy') != 'original uid/gid are recorded separately from the user-owned archive carrier'
            or set(marker.get('current', {})) != keys or set(marker.get('backupState', {})) != keys
            or any(marker['current'][k] != marker['backupState'][k] for k in keys - {'dev', 'ino', 'uid', 'gid'})):
        raise ValueError('Full SSH marker bytes and original metadata record must match the archive carrier')
    if plan['firstOnReportSHA256'] != base.evidence.digest(OLD_WORK / 'execution/exp/on.json'):
        raise ValueError('Preserved first-on report changed')
    return plan


@contextlib.contextmanager
def locked_pending():
    """Permit only the named interrupted transaction while taking the real lock."""
    import vm_lock
    if VM.resolve(strict=True) != VM:
        raise ValueError('Exact recovery VM path required')
    fd = os.open(VM, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    before = os.environ.get(vm_lock.FD_ENV)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.environ[vm_lock.FD_ENV] = str(fd); vm_lock.check_inherited(VM)
        if sorted(VM.glob('.cfw_disk.*')) != [PENDING] or (VM / '.firmware-desired-pending.json').exists():
            raise ValueError('Unexpected unfinished transaction; no recovery writes')
        yield
    finally:
        if before is None: os.environ.pop(vm_lock.FD_ENV, None)
        else: os.environ[vm_lock.FD_ENV] = before
        os.close(fd)


def verify_host_inputs(plan):
    for name, row in plan['protectedHostInputs'].items():
        if retained.snapshot(Path(row['backup'])) != row['backupState']:
            raise ValueError('Frozen host marker carrier changed')
        if retained.snapshot(VM / name) != row['current']:
            raise ValueError('Host marker changed before recovery')


def existing_locked(plan):
    target, = plan['targets']
    if {name: retained.snapshot(VM / name) for name in target['currentBootFiles']} != target['currentBootFiles']:
        raise ValueError('Complete current boot, binding or desired inputs changed')
    if read(VM / 'launchpad.json') != target['expectedBinding']:
        raise ValueError('Current host or guest binding changed')
    if read(VM / '.firmware-desired-plan.json')['generationID'] != GENERATION:
        raise ValueError('Recovery generation changed')
    if base.evidence.digest(PENDING / 'transaction.json') != RECORD_SHA:
        raise ValueError('Interrupted transaction journal changed')
    if (PENDING / base.evidence.CHECKPOINT).exists():
        raise ValueError('Interrupted source must remain unsealed')
    for name, expected in target['failedHistoryRecords'].items():
        if retained.snapshot(VM / '.cfw-history' / name / 'transaction.json') != expected:
            raise ValueError('Prior failed record changed')
    if {name: base.effects.state(VM / name) for name in retained.SCRATCH} != target['scratchTrees']:
        raise ValueError('Preserved cache content changed')
    verify_host_inputs(plan)
    base.txn.require_unheld(VM / 'Disk.img', os.getpid(), 'recovery parent')
    import cfw_reboot_identity as identity
    binding = identity.RequalifiedIdentity(VM, plan['volumeUUID'], plan['requalificationMembers'])
    binding.verify_files(identity._volume_uuid(VM))
    with patch.object(identity, 'binding_for', return_value=binding):
        parent = base.txn.committed_guest_evidence(VM)
        if parent is None or parent[1]['id'] != FIRST or parent[2]['imageSHA256'] != CURRENT_SHA:
            raise ValueError('Complete preserved first-on publication did not requalify')
    return binding


def preserve(plan):
    target, = plan['targets']
    with locked_pending():
        existing_locked(plan)
        BACKUP.mkdir(mode=0o700); (BACKUP / 'boot').mkdir(mode=0o700)
        for name, expected in target['currentBootFiles'].items():
            base.clone_file(VM / name, BACKUP / 'boot' / name)
            actual = retained.snapshot(BACKUP / 'boot' / name)
            if actual['ino'] == expected['ino'] or any(actual[k] != expected[k] for k in
                    ('sha256', 'bytes', 'mtime_ns', 'mode', 'uid', 'gid')):
                raise ValueError('Complete prewrite backup differs: ' + name)
        if plan['diagnosticHostInput'] is not None:
            (BACKUP / 'host-diagnostics').mkdir(mode=0o700)
            base.clone_file(VM / '.vphone-runtime.json', BACKUP / 'host-diagnostics/.vphone-runtime.json')
            if retained.snapshot(VM / '.vphone-runtime.json') != plan['diagnosticHostInput']:
                raise ValueError('Prior diagnostic runtime record changed')
        # All current files and the four historical disk observations requalify
        # before the first VM-directory write. Old journals remain unchanged.
        existing_locked(plan)
        (BACKUP / 'scratch').mkdir(mode=0o700)
        for name, value in target['scratchTrees'].items():
            if value['kind'] != 'missing':
                base.txn.move_exclusive(VM / name, BACKUP / 'scratch' / name)
                if base.effects.state(BACKUP / 'scratch' / name) != value:
                    raise ValueError('Moved cache differs')
        base.save(BACKUP / 'preservation.json', dict(files=target['currentBootFiles'],
            scratchTrees=target['scratchTrees'], failedHistoryRecords=target['failedHistoryRecords'], fullReadbackPassed=True))


def register_and_preserve_source(plan, digest):
    import cfw_reboot_identity as identity
    with locked_pending():
        target, = plan['targets']
        if {name: retained.snapshot(VM / name) for name in target['currentBootFiles']} != target['currentBootFiles']:
            raise ValueError('Current boot or binding changed before explicit registration')
        verify_host_inputs(plan)
        source_files = source_inventory(PENDING)
        base.save(WORK / 'execution/preserved-source-before.json', source_files)
        registration = identity.register_requalification(VM, GENERATION, digest, plan['requalificationMembers'])
        # The only source move is explicit and preserves every old partial file.
        PRESERVED.parent.mkdir(mode=0o700, exist_ok=True)
        base.txn.move_exclusive(PENDING, PRESERVED)
        base.evidence.sync_directory(PRESERVED.parent); base.evidence.sync_directory(VM)
        if base.evidence.digest(PRESERVED / 'transaction.json') != RECORD_SHA:
            raise ValueError('Preserved source journal changed after its move')
        base.save(WORK / 'execution/recovery-registration.json', dict(sha256=registration,
            planSHA256=digest, path=str(VM / identity.REGISTRATION), preservedSource=str(PRESERVED)))


def source_inventory(directory):
    result = {}
    for path in sorted(directory.rglob('*')):
        if path.is_symlink(): raise ValueError('Linked preserved recovery source')
        if path.is_file(): result[str(path.relative_to(directory))] = retained.snapshot(path)
        elif not path.is_dir(): raise ValueError('Special preserved recovery source')
    if not result: raise ValueError('Empty preserved recovery source')
    return result


def verify_preservation(plan):
    target, = plan['targets']
    for name, expected in target['currentBootFiles'].items():
        actual = retained.snapshot(BACKUP / 'boot' / name)
        if any(actual[k] != expected[k] for k in ('sha256', 'bytes', 'mtime_ns', 'mode', 'uid', 'gid')):
            raise ValueError('Prewrite full backup changed')
    for name, expected in target['scratchTrees'].items():
        if base.effects.state(BACKUP / 'scratch' / name) != expected:
            raise ValueError('Preserved cache changed')
    for name, expected in target['failedHistoryRecords'].items():
        if retained.snapshot(VM / '.cfw-history' / name / 'transaction.json') != expected:
            raise ValueError('Prior failure record changed')
    for row in plan['protectedHostInputs'].values():
        if retained.snapshot(Path(row['backup'])) != row['backupState']:
            raise ValueError('Preserved SSH marker carrier changed')
    if plan['diagnosticHostInput'] is not None:
        actual = retained.snapshot(BACKUP / 'host-diagnostics/.vphone-runtime.json')
        if any(actual[k] != plan['diagnosticHostInput'][k] for k in ('sha256', 'bytes', 'mtime_ns', 'mode', 'uid', 'gid')):
            raise ValueError('Preserved prior runtime diagnostic changed')
    if (WORK / 'execution/preserved-source-before.json').exists():
        if source_inventory(PRESERVED if PRESERVED.exists() else PENDING) != read(WORK / 'execution/preserved-source-before.json'):
            raise ValueError('Complete preserved partial transaction changed')
    return dict(fullReadbackPassed=True, bootFiles=len(target['currentBootFiles']), protectedHostInputs=1,
        cacheTrees=sum(row['kind'] != 'missing' for row in target['scratchTrees'].values()), failedHistories=len(FAILED))


def inspect_phase(plan, phase):
    return base.inspect_phase(plan, plan['targets'][0], GENERATION, phase)[0]


def execute(plan, digest):
    configure(digest)
    if os.geteuid() != 0: raise ValueError('Administrator authentication required')
    base.approved(digest); base.verify_inputs(plan); base.verify_execution_inputs(); base.require_capacity(plan)
    (WORK / 'native-execution.claim').mkdir(mode=0o700)
    identity = subprocess.check_output(['/bin/ps', '-p', str(os.getpid()), '-o', 'uid=,lstart='], text=True,
        env=dict(os.environ, LC_ALL='C')).strip()
    base.save(WORK / 'native-root-identity.json', dict(pid=os.getpid(), uidAndStart=identity))
    out = WORK / 'execution'; out.mkdir(mode=0o755)
    result = dict(state='failed', VMStarts=0, securityWindows=0, deletionPerformed=False,
        repeatedFirstOn=0, repeatedUndoWrites=0, automaticRetry=False, automaticRollback=False, phaseTransactions={})
    timings = {}; env = base.runtime_environment(plan)
    def step(name, action):
        print('Starting ' + name, flush=True); t = time.monotonic()
        value = action(); timings[name] = time.monotonic() - t
        base.save(out / (name + '-timing.json'), dict(seconds=timings[name])); return value
    try:
        validate(plan); retained.previous.unrelated(plan)
        cli = Path(plan['installedCLI'])
        if any(p.exists() for p in (BACKUP, cli.parents[3], PRESERVED, NEW_WORK, VM / '.cfw-reboot-identity.json')):
            raise ValueError('Existing recovery output, Store or registration; no replay')
        if base.target_attachments(plan): raise ValueError('Target image already attached')
        step('source-preflight', lambda: base.baseline(plan))
        step('complete-backup', lambda: preserve(plan))
        base.run(plan['runtimeProbeCommand'], out / 'runtime-probe.log', env)
        if read(out / 'runtime-probe.log').get('ok') is not True: raise ValueError('Locked Python runtime refused')
        candidate = plan['candidate']; local = Path(candidate['bundle']) / 'Contents/MacOS/vphone-cli'
        base.run([local, 'core-bundle', 'install', '--version', candidate['version'], '--archive',
                  candidate['archive'], '--sha256', candidate['archiveSHA256']], out / 'store-install.log', env)
        base.run([cli, 'core-bundle', 'verify', '--version', candidate['version']], out / 'store-verify.log', env)
        if base.evidence.digest(cli) != candidate['cliSHA256']: raise ValueError('Installed CLI differs')
        step('register-and-preserve', lambda: register_and_preserve_source(plan, digest))
        base.run(plan['bindingCommand'], out / 'bind.log', env, identity=plan['sourceBootFiles']['config.plist'])
        if read(VM / 'launchpad.json') != plan['boundBeforeRecovery']: raise ValueError('Unrelated binding fields changed')
        exp = out / 'exp'; exp.mkdir()
        first = read(OLD_WORK / 'execution/exp/on.json')
        # Keep f430's historical producer; it must never be rewritten to the new candidate.
        verify_first_on(plan, first)
        base.save(exp / 'on.json', first); result['phaseTransactions']['on'] = FIRST
        base.approved(digest); base.verify_inputs(plan); base.verify_execution_inputs(); base.require_capacity(plan, initial=False)
        python = str(Path(plan['pythonRuntime']['venv']) / 'bin/python3')
        resources = cli.parent.parent / 'Resources/scripts'
        worker = Path(__file__).with_name('run_t33_recovered_undo.py')
        step('recovered-undo', lambda: base.run([python, resources / 'vm_lock.py', VM, 'cfw-record', '--',
            python, '-B', worker, '--plan', WORK / 'offline-plan.json', '--sha256', digest], exp / 'off.log', env))
        off = step('off-audit', lambda: inspect_phase(plan, 'off'))
        if off['transactionID'] != RECOVERY_ID: raise ValueError('Unexpected recovered publication')
        with base.audit.locked_vm(VM):
            archive, record, checkpoint, final = base.txn.committed_guest_evidence(VM)
            originals = base.file_originals.load(base.guest_undo.saved_plan(archive, GENERATION), archive / base.evidence.STORE)['members']
        base.verify_restored(plan['targets'][0], originals)
        base.save(exp / 'originals.json', {name: originals[name] for name in plan['targets'][0]['targets']})
        base.save(exp / 'off.json', off); result['phaseTransactions']['off'] = RECOVERY_ID
        base.approved(digest); base.verify_inputs(plan); base.verify_execution_inputs(); base.require_capacity(plan, initial=False)
        step('reapply', lambda: base.run(plan['installCommand'], exp / 'reapplied.log', env))
        reapplied = step('reapply-audit', lambda: inspect_phase(plan, 'reapplied'))
        base.save(exp / 'reapplied.json', reapplied); result['phaseTransactions']['reapplied'] = reapplied['transactionID']
        transition = base.transition(first['targets'], off['targets'], reapplied['targets'], originals, plan['targets'][0]['targets'])
        base.save(exp / 'transition.json', transition)
        result.update(state='offline-qualified-on-off-on-passed', transition=transition)
    except Exception as error:
        result['error'] = str(error)
    finally:
        try:
            result['baseline'] = base.baseline(plan); retained.previous.unrelated(plan)
            base.verify_inputs(plan); base.verify_execution_inputs()
            if (BACKUP / 'preservation.json').exists(): result['preservation'] = verify_preservation(plan)
            elif BACKUP.exists(): raise ValueError('Partial complete backup retained')
            result['targetAttachments'] = base.target_attachments(plan)
            if result['targetAttachments']: raise ValueError('Target attachment retained; no forced cleanup')
        except Exception as error:
            result.update(state='failed', preservationError=str(error))
        result['timings'] = timings; base.save(out / 'result.json', result)
        print(json.dumps(result), flush=True)
    return 0 if result['state'] == 'offline-qualified-on-off-on-passed' else 1


def verify_first_on(plan, report):
    old = read(OLD_WORK / 'offline-plan.json')
    if base.evidence.digest(OLD_WORK / 'offline-plan.json') != OLD_PLAN_SHA:
        raise ValueError('Historical approval plan changed')
    if report['transactionID'] != FIRST or report['generationID'] != GENERATION or report['phase'] != 'on':
        raise ValueError('Historical first-on association changed')
    audit = report['independentAudit']
    if (audit['passed'] is not True or audit['originQualified'] is not False
            or report['sourceReceipt']['originQualified'] is not True):
        raise ValueError('Historical independent target audit and qualified source receipt required')
    base.verify_origin(old, old['targets'][0], 'on', report['sourceReceipt'], report['binding'])


def prepare_executor(plan, digest):
    configure(digest); base.verify_inputs(plan)
    files = base.execution_inputs(plan)
    for path in Path(__file__).parent.glob('*t33*reboot*.py'):
        files[str(path.resolve(strict=True))] = base.evidence.digest(path)
    worker = Path(__file__).with_name('run_t33_recovered_undo.py')
    files[str(worker)] = base.evidence.digest(worker)
    for name in ('execute_t33_dev_overlay_acceptance.py', 'execute_t33_target_binding_acceptance.py',
                 'finalize_t33_target_binding_acceptance.py', 'test_t33_recovered_undo_worker.py'):
        path = Path(__file__).with_name(name); files[str(path)] = base.evidence.digest(path)
    base.save(WORK / 'executor-inputs.json', dict(planSHA256=digest, files=files))
    return dict(state='prepared-not-approved', planSHA256=digest, inputs=len(files))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--prepare-executor', action='store_true')
    group.add_argument('--execute-approved-plan')
    args = parser.parse_args()
    plan = validate(read(WORK / 'offline-plan.json')); digest = base.evidence.digest(WORK / 'offline-plan.json')
    if args.prepare_executor:
        print(json.dumps(prepare_executor(plan, digest))); return 0
    if args.execute_approved_plan != digest: raise ValueError('Wrong recovery plan digest')
    return execute(plan, digest)


if __name__ == '__main__':
    raise SystemExit(main())
