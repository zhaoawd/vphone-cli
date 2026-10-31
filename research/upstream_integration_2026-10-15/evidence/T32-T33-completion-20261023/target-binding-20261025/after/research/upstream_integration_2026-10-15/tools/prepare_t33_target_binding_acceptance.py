#!/usr/bin/env python3
"""Prepare a fresh EXP plan; retain earlier plans and all disk states."""
import copy
import json
import os
from pathlib import Path

import execute_t33_target_binding_acceptance as runner

ROOT=runner.ROOT
BASE=ROOT/'.build/t32-t33-completion-20261023'


def main():
    prior=json.loads((BASE/'origin-identity-acceptance-20261024-r2/offline-plan.json').read_bytes())
    candidate=json.loads((BASE/'candidate-exp-target-binding-20261025.json').read_bytes())
    preserved=json.loads((BASE/'origin-identity-acceptance-20261024-r2/unrelated-disk-identities-before.json').read_bytes())
    target=copy.deepcopy(prior['targets'][1])
    previous_cli=target['installCommand'][0]
    cli=str(Path(previous_cli).parents[3].parent/candidate['version']/'VPhone.bundle/Contents/MacOS/vphone-cli')
    previous_name=Path(target['vm']).name
    for key in ('generationCommand','installCommand','undoCommand'):
        target[key]=[cli if value==previous_cli else runner.VM.name if value==previous_name else value
                     for value in target[key]]
    target.update(vm=str(runner.VM),firstBindingBackup=str(BASE/'t33s-first-binding-20261025'),
                  targets=list(runner.TARGETS),mode='fresh-copy-and-generation')
    plan={key:copy.deepcopy(prior[key]) for key in ('sourceBackup','sourceBootFiles','pythonRuntime')}
    inputs={}
    def freeze(path):
        path=Path(path).resolve(strict=True);inputs[str(path)]=runner.base.evidence.digest(path)
    for option in ('--iphone-source','--cloudos-source','--boot-rom-source'):
        args=target['generationCommand'];freeze(args[args.index(option)+1])
    for path in Path(candidate['bundle']).rglob('*'):
        if path.is_file():freeze(path)
    for path in (candidate['archive'],ROOT/'scripts/patchers/guest-targets.json',
                 ROOT/'scripts/cfw_install_exp.sh',BASE/'candidate-exp-target-binding-20261025.json',Path(__file__),
                 Path(runner.__file__),Path(runner.__file__).with_name('test_t33_target_binding_acceptance.py')):
        freeze(path)
    for vm in (ROOT/'.build/t32q-20261024',ROOT/'.build/t33q-20261024'):
        info=(vm/'Disk.img').stat()
        preserved[str((vm/'Disk.img').relative_to(ROOT))]=dict(dev=info.st_dev,ino=info.st_ino,size=info.st_size)
    info=os.statvfs(ROOT);available=info.f_bavail*info.f_frsize
    plan.update(schemaVersion=1,scope='fresh EXP build-version target binding and file Undo acceptance',
        candidate=candidate,targets=[target],frozenInputs=inputs,unrelatedDiskIdentities=preserved,
        VMStarts=0,normalGUIBoots=0,securityWindows=0,automaticRetry=False,automaticRollback=False,
        reuseLockedPythonRuntime=True,minimumInitialFreeBytes=75*(1<<30),minimumEachCFWFreeBytes=50*(1<<30),
        observedAvailableBytes=available,initialCapacityPassed=available>=75*(1<<30),
        authorization='not approved; new candidate, fresh target, new generation and writes require explicit approval',
        runtimeProbeCommand=[str(Path(plan['pythonRuntime']['venv'])/'bin/python3'),
            str(Path(candidate['bundle'])/'Contents/Resources/scripts/check_python_runtime.py'),'--locked','--json'],
        regularCFWRepeated=False,expectedPrebootTarget='absent in retained source preflight; do not create',
        unexpectedPrebootPolicy='additional Undo target fails exact target-set audit; stop before Undo',
        preserve=['all previous VMs, disks, histories, originals and backups','regular accepted baseline',
                  'failed EXP target and generation','other VMs'],
        cleanup=['only scratch created by this new transaction through formal normal-unmount cleanup'],
        signatureAcceptance='complete originals and exact first/reapplied bytes plus mode/uid/gid',
        runtimeValidated=False)
    runner.validate(plan)
    runner.WORK.mkdir()
    runner.base.save(runner.WORK/'offline-plan.json',plan)
    print(json.dumps(dict(state='prepared-not-approved',planSHA256=runner.base.evidence.digest(runner.WORK/'offline-plan.json'),
        frozenInputs=len(inputs),initialCapacityPassed=plan['initialCapacityPassed'],availableBytes=available)))


if __name__=='__main__':main()
