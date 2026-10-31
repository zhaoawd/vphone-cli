#!/usr/bin/env python3
"""Prepare an unapproved offline plan; never install, clone a VM, or boot."""
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[3]
WORK=ROOT/'.build/t32-t33-completion-20261023'
sys.path.insert(0,str(ROOT/'scripts'))
import cfw_guest_evidence as evidence


def main():
    if sys.argv[1:]!=['--prepare-only']:raise ValueError('Preparation only')
    out=WORK/'producer-acceptance-20261024'
    if out.exists():raise ValueError('Preserve prior preparation')
    candidate_path=WORK/'candidate-producer-package-final-20261024.json'
    candidate=json.loads(evidence.read(candidate_path))
    if evidence.digest(Path(candidate['archive']))!=candidate['archiveSHA256']:raise ValueError('Candidate differs')
    baseline=json.loads(evidence.read(WORK/'acceptance-backup.json'))
    source=Path(baseline['backup']);boot={}
    for name,row in baseline['files'].items():
        if name.startswith('.firmware-'):continue
        path=source/name
        actual=evidence.digest(path)
        if actual!=row['sha256']:raise ValueError('Complete retained backup differs: '+name)
        info=path.lstat()
        boot[name]=dict(sha256=actual,bytes=info.st_size,dev=info.st_dev,ino=info.st_ino,
                       mtime_ns=info.st_mtime_ns,mode=info.st_mode&0o7777,uid=info.st_uid,gid=info.st_gid)
    archives=json.loads(evidence.read(WORK/'fresh-archive-sources.json'))
    for row in archives:
        if evidence.digest(Path(row['path']))!=row['sha256']:raise ValueError('Source IPSW differs')
    original=Path(baseline['vm'])/'.firmware-generations/6ebc5f6705cf0bffb32da62bf3006cc7ece5027edee4306abc8031aee9f4bb42/originals/AVPBooter.vresearch1.bin'
    rom_sha='301bc973b56e86a9906bb6002d008015a57c9e07b5f191260717b97a62589072'
    if evidence.digest(original)!=rom_sha:raise ValueError('Independent original ROM differs')
    bundle=Path(candidate['bundle']);vm=bundle/'Contents/MacOS/vphone-vm'
    detail=subprocess.run(['/usr/bin/codesign','-d','--verbose=4',str(vm)],capture_output=True,text=True,check=True)
    cdhash=next(line.split('=',1)[1] for line in detail.stderr.splitlines() if line.startswith('CDHash='))
    store=Path('/Library/Application Support/vphone-launchpad/Bundles')/candidate['version']/'VPhone.bundle'
    cli=store/'Contents/MacOS/vphone-cli';cache=ROOT/'.build/t32-qualified-cache-20261024'
    targets=[]
    for variant,name,declarations,files in (
        ('regular','t32q-20261024',['system-seputil-boot-gigalocker_uuid','system-launchd_cache_loader-boot-unsecure_cache_gate','system-mobileactivationd-boot-should_hactivate'],
         ['system:/usr/libexec/seputil','system:/usr/libexec/launchd_cache_loader','system:/usr/libexec/mobileactivationd']),
        ('exp','t33q-20261024',['system-systemversion-cfw-build_version'],
         ['system:/System/Library/CoreServices/SystemVersion.plist','preboot:/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist'])):
        directory=ROOT/'.build'/name
        if directory.exists():raise ValueError('New target already exists: '+name)
        common=[name,'--library-root',str(directory.parent)]
        prepare=[str(cli),'fw','generation-prepare',*common,'--iphone-source',archives[0]['path'],
            '--cloudos-source',archives[1]['path'],'--boot-rom-source',str(original),'--variant',variant]
        install=[str(cli),'cfw','install',*common,'--variant',variant,'--qualify-origin','--keep-artifacts','--work-parent','/private/tmp']
        if variant=='regular':install+=['--reinstall-cryptex']
        else:install+=['--spoof-build','23Z999999']
        targets.append(dict(variant=variant,vm=str(directory),cloneFrom=str(source),copyBootFiles=list(boot),
            exclude=['desired-plan','receipts','history','generation','runtime','launchpad.json'],
            newGeneration=True,firstBindingBackup=str(ROOT/'.build'/(name+'-binding-backup')),
            generationCommand=prepare,installCommand=install,declarations=declarations,targets=files,
            undoCommand=[str(cli),'cfw','undo',*common,'--generation','<verified-new-generation-id>','--declaration',*declarations],
            phases=['clone retained verified full backup','bind selected Store Bundle with complete first-binding backup',
                    'generate originals through formal IPSW producer','clone CFW working tree only from new generation originals',
                    'qualified install','independent readonly audit and source/receipt verification',
                    'declaration Undo','independent full original bytes/metadata readback; Guest origin unknown',
                    'same qualified reapplication','independent exact first/reapplied bytes/metadata and source/receipt verification']))
    frozen={}
    for path in bundle.rglob('*'):
        if path.is_symlink():raise ValueError('Linked candidate')
        if path.is_file():frozen[str(path)]=evidence.digest(path)
    for path in (candidate_path,Path(candidate['archive']),Path(__file__),WORK/'acceptance-backup.json',WORK/'fresh-archive-sources.json'):
        frozen[str(path)]=evidence.digest(path)
    for row in archives:frozen[row['path']]=row['sha256']
    frozen[str(original)]=rom_sha
    capacity=os.statvfs(ROOT);available=capacity.f_bavail*capacity.f_frsize
    plan=dict(schemaVersion=1,approved=False,approvalRequired=True,state='prepared_capacity_blocked' if available<75<<30 else 'prepared_unapproved',
        scope='New isolated regular three-Mach-O and EXP two-plist offline on/off/on with live Store source publication',
        candidate=candidate,candidateRecord=str(candidate_path),newStoreVersionOnly=True,sourceBackup=str(source),
        sourceBootFiles=boot,originalVM=str(baseline['vm']),originalVMWritten=False,targets=targets,
        pythonRuntime=dict(provisionSeparate=True,root=str(cache),venv=str(cache/'venv'),
            hostPython=str((ROOT/'.venv/bin/python').resolve(strict=True)),
            provisionCommand=['<verified-host-python>',str(store/'Contents/Resources/scripts/python_environment.py'),
                '--base',str(store/'Contents/Resources'),'--venv',str(cache/'venv')],
            environment=dict(VPHONE_ROOT=str(cache),PIP_CACHE_DIR=str(cache/'pip-cache'),PYTHONDONTWRITEBYTECODE='1'),
            policy='Explicit new cache only; locked probe before CFW; qualified install/recovery cannot bootstrap'),
        minimumInitialFreeBytes=75<<30,minimumEachCFWFreeBytes=50<<30,observedAvailableBytes=available,
        capacityPolicy='Refuse before Store installation or any VM clone if below initial minimum; no automatic deletion',
        cleanup='Standard CFW temporary cleanup only in the two new targets and their new decoded scratch after normal detach',
        preserve=['all old disks, originals, generations, histories and evidence','original VM','complete retained backups','all other VMs'],
        automaticRetry=False,automaticRollback=False,failurePolicy='Stop dependent phases and retain all evidence and images',
        VMStarts=0,securityWindows=0,normalGUIBoots=0,guestProgramInstallation=False,
        nextRuntimeCandidate=dict(vmSHA256=evidence.digest(vm),CDHash=cdhash,authorized=False,
            status='Separate post-publication GUI/AA.gl plan and backup required; all prior windows consumed'),
        acceptance=dict(strictWholeFileReapplication=True,fullOriginalRestore=True,sourceAndReceiptSameJournal=True,
                        EXPPrebootRequired=True,oldFailuresUnchanged=True,runtimeValidated=False,T32T33Accepted=False),
        frozenInputs=frozen)
    out.mkdir(mode=0o700)
    path=out/'offline-plan.json'
    evidence.write_new(path,json.dumps(plan,indent=2).encode()+b'\n')
    print(json.dumps(dict(plan=str(path),sha256=evidence.digest(path),state=plan['state'],
        candidate=candidate['version'],availableGiB=round(available/(1<<30),3),requiredGiB=75,bootFiles=len(boot),frozenInputs=len(frozen))))


if __name__=='__main__':main()
