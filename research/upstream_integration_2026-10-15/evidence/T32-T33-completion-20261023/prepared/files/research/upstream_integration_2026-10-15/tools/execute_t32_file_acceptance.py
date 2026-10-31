#!/usr/bin/env python3
"""Execute only a separately approved T32 offline on/off/on plan; never boot."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[3];WORK=ROOT/'.build/t32-t33-completion-20261023'
sys.path.insert(0,str(ROOT/'scripts'))
import cfw_guest_evidence as evidence
import cfw_disk_txn as txn
import cfw_verify_effects as audit
from patchers import guest_undo,file_originals,component_effects as effects


def approved(expected):
    raw=evidence.read(WORK/'file-acceptance-plan.json')
    if evidence.digest(WORK/'file-acceptance-plan.json')!=expected:raise ValueError('Plan digest changed')
    approval=json.loads(evidence.read(WORK/'file-acceptance-approval.json'))
    if approval!={'approved':True,'planSHA256':expected}:raise ValueError('Explicit plan approval required')
    plan=json.loads(raw)
    if plan.get('VMStarts')!=0 or plan.get('securityWindows')!=0:raise ValueError('Offline scope changed')
    if 'python' in plan and Path(plan['python']).resolve(strict=True)!=Path(plan['pythonResolved']):
        raise ValueError('Frozen interpreter path changed')
    for name,record in plan['frozenInputs'].items():
        if evidence.digest(Path(name))!=record:raise ValueError('Frozen input changed: '+name)
    return plan


def transition(first,restored,reapplied,originals,targets):
    if set(first)!=set(targets) or set(restored)!=set(targets) or set(reapplied)!=set(targets):
        raise ValueError('Incomplete on/off/on target set')
    for target in targets:
        if restored[target]!=originals[target]['state']:raise ValueError('Off target differs from complete original: '+target)
        if first[target]==restored[target]:raise ValueError('No observed on/off difference: '+target)
        if reapplied[target]!=first[target]:raise ValueError('Reapplied target differs from the first on state: '+target)
    return dict(passed=True,scope='complete file bytes and mode/uid/gid',targets=targets,
                runtimeValidated=False,originQualified=False)


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--execute-approved-plan',required=True)
    args=parser.parse_args()
    if os.geteuid()!=0:raise ValueError('Native administrator authentication required')
    plan=approved(args.execute_approved_plan);vm=Path(plan['vm']);out=WORK/'offline-acceptance'
    if out.exists():raise ValueError('Preserve prior attempt; do not automatically repeat')
    backup=json.loads(evidence.read(WORK/'acceptance-backup.json'))
    with audit.locked_vm(vm):
        txn.require_unheld(vm/'Disk.img',os.getpid(),'acceptance disk')
        if evidence.digest(vm/'Disk.img')!=plan['expectedCurrentImageSHA256']:raise ValueError('Current disk differs from backup')
        for name,record in backup['files'].items():
            if evidence.digest(Path(backup['backup'])/name)!=record['sha256'] or evidence.digest(vm/name)!=record['sha256']:
                raise ValueError('Complete backup/current boot state differs: '+name)
    out.mkdir(mode=0o755);os.chown(out,plan['invokerUID'],plan['invokerGID'])
    env=dict(os.environ,VPHONE_PYTHON=str(ROOT/'.venv/bin/python'),VPHONE_ROOT=str(WORK/'runtime-cache'),
        VPHONE_INVOKER_UID=str(plan['invokerUID']),VPHONE_INVOKER_GID=str(plan['invokerGID']),
        PYTHONDONTWRITEBYTECODE='1')
    for name in ('VPHONE_FROZEN_PLAN','VPHONE_FROZEN_PLAN_SHA256','VPHONE_FROZEN_CONTEXT',
                 'VPHONE_VM_LOCK_FD','VPHONE_DECLARATION_ID','CFW_HOST_MNT','VPHONE_GUEST_EVIDENCE'):
        env.pop(name,None)
    cli=plan['cliExecutable'];common=['--library-root',str(vm.parent),vm.name]
    install=[cli,'cfw','install',*common,'--variant','regular','--keep-artifacts','--reinstall-cryptex',
             '--work-parent','/private/tmp']
    undo=[cli,'cfw','undo',*common,'--generation',plan['generationID'],'--declaration',*plan['declarations']]
    result=dict(state='failed',VMStarted=False,securityWindowStarted=False,phases=[])
    first=None;originals=None;restored=None
    try:
        for name,command in [('on',install),('off',undo),('reapplied',install)]:
            approved(args.execute_approved_plan)
            with (out/(name+'.log')).open('xb') as log:
                status=subprocess.run(command,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT).returncode
            if status!=0:raise ValueError('CFW phase failed; preserve transaction and do not retry: '+name)
            with audit.locked_vm(vm):
                observed=audit.audit_locked(vm,Path('/private/tmp'))
                if not observed['passed']:raise ValueError('Strict installed-effect audit failed: '+name)
                committed=txn.committed_guest_evidence(vm)
                if committed is None:raise ValueError('Missing actual committed publication')
                archive,record,checkpoint,final=committed
                if checkpoint['generationID']!=plan['generationID']:raise ValueError('Generation changed')
                states={row['target']:row['state'] for row in final['outputs'] if row['target'] in plan['targets']}
                if name=='on':
                    selected=guest_undo.preview(vm,plan['generationID'],plan['declarations'])
                    if {entry['target'] for entry in selected['entries']}!=set(plan['targets']):
                        raise ValueError('Undo preview has a different complete target set')
                    catalog=file_originals.load(guest_undo.saved_plan(archive,plan['generationID']),archive/evidence.STORE)
                    originals=catalog['members'];first=states
                elif name=='off':
                    restored=states
                    with audit.readonly_roots(vm/'Disk.img',{'system'},Path('/private/tmp')) as (roots,recheck):
                        for target in plan['targets']:
                            path=audit.installed_effects.target_path(target,roots)
                            if effects.state(path,False)!=originals[target]['state']:raise ValueError('Actual restored file differs')
                            file_originals.code_pages(path,originals[target]['kind'])
                        recheck()
                else:result['transition']=transition(first,restored,states,originals,plan['targets'])
                phase=dict(name=name,transactionID=record['id'],publicationImageSHA256=checkpoint['imageSHA256'],
                           currentImageSHA256=checkpoint['currentImageSHA256'],targets=states,audit=observed)
                evidence.write_new(out/(name+'.json'),json.dumps(phase,indent=2).encode()+b'\n')
                os.chown(out/(name+'.json'),plan['invokerUID'],plan['invokerGID'])
                result['phases'].append(dict(name=name,transactionID=record['id']))
        result['state']='offline-on-off-on-passed'
    except Exception as error:result['error']=str(error)
    finally:
        evidence.write_new(out/'result.json',json.dumps(result,indent=2).encode()+b'\n')
        os.chown(out/'result.json',plan['invokerUID'],plan['invokerGID'])
    print(json.dumps(result));return 0 if result['state']=='offline-on-off-on-passed' else 1


if __name__=='__main__':raise SystemExit(main())
