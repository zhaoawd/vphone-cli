#!/usr/bin/env python3
"""Execute the approved offline producer plan once; no VM boot or helper."""
import argparse
import json
import os
import plistlib
from pathlib import Path
import shutil
import stat
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[3]
WORK=ROOT/'.build/t32-t33-completion-20261023/producer-acceptance-20261024'
APPROVED_SHA256='d5cc7bf5b0ce1d0e0159985e62acc618f2d59aabd4a020b381dfb6a4bebd565b'
EXECUTOR_INPUTS='executor-inputs-v2.json'
sys.path.insert(0,str(ROOT/'scripts'))
import cfw_guest_evidence as evidence
import cfw_disk_txn as txn
import cfw_verify_effects as audit
from patchers import component_effects as effects,file_originals,guest_undo


def save(path,value):
    evidence.write_new(path,json.dumps(value,indent=2).encode()+b'\n')
    os.chmod(path,0o644)


def approved(expected):
    path=WORK/'offline-plan.json'
    if expected!=APPROVED_SHA256 or evidence.digest(path)!=expected:raise ValueError('Approved plan digest changed')
    if json.loads(evidence.read(WORK/'approval.json'))!=dict(approved=True,planSHA256=expected):
        raise ValueError('Explicit plan approval required')
    plan=json.loads(evidence.read(path))
    if (plan['VMStarts']!=0 or plan['securityWindows']!=0 or plan['normalGUIBoots']!=0
            or plan['automaticRetry'] is not False or plan['automaticRollback'] is not False):
        raise ValueError('Approved offline scope changed')
    return plan


def verify_inputs(plan):
    for name,digest in plan['frozenInputs'].items():
        if evidence.digest(Path(name))!=digest:raise ValueError('Frozen input changed: '+name)


def require_capacity(plan,initial=True):
    minimum=plan['minimumInitialFreeBytes'] if initial else plan['minimumEachCFWFreeBytes']
    txn.require_free_space([ROOT],minimum=minimum)
    info=os.statvfs(ROOT)
    return dict(availableBytes=info.f_bavail*info.f_frsize,minimumBytes=minimum)


def baseline(plan):
    source=Path(plan['sourceBackup'])
    with audit.locked_vm(source):
        txn.require_unheld(source/'Disk.img',os.getpid(),'retained source backup')
        for name,row in plan['sourceBootFiles'].items():
            path=source/name;info=path.lstat()
            actual=dict(bytes=info.st_size,dev=info.st_dev,ino=info.st_ino,mtime_ns=info.st_mtime_ns,
                        mode=stat.S_IMODE(info.st_mode),uid=info.st_uid,gid=info.st_gid)
            if any(actual[key]!=row[key] for key in actual) or evidence.digest(path)!=row['sha256']:
                raise ValueError('Complete retained backup differs: '+name)
    return dict(files=len(plan['sourceBootFiles']),fullReadbackPassed=True)


def store_cli(plan):
    return Path(plan['targets'][0]['installCommand'][0])


def preflight(plan):
    require_capacity(plan)
    verify_inputs(plan)
    for target in plan['targets']:
        if os.path.lexists(target['vm']) or os.path.lexists(target['firstBindingBackup']):
            raise ValueError('Preserve existing target or binding backup')
    if os.path.lexists(plan['pythonRuntime']['root']) or os.path.lexists(store_cli(plan).parents[3]):
        raise ValueError('Preserve existing runtime or Store version; do not replay')
    if (WORK/'execution').exists():raise ValueError('Prior execution exists; no automatic retry')
    return baseline(plan)


def clone_file(source,target):
    fd=os.open(source,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        before=os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):raise ValueError('Clone source is not regular')
        txn.clone_file(fd,target);shutil.copystat(source,target)
        if os.geteuid()==0:os.chown(target,before.st_uid,before.st_gid)
        if evidence.digest(source)!=evidence.digest(target):raise ValueError('Complete clone content differs')
        evidence.unchanged(source,fd,before)
    finally:os.close(fd)


def clone_tree(source,target):
    info=source.lstat()
    if stat.S_ISDIR(info.st_mode):
        target.mkdir(mode=stat.S_IMODE(info.st_mode))
        for child in sorted(source.iterdir()):clone_tree(child,target/child.name)
    elif stat.S_ISREG(info.st_mode):clone_file(source,target)
    else:raise ValueError('Generation working source is linked or special')


def runtime_environment(plan):
    # All inherited producer/Python overrides are discarded.
    env=dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin',PYTHONNOUSERSITE='1',**plan['pythonRuntime']['environment'])
    owner=plan['sourceBootFiles']['config.plist']
    env.update(VPHONE_INVOKER_UID=str(owner['uid']),VPHONE_INVOKER_GID=str(owner['gid']))
    return env


def run(argv,log,env,identity=None):
    print('Executing '+log.name,flush=True)
    with log.open('xb') as output:
        credentials={} if identity is None else dict(user=identity['uid'],group=identity['gid'],extra_groups=[])
        subprocess.run([str(a) for a in argv],cwd=ROOT,env=env,stdout=output,stderr=subprocess.STDOUT,check=True,**credentials)


def verify_origin(plan,target,phase,report,binding):
    receipt=report['componentReceipts']
    if phase=='off':
        if report['originQualified'] or 'guestEnvironment' in binding:
            raise ValueError('Undo did not publish unknown Guest origin')
        if set(receipt['removedDeclarations'])!=set(target['declarations']):
            raise ValueError('Undo receipt has another declaration set')
    else:
        source=receipt.get('qualifiedProducer',{})
        if (report['originQualified'] is not True or receipt['originQualified'] is not True
                or source.get('version')!=plan['candidate']['version']
                or source.get('archiveSHA256')!=plan['candidate']['archiveSHA256']
                or source.get('executableSHA256')!=plan['candidate']['cliSHA256']
                or binding.get('guestEnvironment')!=plan['candidate']['version']):
            raise ValueError('Actual source, disk, receipt or binding differs')
    if binding.get('bundle')!=plan['candidate']['version'] or any(binding.get(k) is not None for k in ('kernel','bootChain')):
        raise ValueError('Unrelated component origins changed')
    if report['runtimeValidated'] is not False:raise ValueError('Offline receipt cannot claim runtime acceptance')


def transition(first,restored,reapplied,originals,targets):
    for states in (first,restored,reapplied):
        if set(states)!=set(targets):raise ValueError('Incomplete on/off/on target set')
    for target in targets:
        if restored[target]!=originals[target]['state']:raise ValueError('Off differs from complete original: '+target)
        if first[target]==restored[target]:raise ValueError('No observed on/off difference: '+target)
        if reapplied[target]!=first[target]:raise ValueError('Reapplication differs from exact first bytes/metadata: '+target)
    return dict(passed=True,scope='complete file bytes and mode/uid/gid',targets=targets,runtimeValidated=False)


def inspect_phase(plan,target,generation,phase):
    vm=Path(target['vm'])
    with audit.locked_vm(vm):
        observed=audit.audit_locked(vm,Path('/private/tmp'))
        if not observed['passed']:raise ValueError('Independent installed-target audit failed')
        archive,record,checkpoint,final=txn.committed_guest_evidence(vm)
        if checkpoint['generationID']!=generation:raise ValueError('Publication generation changed')
        report=txn.inspect_guest(vm);binding=json.loads(evidence.read(vm/'launchpad.json'))
        verify_origin(plan,target,phase,report,binding)
        states={r['target']:r['state'] for r in final['outputs'] if r['target'] in target['targets']}
        if set(states)!=set(target['targets']):raise ValueError('Independent target set incomplete')
        originals=None
        if phase=='on':
            preview=guest_undo.preview(vm,generation,target['declarations'])
            if {r['target'] for r in preview['entries']}!=set(target['targets']):raise ValueError('Different Undo target set')
            originals=file_originals.load(guest_undo.saved_plan(archive,generation),archive/evidence.STORE)['members']
        return dict(phase=phase,transactionID=record['id'],generationID=generation,targets=states,
                    independentAudit=observed,sourceReceipt=report,binding=binding),originals


def verify_restored(target,originals):
    vm=Path(target['vm']);wanted={name.split(':',1)[0] for name in target['targets']}
    with audit.locked_vm(vm):
        with audit.readonly_roots(vm/'Disk.img',wanted,Path('/private/tmp')) as (roots,recheck):
            for name in target['targets']:
                path=audit.installed_effects.target_path(name,roots)
                if effects.state(path,False)!=originals[name]['state']:raise ValueError('Full restored original differs: '+name)
                file_originals.code_pages(path,originals[name]['kind'])
            recheck()


def run_target(plan,target,out,env):
    vm=Path(target['vm']);out.mkdir()
    require_capacity(plan,initial=False)
    with audit.locked_vm(Path(plan['sourceBackup'])):
        txn.require_unheld(Path(plan['sourceBackup'])/'Disk.img',os.getpid(),'retained source backup')
        vm.mkdir(mode=0o755)
        owner=plan['sourceBootFiles']['config.plist'];os.chown(vm,owner['uid'],owner['gid'])
        for name in target['copyBootFiles']:clone_file(Path(target['cloneFrom'])/name,vm/name)
    cli=store_cli(plan)
    run([cli,'vm','bind-core-bundle',vm.name,'--library-root',vm.parent,'--version',plan['candidate']['version'],
         '--backup',target['firstBindingBackup']],out/'bind.log',env,identity=owner)
    run(target['generationCommand'],out/'generation.log',env)
    desired=json.loads(evidence.read(vm/'.firmware-desired-plan.json'));generation=desired['generationID']
    manifest=json.loads(evidence.read(vm/'.firmware-generations'/generation/'manifest.json'))
    expected={}
    for key,option in [('iPhone','--iphone-source'),('cloudOS','--cloudos-source')]:
        argv=target['generationCommand'];source=argv[argv.index(option)+1];expected[key]=plan['frozenInputs'][source]
    if (desired['plan']['variant']!=target['variant']
            or manifest['content']['source']['archiveSHA256']!=expected):raise ValueError('Fresh generation source/variant differs')
    originals=vm/'.firmware-generations'/generation/'originals'
    restores=[row['name'] for row in manifest['content']['originals'] if row['name'].endswith('Restore')]
    if len(restores)!=1:raise ValueError('Ambiguous generation Restore working source')
    clone_tree(originals/restores[0],vm/restores[0])
    undo=[generation if arg=='<verified-new-generation-id>' else arg for arg in target['undoCommand']]
    observations=[];catalog=None
    for phase,argv in [('on',target['installCommand']),('off',undo),('reapplied',target['installCommand'])]:
        approved(APPROVED_SHA256);verify_execution_inputs();require_capacity(plan,initial=False)
        run(argv,out/(phase+'.log'),env)
        saved,original=inspect_phase(plan,target,generation,phase)
        if phase=='on':catalog=original
        elif phase=='off':verify_restored(target,catalog)
        save(out/(phase+'.json'),saved);observations.append(saved)
    result=transition(*(r['targets'] for r in observations),catalog,target['targets'])
    save(out/'transition.json',result)
    return dict(vm=str(vm),generationID=generation,phases=[r['transactionID'] for r in observations],transition=result)


def execution_inputs(plan):
    paths=[Path(__file__),Path(plan['pythonRuntime']['hostPython'])]
    paths.extend((ROOT/'scripts').glob('*.py'));paths.extend((ROOT/'scripts/patchers').glob('*.py'))
    return {str(path.resolve(strict=True)):evidence.digest(path.resolve(strict=True)) for path in paths}


def verify_execution_inputs():
    manifest=json.loads(evidence.read(WORK/EXECUTOR_INPUTS))
    if manifest['planSHA256']!=APPROVED_SHA256:raise ValueError('Executor belongs to another plan')
    for path,digest in manifest['files'].items():
        if evidence.digest(Path(path))!=digest:raise ValueError('Executor input changed: '+path)


def target_attachments(plan):
    result=subprocess.run(['/usr/bin/hdiutil','info','-plist'],check=True,capture_output=True,timeout=30)
    listing=plistlib.loads(result.stdout)
    targets=[Path(target['vm']) for target in plan['targets']]
    return [row['image-path'] for row in listing.get('images',[]) if row.get('image-path')
            and any(Path(row['image-path'])==target or target in Path(row['image-path']).parents for target in targets)]


def execute(plan):
    if os.geteuid()!=0:raise ValueError('Native administrator authentication required')
    preflight(plan);verify_execution_inputs()
    out=WORK/'execution';out.mkdir(mode=0o755)
    result=dict(state='failed',VMStarts=0,securityWindows=0,originalVMWritten=False,targets=[])
    env=runtime_environment(plan);candidate=plan['candidate'];cli=store_cli(plan)
    try:
        local=Path(candidate['bundle'])/'Contents/MacOS/vphone-cli'
        run([local,'core-bundle','install','--version',candidate['version'],'--archive',candidate['archive'],
             '--sha256',candidate['archiveSHA256']],out/'store-install.log',env)
        run([cli,'core-bundle','verify','--version',candidate['version']],out/'store-verify.log',env)
        if evidence.digest(cli)!=candidate['cliSHA256']:raise ValueError('Installed CLI changed')
        runtime=plan['pythonRuntime'];Path(runtime['root']).mkdir(mode=0o700)
        provision=[runtime['hostPython'] if a=='<verified-host-python>' else a for a in runtime['provisionCommand']]
        run(provision,out/'runtime-provision.log',env)
        run([Path(runtime['venv'])/'bin/python3',cli.parents[1]/'Resources/scripts/check_python_runtime.py','--locked','--json'],
            out/'runtime-probe.log',env)
        for target in plan['targets']:
            result['targets'].append(run_target(plan,target,out/target['variant'],env))
        result['state']='offline-qualified-on-off-on-passed'
    except Exception as error:
        result['error']=str(error)
    finally:
        try:
            result['baseline']=baseline(plan);verify_inputs(plan)
            result['targetAttachments']=target_attachments(plan)
            if result['targetAttachments']:raise ValueError('Target attachment retained; no force cleanup')
        except Exception as error:
            result['state']='failed';result['preservationOrCleanupError']=str(error)
        save(out/'result.json',result)
        print(json.dumps(result),flush=True)
    return 0 if result['state']=='offline-qualified-on-off-on-passed' else 1


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prepare-executor',action='store_true')
    parser.add_argument('--preflight',action='store_true')
    parser.add_argument('--execute-approved-plan')
    args=parser.parse_args()
    if sum([args.prepare_executor,args.preflight,bool(args.execute_approved_plan)])!=1:
        raise ValueError('Choose exactly one operation')
    plan=approved(args.execute_approved_plan or APPROVED_SHA256)
    if args.prepare_executor:
        verify_inputs(plan)
        save(WORK/EXECUTOR_INPUTS,dict(planSHA256=APPROVED_SHA256,files=execution_inputs(plan)))
        print('Executor inputs frozen; no Store or VM mutation')
        return 0
    if args.preflight:
        print(json.dumps(dict(state='preflight-passed',capacity=require_capacity(plan),baseline=preflight(plan))))
        return 0
    return execute(plan)


if __name__=='__main__':raise SystemExit(main())
