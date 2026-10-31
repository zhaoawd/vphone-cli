#!/usr/bin/env python3
"""Continue the named offline plan once, preserving its existing generation."""
import argparse
import json
import os
from pathlib import Path
import stat

import execute_t32_producer_acceptance as base

ROOT = base.ROOT
WORK = ROOT / '.build/t32-t33-completion-20261023/origin-identity-acceptance-20261024-r2'
PLAN_SHA = 'b98e0a565583ebd57380c5984be62ff0ed491fe499e7357c4d111c8fe5f87230'
base.WORK = WORK
base.APPROVED_SHA256 = PLAN_SHA
base.EXECUTOR_INPUTS = 'continuation-executor-inputs.json'


def plan_record():
    path = WORK / 'offline-plan.json'
    if base.evidence.digest(path) != PLAN_SHA:
        raise ValueError('Named continuation plan changed')
    plan = json.loads(base.evidence.read(path))
    if ([t['mode'] for t in plan['targets']] != ['reuse-existing-generation', 'fresh-copy-and-generation']
            or [t['variant'] for t in plan['targets']] != ['regular', 'exp']
            or plan['reuseLockedPythonRuntime'] is not True
            or any(plan[k] != 0 for k in ('VMStarts', 'normalGUIBoots', 'securityWindows'))
            or any(plan[k] is not False for k in ('automaticRetry', 'automaticRollback'))):
        raise ValueError('Continuation scope changed')
    return plan


def file_snapshot(path):
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


def existing_regular_locked(target):
    vm = Path(target['vm'])
    base.txn.require_unheld(vm / 'Disk.img', os.getpid(), 'continuation current disk')
    for name, expected in target['currentBootFiles'].items():
        if file_snapshot(vm / name) != expected:
            raise ValueError('Existing regular boot input changed: ' + name)
    if json.loads(base.evidence.read(vm / 'launchpad.json')) != target['expectedBinding']:
        raise ValueError('Existing regular binding changed')
    desired = json.loads(base.evidence.read(vm / '.firmware-desired-plan.json'))
    if desired['generationID'] != target['generationID'] or desired['plan']['variant'] != 'regular':
        raise ValueError('Existing generation or variant changed')
    committed = base.txn.committed_guest_evidence(vm)
    if (committed is None or committed[2]['generationID'] != target['generationID']
            or base.evidence.digest(committed[0] / base.evidence.PLAN) != target['expectedDesiredSHA256']):
        raise ValueError('Existing publication or saved plan changed')
    saved = json.loads(base.evidence.read(committed[0] / base.evidence.PLAN))
    if any(desired[k] != saved[k] for k in ('generationID', 'planSHA256', 'plan', 'identity')):
        raise ValueError('Live desired plan differs from saved publication')
    return {name: file_snapshot(vm / name) for name in target['beforeWriteBackupFiles']}


def preflight(plan):
    capacity = base.require_capacity(plan)
    base.verify_inputs(plan)
    regular, experimental = plan['targets']
    for name in (regular['beforeWriteBackup'], experimental['vm'], experimental['firstBindingBackup'],
                 str(base.store_cli(plan).parents[3]), str(WORK / 'execution')):
        if os.path.lexists(name):
            raise ValueError('Preserve existing continuation output: ' + name)
    runtime = Path(plan['pythonRuntime']['root'])
    if runtime.resolve(strict=True) != runtime or not runtime.is_dir():
        raise ValueError('Existing locked runtime is missing or linked; do not provision')
    if base.target_attachments(plan):
        raise ValueError('Target disk already attached')
    baseline = base.baseline(plan)
    with base.audit.locked_vm(Path(regular['vm'])):
        current = existing_regular_locked(regular)
    return dict(capacity=capacity, baseline=baseline, currentRegularFiles=current)


def backup_regular(target, expected):
    vm = Path(target['vm']); destination = Path(target['beforeWriteBackup'])
    with base.audit.locked_vm(vm):
        if existing_regular_locked(target) != expected:
            raise ValueError('Current regular input changed before backup')
        destination.mkdir(mode=0o700)
        for name in target['beforeWriteBackupFiles']:
            base.clone_file(vm / name, destination / name)
            copied = file_snapshot(destination / name)
            if (copied['ino'] == expected[name]['ino'] or any(copied[k] != expected[name][k]
                    for k in ('sha256', 'bytes', 'mtime_ns', 'mode', 'uid', 'gid'))):
                raise ValueError('Complete independent backup differs: ' + name)
        if existing_regular_locked(target) != expected:
            raise ValueError('Source changed while backing up regular')
    return dict(path=str(destination), files=expected, fullReadbackPassed=True)


def verify_backup(record):
    for name, expected in record['files'].items():
        copied = file_snapshot(Path(record['path']) / name)
        if any(copied[k] != expected[k] for k in ('sha256', 'bytes', 'mtime_ns', 'mode', 'uid', 'gid')):
            raise ValueError('Preserved pre-write backup changed: ' + name)


def probe_runtime(plan, out, env):
    runtime = plan['pythonRuntime']
    probe = Path(plan['candidate']['bundle']) / 'Contents/Resources/scripts/check_python_runtime.py'
    base.run([Path(runtime['venv']) / 'bin/python3', probe, '--locked', '--json'], out / 'runtime-probe.log', env)
    report = json.loads((out / 'runtime-probe.log').read_text())
    if report.get('ok') is not True:
        raise ValueError('Existing locked runtime failed its capability/lock probe')


def run_regular(plan, target, out, env):
    out.mkdir()
    owner = plan['sourceBootFiles']['config.plist']
    base.run(plan['regularBindingCommand'], out / 'bind.log', env, identity=owner)
    binding = json.loads(base.evidence.read(Path(target['vm']) / 'launchpad.json'))
    expected = dict(target['expectedBinding'], bundle=plan['candidate']['version'])
    if binding != expected:
        raise ValueError('Host binding changed unrelated component origins')
    observations = []; catalog = None
    for phase, argv in [('on', target['installCommand']), ('off', target['undoCommand']),
                        ('reapplied', target['installCommand'])]:
        base.approved(PLAN_SHA); base.verify_execution_inputs(); base.verify_inputs(plan)
        base.require_capacity(plan, initial=False)
        base.run(argv, out / (phase + '.log'), env)
        saved, originals = base.inspect_phase(plan, target, target['generationID'], phase)
        if phase == 'on':
            catalog = originals
        elif phase == 'off':
            base.verify_restored(target, catalog)
        base.save(out / (phase + '.json'), saved); observations.append(saved)
    transition = base.transition(*(row['targets'] for row in observations), catalog, target['targets'])
    base.save(out / 'transition.json', transition)
    return dict(vm=target['vm'], generationID=target['generationID'],
                phases=[row['transactionID'] for row in observations], transition=transition)


def execute(plan):
    if os.geteuid() != 0:
        raise ValueError('Native administrator authentication required')
    base.approved(PLAN_SHA); base.verify_execution_inputs()
    checked = preflight(plan)
    out = WORK / 'execution'; out.mkdir(mode=0o755)
    result = dict(state='failed', VMStarts=0, securityWindows=0, originalVMWritten=False, targets=[])
    backup = None
    env = base.runtime_environment(plan)
    try:
        # Preserve the existing disk and binding before installing or rebinding.
        regular, experimental = plan['targets']
        backup = backup_regular(regular, checked['currentRegularFiles'])
        base.save(out / 'regular-before-write-backup.json', backup)
        probe_runtime(plan, out, env)
        base.run(plan['installCommand'], out / 'store-install.log', env)
        base.run(plan['verifyCommand'], out / 'store-verify.log', env)
        if base.evidence.digest(base.store_cli(plan)) != plan['candidate']['cliSHA256']:
            raise ValueError('Installed CLI differs from fixed candidate')
        result['targets'].append(run_regular(plan, regular, out / 'regular', env))
        result['targets'].append(base.run_target(plan, experimental, out / 'exp', env))
        result['state'] = 'offline-qualified-on-off-on-passed'
    except Exception as error:
        result['error'] = str(error)
    finally:
        try:
            result['baseline'] = base.baseline(plan)
            base.verify_inputs(plan); base.verify_execution_inputs()
            if backup is not None:
                verify_backup(backup); result['regularBeforeWriteBackupVerified'] = True
            result['targetAttachments'] = base.target_attachments(plan)
            if result['targetAttachments']:
                raise ValueError('Target attachment retained; no force cleanup')
        except Exception as error:
            result['state'] = 'failed'; result['preservationOrCleanupError'] = str(error)
        base.save(out / 'result.json', result)
        print(json.dumps(result), flush=True)
    return 0 if result['state'] == 'offline-qualified-on-off-on-passed' else 1


def executor_inputs(plan):
    files = base.execution_inputs(plan)
    for path in (Path(__file__), Path(__file__).with_name('test_t32_origin_identity_acceptance.py')):
        files[str(path.resolve(strict=True))] = base.evidence.digest(path)
    return dict(planSHA256=PLAN_SHA, files=files)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--prepare-executor', action='store_true')
    group.add_argument('--execute-approved-plan')
    args = parser.parse_args(); plan = plan_record()
    if args.prepare_executor:
        base.verify_inputs(plan); capacity = base.require_capacity(plan)
        base.save(WORK / base.EXECUTOR_INPUTS, executor_inputs(plan))
        print(json.dumps(dict(state='executor-prepared', capacity=capacity,
                              frozenInputsVerified=len(plan['frozenInputs']), VMStarts=0, securityWindows=0)))
        return 0
    if args.execute_approved_plan != PLAN_SHA:
        raise ValueError('Wrong continuation plan digest')
    return execute(plan)


if __name__ == '__main__':
    raise SystemExit(main())
