"""One approved EXP continuation on the unpublished generation; never boot or retry."""
import argparse
import json
import os
from pathlib import Path
import stat

import execute_t33_target_binding_acceptance as previous

base = previous.base
ROOT = base.ROOT
BASE = ROOT / '.build/t32-t33-completion-20261023'
WORK = BASE / 'exp-dev-overlay-acceptance-20261025'
VM = ROOT / '.build/t33t-20261025'
GENERATION = 'e45c2fedee57f70b05bf7e4fe8fc6946b21b0aded7dadf4f66760f0304274308'
VERSION = '2.6.2-local.e12747163c76'
ARCHIVE_SHA = 'cb4b43687285a78bfeeb010333c6f3fca06c326052f0d8e232b06f3e88d8e7fc'
CLI = Path('/Library/Application Support/vphone-launchpad/Bundles') / VERSION / 'VPhone.bundle/Contents/MacOS/vphone-cli'
BACKUP = BASE / 't33t-before-dev-overlay-20261025'
SCRATCH = ('cfw_input', 'cfw_jb_input', '.cfw_temp')
READONLY = BASE / 'dev-overlay-reuse-preparation-20261025/readonly-inspection.json'


def commands(binding_sha):
    common = [VM.name, '--library-root', str(VM.parent)]
    return dict(
        installCommand=[str(CLI), 'cfw', 'install', *common, '--variant', 'exp', '--qualify-origin',
                        '--keep-artifacts', '--work-parent', '/private/tmp', '--spoof-build', '23Z999999'],
        undoCommand=[str(CLI), 'cfw', 'undo', *common, '--generation', GENERATION,
                     '--declaration', 'system-systemversion-cfw-build_version'],
        bindingCommand=[str(CLI), 'vm', 'bind-core-bundle', *common, '--version', VERSION,
                        '--expected-binding-sha256', binding_sha])


def validate(plan):
    target, = plan['targets']
    candidate = plan['candidate']
    if (target['vm'] != str(VM) or target['mode'] != 'reuse-unpublished-exp-generation'
            or target['variant'] != 'exp' or target['generationID'] != GENERATION
            or target['targets'] != previous.TARGETS
            or target['declarations'] != ['system-systemversion-cfw-build_version']
            or target['beforeWriteBackup'] != str(BACKUP)
            or set(target['scratchTrees']) - set(SCRATCH)
            or set(target['currentBootFiles']) != set(plan['sourceBootFiles']) | {'launchpad.json', '.firmware-desired-plan.json'}
            or not target['priorFailedTransactions']
            or candidate['version'] != VERSION or candidate['archiveSHA256'] != ARCHIVE_SHA
            or candidate['targetRulesSHA256'] != previous.RULES
            or plan['minimumInitialFreeBytes'] != 75 * 1024**3
            or plan['minimumEachCFWFreeBytes'] != 50 * 1024**3
            or plan['reuseLockedPythonRuntime'] is not True
            or any(plan[k] != 0 for k in ('VMStarts', 'normalGUIBoots', 'securityWindows'))
            or any(plan[k] is not False for k in ('automaticRetry', 'automaticRollback', 'additionalDeletionAllowed'))):
        raise ValueError('Unpublished EXP continuation scope changed')
    expected = commands(target['currentBootFiles']['launchpad.json']['sha256'])
    if any(target[key] != value for key, value in expected.items()):
        raise ValueError('Continuation command changed')
    return plan


def snapshot(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise ValueError('Backup input is linked or special: ' + str(path))
        result = dict(sha256=base.evidence.digest(path), bytes=before.st_size, dev=before.st_dev,
                      ino=before.st_ino, mtime_ns=before.st_mtime_ns,
                      mode=stat.S_IMODE(before.st_mode), uid=before.st_uid, gid=before.st_gid)
        base.evidence.unchanged(path, fd, before)
        return result
    finally:
        os.close(fd)


def history(target):
    """Freeze failed transaction records; do not claim full failed-artifact hashes."""
    result = {}
    root = VM / '.cfw-history'
    for path in sorted(root.iterdir()):
        if path.is_symlink() or not path.is_dir():
            raise ValueError('Unexpected history member')
        record = json.loads(base.evidence.read(path / 'transaction.json'))
        if record['status'] != 'failed' or record['id'] != path.name:
            raise ValueError('Target history is pending or published')
        result[path.name] = snapshot(path / 'transaction.json')
    if set(result) != set(target['priorFailedTransactions']):
        raise ValueError('Failed transaction set changed')
    return result


def existing_locked(target):
    base.txn.require_unheld(VM / 'Disk.img', os.getpid(), 'unpublished EXP continuation')
    actual = {name: snapshot(VM / name) for name in target['currentBootFiles']}
    if actual != target['currentBootFiles']:
        raise ValueError('Unpublished boot, binding or desired input changed')
    desired = json.loads(base.evidence.read(VM / '.firmware-desired-plan.json'))
    if desired['generationID'] != GENERATION or desired['plan']['variant'] != 'exp':
        raise ValueError('Unpublished generation or variant changed')
    if json.loads(base.evidence.read(VM / 'launchpad.json')) != target['expectedBinding']:
        raise ValueError('Unpublished binding changed')
    if base.txn.committed_guest_evidence(VM) is not None:
        raise ValueError('A committed guest cannot use this continuation')
    if history(target) != target['historyRecords']:
        raise ValueError('Failed transaction records changed')
    for name in SCRATCH:
        if base.effects.state(VM / name) != target['scratchTrees'].get(name, {'kind': 'missing'}):
            raise ValueError('Rebuildable input changed: ' + name)
    return actual


def configure(digest):
    base.WORK = WORK
    base.APPROVED_SHA256 = digest
    base.EXECUTOR_INPUTS = 'executor-inputs.json'


def preflight(plan, digest):
    validate(plan)
    base.approved(digest)
    base.require_capacity(plan)
    if 'retirement' in plan:
        retired = json.loads(base.evidence.read(WORK / 'retirement/result.json'))
        names = [row['path'] for row in plan['retirement']['retirementTargets']]
        if (retired.get('state') != 'completed' or retired.get('planSHA256') != digest
                or retired.get('removed') != names or any(os.path.lexists(ROOT / name) for name in names)):
            raise ValueError('Approved retirement did not complete')
    base.verify_inputs(plan)
    base.verify_execution_inputs()
    previous.unrelated(plan)
    if any(os.path.lexists(p) for p in (BACKUP, CLI.parents[3], WORK / 'execution')):
        raise ValueError('Preserve existing backup, Store or execution; no replay')
    if base.target_attachments(plan):
        raise ValueError('Target already attached')
    runtime = Path(plan['pythonRuntime']['root'])
    if runtime.resolve(strict=True) != runtime or not runtime.is_dir():
        raise ValueError('Locked runtime unavailable')
    retained = base.baseline(plan)
    with base.audit.locked_vm(VM):
        existing_locked(plan['targets'][0])
    return retained


def preserve_before_write(target):
    """Keep complete boot/binding inputs and rename caches without deleting them."""
    with base.audit.locked_vm(VM):
        expected = existing_locked(target)
        BACKUP.mkdir(mode=0o700)
        boot = BACKUP / 'boot'; boot.mkdir(mode=0o700)
        for name, value in expected.items():
            base.clone_file(VM / name, boot / name)
            actual = snapshot(boot / name)
            if actual['ino'] == value['ino'] or any(actual[k] != value[k] for k in
                    ('sha256', 'bytes', 'mtime_ns', 'mode', 'uid', 'gid')):
                raise ValueError('Independent pre-write backup differs: ' + name)
        # Recheck everything before the first VM-directory change.
        existing_locked(target)
        caches = BACKUP / 'scratch'; caches.mkdir(mode=0o700)
        base.save(BACKUP / 'preservation-intent.json', dict(files=expected,
                  scratchTrees=target['scratchTrees'], historyRecords=target['historyRecords']))
        for name, value in target['scratchTrees'].items():
            base.txn.move_exclusive(VM / name, caches / name)
            if base.effects.state(caches / name) != value:
                raise ValueError('Preserved scratch differs: ' + name)
            base.save(BACKUP / ('moved-' + name + '.json'), dict(name=name, preserved=True))
        record = dict(path=str(BACKUP), files=expected, scratchTrees=target['scratchTrees'],
                      historyRecords=target['historyRecords'], fullReadbackPassed=True)
        base.save(BACKUP / 'preservation.json', record)
        return record


def verify_preservation(target, record):
    for name, expected in record['files'].items():
        actual = snapshot(BACKUP / 'boot' / name)
        if any(actual[k] != expected[k] for k in ('sha256', 'bytes', 'mtime_ns', 'mode', 'uid', 'gid')):
            raise ValueError('Preserved boot input changed: ' + name)
    for name, expected in record['scratchTrees'].items():
        if base.effects.state(BACKUP / 'scratch' / name) != expected:
            raise ValueError('Preserved scratch changed: ' + name)
    for name, expected in record['historyRecords'].items():
        if snapshot(VM / '.cfw-history' / name / 'transaction.json') != expected:
            raise ValueError('Prior failed transaction changed: ' + name)


def run_target(plan, target, out, env, digest):
    out.mkdir()
    owner = plan['sourceBootFiles']['config.plist']
    base.run(target['bindingCommand'], out / 'bind.log', env, identity=owner)
    expected = dict(target['expectedBinding'], bundle=VERSION)
    if json.loads(base.evidence.read(VM / 'launchpad.json')) != expected:
        raise ValueError('Binding changed unrelated component origins')
    base.run([str(CLI), 'cfw', 'verify-plan', str(VM), '--expected-sha256',
              target['currentBootFiles']['.firmware-desired-plan.json']['sha256']], out / 'verify-plan.log', env)
    observations = []; originals = None
    for phase, argv in [('on', target['installCommand']), ('off', target['undoCommand']),
                        ('reapplied', target['installCommand'])]:
        base.approved(digest); base.verify_inputs(plan); base.verify_execution_inputs()
        base.require_capacity(plan, initial=False)
        base.run(argv, out / (phase + '.log'), env)
        saved, catalog = base.inspect_phase(plan, target, GENERATION, phase)
        if phase == 'on': originals = catalog
        elif phase == 'off': base.verify_restored(target, originals)
        base.save(out / (phase + '.json'), saved); observations.append(saved)
    result = base.transition(*(r['targets'] for r in observations), originals, target['targets'])
    base.save(out / 'transition.json', result)
    return dict(vm=str(VM), generationID=GENERATION, phases=[r['transactionID'] for r in observations], transition=result)


def execute(plan, digest):
    if os.geteuid() != 0:
        raise ValueError('Native administrator authentication required')
    preflight(plan, digest)
    out = WORK / 'execution'; out.mkdir(mode=0o755)
    result = dict(state='failed', VMStarts=0, securityWindows=0, originalVMWritten=False,
                  deletionPerformed=False, targets=[])
    record = None; target = plan['targets'][0]; env = base.runtime_environment(plan)
    try:
        record = preserve_before_write(target)
        base.save(out / 'before-write-backup.json', record)
        base.run(plan['runtimeProbeCommand'], out / 'runtime-probe.log', env)
        if json.loads((out / 'runtime-probe.log').read_bytes()).get('ok') is not True:
            raise ValueError('Locked runtime probe failed')
        candidate = plan['candidate']; local = Path(candidate['bundle']) / 'Contents/MacOS/vphone-cli'
        base.require_capacity(plan, initial=False)
        base.run([local, 'core-bundle', 'install', '--version', VERSION,
                  '--archive', candidate['archive'], '--sha256', ARCHIVE_SHA], out / 'store-install.log', env)
        base.run([CLI, 'core-bundle', 'verify', '--version', VERSION], out / 'store-verify.log', env)
        if base.evidence.digest(CLI) != candidate['cliSHA256']:
            raise ValueError('Installed candidate CLI differs')
        result['targets'].append(run_target(plan, target, out / 'exp', env, digest))
        result['state'] = 'offline-qualified-on-off-on-passed'
    except Exception as error:
        result['error'] = str(error)
    finally:
        try:
            result['baseline'] = base.baseline(plan)
            previous.unrelated(plan); base.verify_inputs(plan); base.verify_execution_inputs()
            if record is not None:
                verify_preservation(target, record); result['beforeWriteBackupVerified'] = True
            elif BACKUP.exists():
                raise ValueError('Partial pre-write backup retained; inspect before any new plan')
            result['targetAttachments'] = base.target_attachments(plan)
            if result['targetAttachments']:
                raise ValueError('Target attachment retained; no forced cleanup')
        except Exception as error:
            result['state'] = 'failed'; result['preservationOrCleanupError'] = str(error)
        base.save(out / 'result.json', result)
        print(json.dumps(result), flush=True)
    return 0 if result['state'] == 'offline-qualified-on-off-on-passed' else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--prepare-executor', action='store_true')
    group.add_argument('--execute-approved-plan')
    args = parser.parse_args()
    plan = validate(json.loads(base.evidence.read(WORK / 'offline-plan.json')))
    digest = base.evidence.digest(WORK / 'offline-plan.json'); configure(digest)
    if args.prepare_executor:
        base.verify_inputs(plan)
        inputs = base.execution_inputs(plan)
        for name in ('execute_t33_target_binding_acceptance.py', 'execute_t33_dev_overlay_acceptance.py',
                     'prepare_t33_dev_overlay_acceptance.py', 'test_t33_dev_overlay_acceptance.py',
                     'retire_t33_dev_overlay_states.py', 'test_t33_dev_overlay_retirement.py',
                     'finalize_t33_dev_overlay_acceptance.py'):
            path = Path(__file__).with_name(name)
            inputs[str(path.resolve(strict=True))] = base.evidence.digest(path)
        storage = ROOT / 'research/retire_t32_t33_states_20261025.py'
        inputs[str(storage)] = base.evidence.digest(storage)
        base.save(WORK / 'executor-inputs.json', dict(planSHA256=digest, files=inputs))
        print(json.dumps(dict(state='prepared-not-approved', planSHA256=digest, inputs=len(inputs))))
        return 0
    if args.execute_approved_plan != digest:
        raise ValueError('Wrong continuation plan digest')
    return execute(plan, digest)


if __name__ == '__main__':
    raise SystemExit(main())
