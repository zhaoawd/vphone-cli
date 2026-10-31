#!/usr/bin/env python3
"""Execute a separately approved EXP continuation once; never retry a failed phase."""
import argparse
import json
import os
from pathlib import Path
import stat

import execute_t32_producer_acceptance as base

ROOT=base.ROOT
WORK=ROOT/'.build/t32-t33-completion-20261023/exp-cryptex-links-acceptance-20261024'
GENERATION='9084e09ef4fd59891f6279dfccf33b79cf46a5b63ffda790a3563cd6521bfa1a'
base.WORK=WORK
base.EXECUTOR_INPUTS='executor-inputs.json'


def validate_plan(plan):
    if (len(plan['targets'])!=1 or plan['targets'][0]['variant']!='exp'
            or plan['targets'][0]['vm']!=str(ROOT/'.build/t33q-20261024')
            or plan['targets'][0]['generationID']!=GENERATION
            or any(plan[k]!=0 for k in ('VMStarts','securityWindows','normalGUIBoots'))
            or any(plan[k] is not False for k in ('automaticRetry','automaticRollback'))):
        raise ValueError('EXP continuation scope changed')
    names=set(plan['currentTargetSnapshot']['files'])
    if len(names)!=14 or not {'.firmware-desired-plan.json','launchpad.json','Disk.img',
        '.cfw_temp/CryptexSystemOS.dmg','.cfw_temp/.CryptexSystemOS.dmg.source.json'}<=names:
        raise ValueError('Incomplete fourteen-file backup scope')
    return plan


def file_state(path):
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        before=os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink!=1:
            raise ValueError('Backup input is linked or special')
        value=dict(sha256=base.evidence.digest(path),bytes=before.st_size,dev=before.st_dev,
            ino=before.st_ino,mtime_ns=before.st_mtime_ns,mode=stat.S_IMODE(before.st_mode),
            uid=before.st_uid,gid=before.st_gid)
        base.evidence.unchanged(path,fd,before);return value
    finally:os.close(fd)


def current_locked(plan):
    target=plan['targets'][0];vm=Path(target['vm'])
    base.txn.require_unheld(vm/'Disk.img',os.getpid(),'EXP continuation current disk')
    if {p.name for p in (vm/'.cfw_temp').iterdir()}!={'CryptexSystemOS.dmg','.CryptexSystemOS.dmg.source.json'}:
        raise ValueError('Preserve unexpected EXP cache entries')
    for name,expected in plan['currentTargetSnapshot']['files'].items():
        if file_state(vm/name)!=expected:raise ValueError('EXP input changed: '+name)
    desired=json.loads(base.evidence.read(vm/'.firmware-desired-plan.json'))
    if desired['generationID']!=GENERATION or desired['plan']['variant']!='exp':
        raise ValueError('EXP generation or variant changed')
    if base.txn.committed_guest_evidence(vm) is not None:
        raise ValueError('Preserve an unexpected published EXP state')
    return target


def unrelated(plan):
    for name,expected in plan['unrelatedDiskIdentities'].items():
        s=(ROOT/name).stat()
        if dict(dev=s.st_dev,ino=s.st_ino,size=s.st_size)!=expected:
            raise ValueError('Unrelated disk identity changed: '+name)


def backup(plan):
    vm=Path(plan['targets'][0]['vm']);destination=Path(plan['preWriteBackup'])
    with base.audit.locked_vm(vm):
        current_locked(plan);destination.mkdir(mode=0o700)
        for name,expected in plan['currentTargetSnapshot']['files'].items():
            copied=destination/name;copied.parent.mkdir(mode=0o700,parents=True,exist_ok=True)
            base.clone_file(vm/name,copied);actual=file_state(copied)
            if actual['ino']==expected['ino'] or any(actual[k]!=expected[k]
                    for k in ('sha256','bytes','mtime_ns','mode','uid','gid')):
                raise ValueError('Fourteen-file backup differs: '+name)
        current_locked(plan)
    return dict(path=str(destination),files=plan['currentTargetSnapshot']['files'],fullReadbackPassed=True)


def verify_backup(record):
    for name,expected in record['files'].items():
        actual=file_state(Path(record['path'])/name)
        if any(actual[k]!=expected[k] for k in ('sha256','bytes','mtime_ns','mode','uid','gid')):
            raise ValueError('Preserved EXP pre-write backup changed: '+name)


def phases(plan,out,env,digest):
    target=plan['targets'][0];catalog=None;observations=[]
    for phase,argv in [('on',target['installCommand']),('off',target['undoCommand']),
                       ('reapplied',target['installCommand'])]:
        base.approved(digest);base.verify_execution_inputs();base.verify_inputs(plan)
        base.require_capacity(plan,initial=False)
        base.run(argv,out/(phase+'.log'),env)
        saved,originals=base.inspect_phase(plan,target,GENERATION,phase)
        if phase=='on':catalog=originals
        elif phase=='off':base.verify_restored(target,catalog)
        base.save(out/(phase+'.json'),saved);observations.append(saved)
    transition=base.transition(*(row['targets'] for row in observations),catalog,target['targets'])
    base.save(out/'transition.json',transition)
    return dict(vm=target['vm'],generationID=GENERATION,
        phases=[row['transactionID'] for row in observations],transition=transition)


def execute(plan,digest):
    if os.geteuid()!=0:raise ValueError('Native administrator authentication required')
    base.approved(digest);base.verify_inputs(plan);base.verify_execution_inputs();unrelated(plan)
    base.require_capacity(plan)
    out=WORK/'execution';store=base.store_cli(plan).parents[3]
    if out.exists() or Path(plan['preWriteBackup']).exists() or store.exists():
        raise ValueError('Preserve existing EXP continuation output, backup or Store version')
    if base.target_attachments(plan):raise ValueError('Target disk already attached')
    out.mkdir(mode=0o755);record=None
    result=dict(state='failed',VMStarts=0,securityWindows=0,originalVMWritten=False,targets=[])
    env=base.runtime_environment(plan)
    try:
        base.baseline(plan);record=backup(plan);base.save(out/'before-write-backup.json',record)
        base.run(plan['runtimeProbeCommand'],out/'runtime-probe.log',env)
        if json.loads((out/'runtime-probe.log').read_text()).get('ok') is not True:
            raise ValueError('Locked runtime probe failed')
        base.run(plan['installCommand'],out/'store-install.log',env)
        base.run(plan['verifyCommand'],out/'store-verify.log',env)
        if base.evidence.digest(base.store_cli(plan))!=plan['candidate']['cliSHA256']:
            raise ValueError('Installed CLI differs')
        base.run(plan['bindingCommand'],out/'bind.log',env,
                 identity=plan['sourceBootFiles']['config.plist'])
        expected=dict(plan['expectedBinding'],bundle=plan['candidate']['version'])
        if json.loads(base.evidence.read(Path(plan['targets'][0]['vm'])/'launchpad.json'))!=expected:
            raise ValueError('EXP binding changed unrelated origins')
        directory=out/'exp';directory.mkdir()
        result['targets'].append(phases(plan,directory,env,digest))
        result['state']='offline-qualified-on-off-on-passed'
    except Exception as error:result['error']=str(error)
    finally:
        try:
            result['baseline']=base.baseline(plan);unrelated(plan)
            base.verify_inputs(plan);base.verify_execution_inputs()
            if record is not None:verify_backup(record);result['preWriteBackupVerified']=True
            result['targetAttachments']=base.target_attachments(plan)
            if result['targetAttachments']:raise ValueError('Target attachment retained; no force cleanup')
        except Exception as error:
            result['state']='failed';result['preservationOrCleanupError']=str(error)
        base.save(out/'result.json',result);print(json.dumps(result),flush=True)
    return 0 if result['state']=='offline-qualified-on-off-on-passed' else 1


def main():
    parser=argparse.ArgumentParser(description=__doc__);group=parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--prepare-executor',action='store_true');group.add_argument('--execute-approved-plan')
    args=parser.parse_args();plan=validate_plan(json.loads((WORK/'offline-plan.json').read_text()))
    digest=base.evidence.digest(WORK/'offline-plan.json');base.APPROVED_SHA256=digest
    if args.prepare_executor:
        base.verify_inputs(plan);base.require_capacity(plan)
        inputs=base.execution_inputs(plan)
        for path in (Path(__file__),Path(__file__).with_name('test_t33_cryptex_links_acceptance.py')):
            inputs[str(path.resolve())]=base.evidence.digest(path)
        base.save(WORK/base.EXECUTOR_INPUTS,dict(planSHA256=digest,files=inputs))
        print(json.dumps(dict(state='executor-prepared-not-approved',planSHA256=digest,inputs=len(inputs))))
        return 0
    if args.execute_approved_plan!=digest:raise ValueError('Wrong EXP continuation plan digest')
    return execute(plan,digest)


if __name__=='__main__':raise SystemExit(main())
