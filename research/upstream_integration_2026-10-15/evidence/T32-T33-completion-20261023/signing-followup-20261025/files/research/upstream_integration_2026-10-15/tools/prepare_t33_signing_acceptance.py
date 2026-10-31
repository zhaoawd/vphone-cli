#!/usr/bin/env python3
"""Freeze a new EXP-only plan without replaying the failed execution."""
import copy
import json
import os
from pathlib import Path

import execute_t33_signing_acceptance as entry

runner = entry.runner
ROOT = runner.ROOT
BASE = ROOT / '.build/t32-t33-completion-20261023'


def main():
    prior_work = BASE / 'exp-target-binding-acceptance-20261025'
    prior = json.loads((prior_work / 'offline-plan.json').read_bytes())
    outcome = json.loads((prior_work / 'execution/result.json').read_bytes())
    if (outcome.get('state') != 'failed' or outcome.get('targetAttachments') != []
            or outcome.get('baseline') != dict(files=10, fullReadbackPassed=True)
            or outcome.get('preservationOrCleanupError')):
        raise ValueError('Prior execution requires preservation/cleanup investigation')
    candidate = json.loads((BASE / 'candidate-exp-signing-20261025-r2.json').read_bytes())
    target = copy.deepcopy(prior['targets'][0])
    previous_cli = target['installCommand'][0]
    cli = str(Path(previous_cli).parents[3].parent / candidate['version'] / 'VPhone.bundle/Contents/MacOS/vphone-cli')
    previous_name = Path(target['vm']).name
    for key in ('generationCommand', 'installCommand', 'undoCommand'):
        target[key] = [cli if value == previous_cli else entry.VM.name if value == previous_name else value
                       for value in target[key]]
    target.update(vm=str(entry.VM), firstBindingBackup=str(BASE / 't33t-first-binding-20261025'))
    if any(Path(path).exists() for path in (entry.VM, target['firstBindingBackup'], entry.WORK,
                                           Path(cli).parents[3])):
        raise ValueError('Preserve existing target, backup, plan or Store')
    plan = {key: copy.deepcopy(prior[key]) for key in ('sourceBackup', 'sourceBootFiles', 'pythonRuntime',
            'minimumInitialFreeBytes', 'minimumEachCFWFreeBytes', 'expectedPrebootTarget', 'unexpectedPrebootPolicy',
            'signatureAcceptance', 'preserve', 'cleanup')}
    inputs = {}
    def freeze(path):
        path = Path(path).resolve(strict=True)
        inputs[str(path)] = runner.base.evidence.digest(path)
    for option in ('--iphone-source', '--cloudos-source', '--boot-rom-source'):
        argv = target['generationCommand']
        freeze(argv[argv.index(option) + 1])
    for path in Path(candidate['bundle']).rglob('*'):
        if path.is_file():
            freeze(path)
    for path in (candidate['archive'], BASE / 'candidate-exp-signing-20261025-r2.json', Path(__file__),
                 Path(entry.__file__), Path(runner.__file__),
                 Path(__file__).with_name('test_t33_target_binding_acceptance.py'),
                 prior_work / 'execution/result.json', prior_work / 'execution/exp/on.log'):
        freeze(path)
    identities = copy.deepcopy(prior['unrelatedDiskIdentities'])
    old_vm = Path(prior['targets'][0]['vm'])
    info = (old_vm / 'Disk.img').stat()
    identities[str((old_vm / 'Disk.img').relative_to(ROOT))] = dict(dev=info.st_dev, ino=info.st_ino, size=info.st_size)
    for name, expected in identities.items():
        info = (ROOT / name).stat()
        if dict(dev=info.st_dev, ino=info.st_ino, size=info.st_size) != expected:
            raise ValueError('Preserved disk identity changed: ' + name)
    capacity = os.statvfs(ROOT)
    available = capacity.f_bavail * capacity.f_frsize
    plan.update(schemaVersion=1, scope='fresh EXP classic signing and cached Cryptex transport acceptance',
        candidate=candidate, targets=[target], frozenInputs=inputs, unrelatedDiskIdentities=identities,
        priorPlanSHA256=runner.base.evidence.digest(prior_work / 'offline-plan.json'), priorFailurePreserved=True,
        VMStarts=0, normalGUIBoots=0, securityWindows=0, automaticRetry=False, automaticRollback=False,
        reuseLockedPythonRuntime=True, regularCFWRepeated=False, runtimeValidated=False,
        runtimeProbeCommand=[str(Path(plan['pythonRuntime']['venv']) / 'bin/python3'),
            str(Path(candidate['bundle']) / 'Contents/Resources/scripts/check_python_runtime.py'), '--locked', '--json'],
        observedAvailableBytes=available, initialCapacityPassed=available >= plan['minimumInitialFreeBytes'],
        authorization='not approved; new Store candidate installation and named EXP writes require confirmation')
    runner.VM = entry.VM
    runner.validate(plan)
    entry.WORK.mkdir()
    runner.base.save(entry.WORK / 'offline-plan.json', plan)
    print(json.dumps(dict(state='prepared-not-approved', planSHA256=runner.base.evidence.digest(entry.WORK / 'offline-plan.json'),
        frozenInputs=len(inputs), preservedDisks=len(identities), availableBytes=available,
        capacityPassed=plan['initialCapacityPassed'])))


if __name__ == '__main__':
    main()
