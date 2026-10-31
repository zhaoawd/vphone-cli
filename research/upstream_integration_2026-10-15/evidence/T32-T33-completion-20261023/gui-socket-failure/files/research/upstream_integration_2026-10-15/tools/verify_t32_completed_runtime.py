#!/usr/bin/env python3
"""Read-only cleanup and preservation checks for the separately approved GUI run."""
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[3]
WORK=ROOT/'.build/t32-t33-completion-20261023/completed-runtime'
sys.path.insert(0,str(ROOT/'scripts'))
import cfw_guest_evidence as evidence


def absent(pid):
    p=subprocess.run(['/bin/ps','-p',str(pid),'-o','pid='],capture_output=True,text=True,timeout=10)
    if p.returncode not in (0,1):raise ValueError('Cannot inspect process')
    return p.returncode==1


def main():
    result=json.loads(evidence.read(WORK/'runtime-observation/result.json'))
    plan=json.loads(evidence.read(WORK/'runtime-plan.json'))
    state=json.loads(evidence.read(WORK/'boot-window/helper-state.json'))
    supervision=json.loads(evidence.read(WORK/'boot-window/supervisor-stop.json'))
    cleanup=json.loads(evidence.read(WORK/'boot-window/amfid-cleanup.json'))
    stopped=not result['VMStillRunning'] and absent(result['pid'])
    serial=evidence.read(WORK/'runtime-observation/serial.log').decode(errors='replace')
    normal=result['guestStopped'] and 'shutdown' in result and result.get('vmExitCode')==0
    processes={str(pid):absent(pid) for pid in (supervision['workerPID'],supervision['supervisorPID'])}
    debug=subprocess.run(['/usr/bin/pgrep','-x','debugserver'],capture_output=True,timeout=10)
    if debug.returncode not in (0,1):raise ValueError('Cannot inspect debugserver')
    seconds=supervision['stoppedAt']-state['startedAt']
    safety=dict(VMStopped=stopped,processesAbsent=processes,debugserverAbsent=debug.returncode==1,
        secondsToHelperExit=seconds,oneAttachment=state['attempt']==1,helperStopped=processes[str(supervision['workerPID'])],
        helperLastRecordedState=state['state'],normalShutdownVerified=normal,
        hostForcedStopObserved='graceful shutdown timed out; stopping' in serial,
        withinDeadline=supervision['withinDeadline'],amfidCleanup=cleanup)
    passed=stopped and all(processes.values()) and debug.returncode==1 and seconds<=900 and state['attempt']==1 and cleanup['passed']
    safety['passed']=passed
    evidence.write_new(WORK/'runtime-safety.json',json.dumps(safety,indent=2).encode()+b'\n')
    if not passed:raise ValueError('Cleanup check failed; preserve processes/state for manual inspection')
    print('VM/helper absence verified; normal shutdown: '+str(normal),flush=True)
    backup=json.loads(evidence.read(WORK/'runtime-backup.json'))
    rows={};current={};vm=Path(plan['vm'])
    for name,record in backup['files'].items():
        path=Path(backup['backup'])/name
        if evidence.digest(path)!=record['sha256'] or path.stat().st_size!=record['bytes']:
            raise ValueError('Backup changed: '+name)
        rows[name]=dict(sha256=record['sha256'],bytes=record['bytes'],passed=True)
        if name!='Disk.img':current[name]=dict(sha256=evidence.digest(vm/name))
        if name not in ('Disk.img','SEPStorage','nvram.bin') and current[name]['sha256']!=record['sha256']:
            raise ValueError('Static VM member changed: '+name)
    for path,digest in plan['frozenTools'].items():
        if evidence.digest(Path(path))!=digest:raise ValueError('Frozen runtime tool changed: '+path)
    print('Complete runtime backup and 365 frozen inputs verified',flush=True)
    native=json.loads(evidence.read(WORK.parent/'resumed-file-acceptance-plan.json'))
    p=Path(__file__).with_name('execute_t32_resumed_file_acceptance.py')
    spec=importlib.util.spec_from_file_location('native_preservation',p);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    module.verify_files(Path(native['sourceVM']),native['originalBootSHA256'],native['originalBootIdentity'])
    listing=plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil','info','-plist']))
    attached=[row.get('image-path','') for row in listing.get('images',[]) if row.get('image-path','').startswith(str(vm)+'/')]
    if attached:raise ValueError('Target image remains attached')
    preservation=dict(backupFiles=rows,currentNonDiskMembers=current,
        originalVMFilesFullReadback=len(native['originalBootSHA256']),frozenInputsVerified=len(plan['frozenTools']),
        targetAttachments=attached,VMStarts=1,securityWindows=1,accepted=False,runtimeValidated=False,
        patchCausalityValidated=False,trustedGuestOriginQualified=False)
    evidence.write_new(WORK/'runtime-preservation.json',json.dumps(preservation,indent=2).encode()+b'\n')
    print(json.dumps(dict(cleanupPassed=True,backupFiles=len(rows),originalVMFiles=12,frozenInputs=365,accepted=False)),flush=True)

if __name__=='__main__':main()
