#!/usr/bin/env python3
"""Prepare a separate short-path diagnostic snapshot; never boot or bind a VM."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import sys

ROOT=Path(__file__).resolve().parents[3]
TOOLS=Path(__file__).parent
BASE=ROOT/'.build/t32-t33-completion-20261023'
OLD=BASE/'completed-runtime'
WORK=BASE/'short-runtime'
VM=ROOT/'.build/t32r-20261023'
sys.path.insert(0,str(ROOT/'scripts'))
import cfw_disk_txn as txn
import cfw_guest_evidence as evidence
from t32_runtime_preflight import validate_control_socket


def save(path,value):
    evidence.write_new(path,json.dumps(value,indent=2).encode()+b'\n')


def main():
    if sys.argv[1:]!=['--prepare-only']:raise ValueError('Preparation only')
    if VM.exists() or WORK.exists():raise ValueError('Preserve any existing snapshot/work directory')
    geometry=validate_control_socket(VM)
    safety=json.loads(evidence.read(OLD/'runtime-safety.json'))
    preservation=json.loads(evidence.read(OLD/'runtime-preservation.json'))
    if not safety['passed'] or preservation['frozenInputsVerified']!=365:
        raise ValueError('Prior safety/preservation evidence required')
    snapshot_manifest=OLD/'runtime-backup.json'
    if evidence.digest(snapshot_manifest)!='ba519ab92e1ea77dfcbaf3161ae5fef3959c4daa36cfd9ffc07ce22a87278848':
        raise ValueError('Retained pre-boot snapshot manifest differs')
    snapshot=json.loads(evidence.read(snapshot_manifest));source=Path(snapshot['backup'])
    for name,record in snapshot['files'].items():
        if evidence.digest(source/name)!=record['sha256']:raise ValueError('Snapshot member differs: '+name)
    WORK.mkdir(mode=0o700);VM.mkdir(mode=0o700)
    files={}
    for name,record in sorted(snapshot['files'].items()):
        original=source/name;target=VM/name
        fd=os.open(original,os.O_RDONLY|os.O_NOFOLLOW)
        try:
            before=os.fstat(fd)
            if name=='Disk.img':txn.clone_file(fd,target);shutil.copystat(original,target)
            else:shutil.copy2(original,target)
            evidence.unchanged(original,fd,before)
        finally:os.close(fd)
        if evidence.digest(target)!=record['sha256']:raise ValueError('Diagnostic copy differs: '+name)
        if target.stat().st_ino==original.stat().st_ino:raise ValueError('Diagnostic member shares source inode')
        files[name]=dict(record,sourceIdentity=evidence.image_identity(target.stat()))
    save(WORK/'runtime-backup.json',dict(schemaVersion=1,state='verified-backup',vm=str(VM),backup=str(source),
        files=files,restoreAuthorized=False,runtimeSnapshotOnly=True,CFWAuthorityCopied=False,
        sourceVM=snapshot['vm'],sourceSnapshotManifestSHA256=evidence.digest(snapshot_manifest)))
    config=plistlib.loads(evidence.read(VM/'config.plist'))
    for name in [config['diskImage'],config['nvramStorage'],config['sepStorage'],*config['romImages'].values()]:
        if Path(name).is_absolute() or len(Path(name).parts)!=1 or name not in files:
            raise ValueError('Boot input escapes the diagnostic copy')
    plan=json.loads(evidence.read(OLD/'runtime-plan.json'))
    window=WORK/'boot-window';window.mkdir(mode=0o700)
    helper=evidence.read(OLD/'boot-window/scoped-amfidont.py').decode()
    previous=str(OLD/'boot-window')
    if helper.count(previous)!=1:raise ValueError('Unexpected helper path')
    evidence.write_new(window/'scoped-amfidont.py',helper.replace(previous,str(window)).encode())
    wrappers=[]
    for name in ('observe_t32_runtime','start_t32_observation_window'):
        path=WORK/(name+'.py')
        code=('import importlib.util\nfrom pathlib import Path\n'
            f'spec=importlib.util.spec_from_file_location("short_{name}",{str(TOOLS/(name+".py"))!r})\n'
            'module=importlib.util.module_from_spec(spec)\nspec.loader.exec_module(module)\n'
            f'module.WORK=Path({str(WORK)!r})\n'
            'if __name__=="__main__":raise SystemExit(module.main())\n')
        evidence.write_new(path,code.encode());wrappers.append(path)
    frozen=set(plan['frozenTools'])
    frozen-={str(OLD/'boot-window/scoped-amfidont.py'),str(OLD/'observe_t32_runtime.py'),str(OLD/'start_t32_observation_window.py')}
    frozen|={str(p) for p in wrappers+[window/'scoped-amfidont.py',Path(__file__).resolve(),TOOLS/'t32_runtime_preflight.py',TOOLS/'test_t32_runtime_preflight.py']}
    info=(VM/'Disk.img').stat()
    plan.update(scope='One GUI/hash diagnostic on a short-path independent pre-runtime snapshot',vm=str(VM),
        approved=False,expectedDiskIdentity=dict(evidence.image_identity(info),ctime_ns=info.st_ctime_ns),
        backup=str(source),backupManifestSHA256=evidence.digest(WORK/'runtime-backup.json'),
        runtimeObserver=str(wrappers[0]),rootWindowStarter=str(wrappers[1]),
        frozenTools={p:evidence.digest(Path(p)) for p in sorted(frozen)},
        runtimeSnapshotOnly=True,CFWAuthorityCopied=False,sourceVM=snapshot['vm'],
        sourceSnapshotManifestSHA256=evidence.digest(snapshot_manifest),socketPreflight=geometry,
        sourceVMGenerationID=plan['generationID'],sourcePublicationTransactionID=plan['transactionID'],
        failurePolicy='Stop helper and preserve all states. Permit only this diagnostic VM executable standard requestStop then framework-stop fallback on fatal startup/shutdown timeout; record fallback as failed normal shutdown. No agent force-stop or process kill.',
        shutdown='Normal system.shutdown RPC is required for acceptance; the pinned host executable own requestStop then framework-stop fallback on fatal startup/shutdown timeout is permitted only for this diagnostic copy and is recorded as failure',
        previousConsumedRuntimePlanSHA256=evidence.digest(OLD/'runtime-plan.json'),
        normalShutdownRequiredForAcceptance=True)
    # The copy has no generation/journal/binding authority of its own.
    plan.pop('generationID');plan.pop('transactionID')
    save(WORK/'runtime-plan.json',plan)
    print(json.dumps(dict(state='prepared-not-approved',plan=str(WORK/'runtime-plan.json'),
        planSHA256=evidence.digest(WORK/'runtime-plan.json'),files=len(files),frozenTools=len(frozen),
        socketBytes=geometry['bytesIncludingNul'],VMStarts=0,securityWindows=0)),flush=True)

if __name__=='__main__':main()
