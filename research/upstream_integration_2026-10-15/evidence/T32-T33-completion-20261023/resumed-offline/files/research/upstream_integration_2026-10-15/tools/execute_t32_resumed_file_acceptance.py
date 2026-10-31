#!/usr/bin/env python3
"""One separately approved continuation on the retained fresh-generation copy."""
import argparse
import importlib.util
import json
import os
import stat
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / '.build/t32-t33-completion-20261023'
sys.path.insert(0, str(ROOT / 'scripts'))
import cfw_guest_evidence as evidence
import cfw_disk_txn as txn
import cfw_verify_effects as audit
from patchers import file_originals, guest_undo, component_effects as effects

spec = importlib.util.spec_from_file_location('prior_acceptance', Path(__file__).with_name('execute_t32_file_acceptance.py'))
prior = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prior)


def approved(expected):
    path = WORK / 'resumed-file-acceptance-plan.json'
    if evidence.digest(path) != expected:
        raise ValueError('Continuation plan changed')
    approval = json.loads(evidence.read(WORK / 'resumed-file-acceptance-approval.json'))
    if approval != dict(approved=True, planSHA256=expected):
        raise ValueError('Separate continuation approval required')
    plan = json.loads(evidence.read(path))
    if plan['VMStarts'] != 0 or plan['securityWindows'] != 0 or plan['automaticRetry'] is not False:
        raise ValueError('Continuation scope changed')
    if Path(plan['python']).resolve(strict=True) != Path(plan['pythonResolved']):
        raise ValueError('Interpreter changed')
    for name, digest in plan['frozenInputs'].items():
        if evidence.digest(Path(name)) != digest:
            raise ValueError('Frozen input changed: ' + name)
    return plan


def verify_files(directory, expected, identities):
    observed = {}
    with audit.locked_vm(directory):
        txn.require_unheld(directory / 'Disk.img', os.getpid(), 'acceptance baseline disk')
        for name, digest in expected.items():
            info = (directory / name).lstat()
            identity = dict(dev=info.st_dev, ino=info.st_ino, size=info.st_size,
                            mtime_ns=info.st_mtime_ns, mode=stat.S_IMODE(info.st_mode),
                            uid=info.st_uid, gid=info.st_gid)
            if identity != identities[name]:
                raise ValueError('Persistent boot identity changed: ' + str(directory / name))
            observed[name] = evidence.digest(directory / name)
            if observed[name] != digest:
                raise ValueError('Persistent boot state changed: ' + str(directory / name))
    return observed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--execute-approved-plan', required=True)
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise ValueError('Native administrator authentication required')
    plan = approved(args.execute_approved_plan)
    vm, source = Path(plan['vm']), Path(plan['sourceVM'])
    out = WORK / 'resumed-offline-acceptance'
    if out.exists():
        raise ValueError('Preserve the prior continuation; no automatic retry')
    out.mkdir(mode=0o755)
    os.chown(out, 501, 20)
    result = dict(state='failed', sourceVMWritten=False, VMStarted=False, securityWindowStarted=False, phases=[])
    try:
        print('Verifying complete original and retained-copy boot state', flush=True)
        verify_files(source, plan['originalBootSHA256'], plan['originalBootIdentity'])
        verify_files(vm, plan['freshBootSHA256'], plan['freshBootIdentity'])
        desired_raw = evidence.read(vm / '.firmware-desired-plan.json')
        desired = json.loads(desired_raw)
        generation = desired['generationID']
        if generation != plan['generationID'] or desired['planSHA256'] != plan['expectedPlanSHA256']:
            raise ValueError('Retained fresh generation or semantic plan changed')
        manifest = json.loads(evidence.read(vm / '.firmware-generations' / generation / 'manifest.json'))
        if manifest['content']['source']['archiveSHA256'] != plan['archiveSHA256']:
            raise ValueError('Retained fresh archive association changed')
        # The actual CLI requalifies the complete generation and disk identity
        # before creating its transaction; no saved JSON grants producer scope.
        result.update(generationID=generation, initialDesiredSHA256=evidence.digest(vm / '.firmware-desired-plan.json'))
        env = dict(os.environ, VPHONE_PYTHON=plan['python'], VPHONE_ROOT=str(WORK / 'fresh-runtime-cache'),
                   SUDO_UID='501', SUDO_GID='20', PYTHONDONTWRITEBYTECODE='1')
        for key in ('VPHONE_VM_LOCK_FD', 'VPHONE_FROZEN_PLAN', 'VPHONE_FROZEN_PLAN_SHA256',
                    'VPHONE_FROZEN_CONTEXT', 'VPHONE_GUEST_EVIDENCE', 'CFW_HOST_MNT', 'VPHONE_DECLARATION_ID'):
            env.pop(key, None)
        cli = plan['cliExecutable']
        common = ['--library-root', str(vm.parent), vm.name]
        install = [cli, 'cfw', 'install', *common, '--variant', 'regular', '--keep-artifacts',
                   '--reinstall-cryptex', '--work-parent', '/private/tmp']
        undo = [cli, 'cfw', 'undo', *common, '--generation', generation, '--declaration', *plan['declarations']]
        first = originals = restored = None
        for phase, command in [('on', install), ('off', undo), ('reapplied', install)]:
            approved(args.execute_approved_plan)
            print('Starting phase: ' + phase, flush=True)
            with (out / (phase + '.log')).open('xb') as log:
                subprocess.run(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
            print('Independent readonly audit: ' + phase, flush=True)
            with audit.locked_vm(vm):
                observation = audit.audit_locked(vm, Path('/private/tmp'))
                if not observation['passed']:
                    raise ValueError('Strict current-target audit failed: ' + phase)
                archive, journal, checkpoint, final = txn.committed_guest_evidence(vm)
                if checkpoint['generationID'] != generation:
                    raise ValueError('Published generation differs')
                states = {row['target']: row['state'] for row in final['outputs'] if row['target'] in plan['targets']}
                if phase == 'on':
                    selection = guest_undo.preview(vm, generation, plan['declarations'])
                    if {entry['target'] for entry in selection['entries']} != set(plan['targets']):
                        raise ValueError('Different complete Undo target set')
                    originals = file_originals.load(guest_undo.saved_plan(archive, generation), archive / evidence.STORE)['members']
                    first = states
                elif phase == 'off':
                    restored = states
                    with audit.readonly_roots(vm / 'Disk.img', {'system'}, Path('/private/tmp')) as (roots, recheck):
                        for target in plan['targets']:
                            path = audit.installed_effects.target_path(target, roots)
                            if effects.state(path, False) != originals[target]['state']:
                                raise ValueError('Complete restored original differs: ' + target)
                            file_originals.code_pages(path, originals[target]['kind'])
                        recheck()
                else:
                    result['transition'] = prior.transition(first, restored, states, originals, plan['targets'])
                saved = dict(phase=phase, transactionID=journal['id'], generationID=generation,
                             targets=states, audit=observation)
                destination = out / (phase + '.json')
                evidence.write_new(destination, json.dumps(saved, indent=2).encode() + b'\n')
                os.chown(destination, 501, 20)
                result['phases'].append(dict(name=phase, transactionID=journal['id']))
            print('Phase passed: ' + phase, flush=True)
        verify_files(source, plan['originalBootSHA256'], plan['originalBootIdentity'])
        result['state'] = 'resumed-offline-on-off-on-passed'
    except Exception as error:
        result['error'] = str(error)
    finally:
        destination = out / 'result.json'
        evidence.write_new(destination, json.dumps(result, indent=2).encode() + b'\n')
        os.chown(destination, 501, 20)
    print(json.dumps(result), flush=True)
    return 0 if result['state'] == 'resumed-offline-on-off-on-passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
