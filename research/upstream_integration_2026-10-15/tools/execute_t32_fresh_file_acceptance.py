#!/usr/bin/env python3
"""Separately approved fresh-source isolation after an incomplete historical chain."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[3];WORK=ROOT/'.build/t32-t33-completion-20261023'
sys.path.insert(0,str(ROOT/'scripts'))
import cfw_guest_evidence as evidence
import cfw_disk_txn as txn
import cfw_verify_effects as audit
from patchers import file_originals,guest_undo,component_effects as effects
spec=importlib.util.spec_from_file_location('old_acceptance',Path(__file__).with_name('execute_t32_file_acceptance.py'))
previous=importlib.util.module_from_spec(spec);spec.loader.exec_module(previous)


def approved(expected):
    path=WORK/'fresh-file-acceptance-plan.json'
    if evidence.digest(path)!=expected:raise ValueError('Fresh plan changed')
    approval=json.loads(evidence.read(WORK/'fresh-file-acceptance-approval.json'))
    if approval!={'approved':True,'planSHA256':expected}:raise ValueError('Separate fresh-source approval required')
    plan=json.loads(evidence.read(path))
    if plan['VMStarts']!=0 or plan['securityWindows']!=0:raise ValueError('Offline scope differs')
    if Path(plan['python']).resolve(strict=True)!=Path(plan['pythonResolved']):raise ValueError('Interpreter path changed')
    for name,digest in plan['frozenInputs'].items():
        if evidence.digest(Path(name))!=digest:raise ValueError('Frozen input changed: '+name)
    return plan


def clone_file(source,target):
    fd=os.open(source,os.O_RDONLY|os.O_NOFOLLOW)
    try:
        before=os.fstat(fd);txn.clone_file(fd,target);shutil.copystat(source,target)
        if evidence.digest(target)!=evidence.digest(source):raise ValueError('Complete clone digest differs')
        evidence.unchanged(source,fd,before)
    finally:os.close(fd)


def clone_tree(source,target):
    if source.is_symlink():raise ValueError('Linked fresh source')
    if source.is_dir():
        target.mkdir(mode=0o700)
        for child in sorted(source.iterdir()):clone_tree(child,target/child.name)
    elif source.is_file():clone_file(source,target)
    else:raise ValueError('Special fresh source')


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--execute-approved-plan',required=True);args=parser.parse_args()
    if os.geteuid()!=0:raise ValueError('Native administrator authentication required')
    plan=approved(args.execute_approved_plan);old=Path(plan['sourceVM']);vm=Path(plan['vm']);out=WORK/'fresh-offline-acceptance'
    if out.exists() or vm.exists():raise ValueError('Preserve prior attempt; no automatic retry')
    out.mkdir(mode=0o755);os.chown(out,501,20)
    result=dict(state='failed',sourceVMWritten=False,VMStarted=False,securityWindowStarted=False,phases=[])
    try:
        # The only approved deletion is a named, detached, regenerable decoder cache.
        cache=Path(plan['decodedCacheCleanup']['path'])
        listing=__import__('plistlib').loads(subprocess.check_output(['/usr/bin/hdiutil','info','-plist']))
        if any(Path(row.get('image-path','')).absolute()==cache for row in listing.get('images',[])):
            raise ValueError('Preserve attached decoder cache')
        if evidence.digest(cache)!=plan['decodedCacheCleanup']['sha256']:raise ValueError('Decoder cache changed')
        cache.unlink()
        txn.require_free_space([WORK],minimum=plan['minimumFreeBytes'])
        backup=json.loads(evidence.read(WORK/'acceptance-backup.json'))
        with audit.locked_vm(old):
            txn.require_unheld(old/'Disk.img',os.getpid(),'source VM disk')
            for name,record in backup['files'].items():
                if evidence.digest(old/name)!=record['sha256']:raise ValueError('Source boot state changed')
            vm.parent.mkdir(mode=0o755,exist_ok=True);vm.mkdir(mode=0o755);os.chown(vm,501,20)
            for name in plan['copyBootFiles']:
                source=old/name;target=vm/name;clone_file(source,target);os.chown(target,501,20)
        env=dict(os.environ,VPHONE_PYTHON=plan['python'],VPHONE_ROOT=str(WORK/'fresh-runtime-cache'),
            SUDO_UID='501',SUDO_GID='20',PYTHONDONTWRITEBYTECODE='1')
        for key in ('VPHONE_VM_LOCK_FD','VPHONE_FROZEN_PLAN','VPHONE_FROZEN_PLAN_SHA256','VPHONE_FROZEN_CONTEXT',
                    'VPHONE_GUEST_EVIDENCE','CFW_HOST_MNT','VPHONE_DECLARATION_ID'):env.pop(key,None)
        cli=plan['cliExecutable'];common=['--library-root',str(vm.parent),vm.name]
        prepare=[cli,'fw','generation-prepare',*common,'--iphone-source',plan['iphoneSource'],
            '--cloudos-source',plan['cloudOSSource'],'--boot-rom-source',plan['bootROMSource'],'--variant','regular']
        with (out/'generation-prepare.log').open('xb') as log:
            subprocess.run(prepare,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
        record=json.loads(evidence.read(vm/'.firmware-desired-plan.json'));generation=record['generationID']
        if generation==plan['oldGenerationID'] or record['planSHA256']!=plan['expectedPlanSHA256']:
            raise ValueError('Fresh generation or selection boundary differs')
        generation_root=vm/'.firmware-generations'/generation
        manifest=json.loads(evidence.read(generation_root/'manifest.json'))
        if manifest['content']['source']['archiveSHA256']!=plan['archiveSHA256']:
            raise ValueError('Fresh producer archive association differs')
        # CFW's working tree is a clone of the newly verified generation, never
        # an original inferred from the installed guest or its old history.
        restores=[row['name'] for row in manifest['content']['originals'] if row['name'].endswith('Restore')]
        if len(restores)!=1:raise ValueError('Ambiguous fresh restore tree')
        clone_tree(generation_root/'originals'/restores[0],vm/restores[0])
        result['generationID']=generation
        first=originals=restored=None
        install=[cli,'cfw','install',*common,'--variant','regular','--keep-artifacts','--reinstall-cryptex','--work-parent','/private/tmp']
        undo=[cli,'cfw','undo',*common,'--generation',generation,'--declaration',*plan['declarations']]
        for phase,command in [('on',install),('off',undo),('reapplied',install)]:
            approved(args.execute_approved_plan)
            with (out/(phase+'.log')).open('xb') as log:
                subprocess.run(command,cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
            with audit.locked_vm(vm):
                observation=audit.audit_locked(vm,Path('/private/tmp'))
                if not observation['passed']:raise ValueError('Strict current-target audit failed: '+phase)
                archive,journal,checkpoint,final=txn.committed_guest_evidence(vm)
                states={row['target']:row['state'] for row in final['outputs'] if row['target'] in plan['targets']}
                if phase=='on':
                    selection=guest_undo.preview(vm,generation,plan['declarations'])
                    if {entry['target'] for entry in selection['entries']}!=set(plan['targets']):raise ValueError('Different Undo target set')
                    originals=file_originals.load(guest_undo.saved_plan(archive,generation),archive/evidence.STORE)['members'];first=states
                elif phase=='off':
                    restored=states
                    with audit.readonly_roots(vm/'Disk.img',{'system'},Path('/private/tmp')) as (roots,recheck):
                        for target in plan['targets']:
                            path=audit.installed_effects.target_path(target,roots)
                            if effects.state(path,False)!=originals[target]['state']:raise ValueError('Restored complete original differs')
                            file_originals.code_pages(path,originals[target]['kind'])
                        recheck()
                else:result['transition']=previous.transition(first,restored,states,originals,plan['targets'])
                saved=dict(phase=phase,transactionID=journal['id'],generationID=generation,targets=states,audit=observation)
                evidence.write_new(out/(phase+'.json'),json.dumps(saved,indent=2).encode()+b'\n');os.chown(out/(phase+'.json'),501,20)
                result['phases'].append(dict(name=phase,transactionID=journal['id']))
        with audit.locked_vm(old):
            for name,record in backup['files'].items():
                if evidence.digest(old/name)!=record['sha256']:raise ValueError('Source VM changed during isolation')
        result['state']='fresh-offline-on-off-on-passed'
    except Exception as error:result['error']=str(error)
    finally:
        evidence.write_new(out/'result.json',json.dumps(result,indent=2).encode()+b'\n');os.chown(out/'result.json',501,20)
    print(json.dumps(result));return 0 if result['state']=='fresh-offline-on-off-on-passed' else 1


if __name__=='__main__':raise SystemExit(main())
