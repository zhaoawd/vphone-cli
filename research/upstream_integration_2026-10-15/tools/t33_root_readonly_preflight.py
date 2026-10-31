#!/usr/bin/env python3
"""Read-only plan timing and guest-file capture; no CFW or VM execution."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parents[3]
WORK=ROOT/'.build/t32-t33-completion-20261023/exp-bounded-preflight-20261024'
CLI=Path('/Library/Application Support/vphone-launchpad/Bundles/2.6.2-local.a84f5889b159/VPhone.bundle/Contents/MacOS/vphone-cli')


def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as stream:
        while block:=stream.read(1<<20):h.update(block)
    return h.hexdigest()


def prepared():
    plan=json.loads((WORK/'readonly-diagnostic-plan.json').read_text())
    if (plan['VMStarts']!=0 or plan['securityWindows']!=0 or plan['CFWWrites']!=0
            or plan['operations']!=['trace-regular-plan-read','trace-exp-plan-read','readonly-guest-file-capture']):
        raise ValueError('Readonly diagnostic scope changed')
    for name,digest in plan['frozenCode'].items():
        if sha(name)!=digest:raise ValueError('Readonly diagnostic code changed: '+name)
    if sha(CLI)!=plan['cliSHA256']:raise ValueError('Readonly verifier executable changed')
    return plan


def identity(path):
    s=Path(path).stat()
    return dict(dev=s.st_dev,ino=s.st_ino,size=s.st_size,mtime_ns=s.st_mtime_ns,ctime_ns=s.st_ctime_ns)


def trace_read(plan,folder,name,vm,expected):
    prefix=folder/(name+'-trace')
    env=dict(PATH='/usr/bin:/bin:/usr/sbin:/sbin',VPHONE_KERNEL_IO_TRACE=str(prefix))
    argv=[str(CLI),'cfw','verify-plan',str(vm),'--expected-sha256',expected]
    start=time.monotonic();timed_out=False;sent=[]
    with (folder/(name+'-stdout.json')).open('xb') as out,(folder/(name+'-stderr.log')).open('xb') as err:
        child=subprocess.Popen(argv,stdout=out,stderr=err,env=env,start_new_session=True)
        try:child.wait(timeout=plan['maximumEachPlanReadSeconds'])
        except subprocess.TimeoutExpired:
            timed_out=True
            if os.getpgid(child.pid)!=child.pid:raise ValueError('Readonly child group changed')
            os.killpg(child.pid,signal.SIGTERM);sent.append('TERM')
            try:child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid,signal.SIGKILL);sent.append('KILL');child.wait(timeout=3)
    report=dict(command=argv,pid=child.pid,exitCode=child.returncode,timedOut=timed_out,
                elapsedSeconds=time.monotonic()-start,signalsToOwnedDiagnosticGroup=sent)
    path=Path(str(prefix)+'.'+str(child.pid)+'.jsonl')
    if path.exists():
        rows=[json.loads(line) for line in path.read_text().splitlines()]
        end=rows[-1]
        report['traceComplete']=end.get('type')=='measurement_end' and end.get('complete') is True
        hashes=[row for row in rows if row.get('phase')=='generation.fileSHA256']
        report['hashCalls']=len(hashes);report['hashedBytes']=sum(row.get('counts',{}).get('bytes',0) for row in hashes)
        report['hashInclusiveSeconds']=sum(row['elapsed_ns'] for row in hashes)/1e9
        groups={}
        for row in hashes:
            label=row.get('labels',{}).get('path_basename','unknown')
            group=groups.setdefault(label,dict(calls=0,bytes=0,elapsedSeconds=0))
            group['calls']+=1;group['bytes']+=row.get('counts',{}).get('bytes',0)
            group['elapsedSeconds']+=row['elapsed_ns']/1e9
        report['hashGroups']=groups
    else:report['traceComplete']=False
    report['passed']=not timed_out and child.returncode==0 and report['traceComplete']
    (folder/(name+'-summary.json')).write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(dict(step=name,**report)),flush=True);return report


def main():
    plan=prepared()
    if sys.argv[1:]==['--check-prepared']:
        print(json.dumps(dict(state='readonly-diagnostic-prepared',frozenCode=len(plan['frozenCode']))));return 0
    if sys.argv[1:]!=['--execute-authorized-readonly-diagnostic'] or os.geteuid()!=0:
        raise ValueError('Native authentication required for readonly private plans and APFS mounts')
    sys.path.insert(0,str(ROOT/'scripts'))
    import cfw_verify_effects as audit
    import cfw_disk_txn as txn
    folder=WORK/'root-readonly';folder.mkdir(mode=0o700)
    regular=ROOT/'.build/t32q-20261024';experimental=ROOT/'.build/t33q-20261024'
    before={str(vm):identity(vm/'Disk.img') for vm in (regular,experimental)}
    result=dict(scope=plan['operations'],VMStarts=0,CFWWrites=0,securityWindows=0,passed=False,checks={})
    try:
        for name,vm,expected in [('regular',regular,plan['regularDesiredSHA256']),
                                 ('exp',experimental,plan['expDesiredSHA256'])]:
            with audit.locked_vm(vm):
                txn.require_unheld(vm/'Disk.img',os.getpid(),'readonly diagnostic disk')
                if sha(vm/'.firmware-desired-plan.json')!=expected:raise ValueError('Private desired plan changed')
                result['checks'][name]=trace_read(plan,folder,name,vm,expected)
        files=folder/'guest-files';files.mkdir(mode=0o700);copied=[]
        with audit.locked_vm(experimental):
            txn.require_unheld(experimental/'Disk.img',os.getpid(),'readonly guest capture disk')
            with audit.readonly_roots(experimental/'Disk.img',{'system','preboot'},Path('/private/tmp')) as (roots,recheck):
                for volume,relative,name in plan['captureFiles']:
                    source=roots[volume]/relative
                    if source.is_symlink() or not source.is_file():
                        copied.append(dict(volume=volume,relative=relative,file=name,state='missing-or-linked'))
                        continue
                    first=identity(source);digest=sha(source)
                    with source.open('rb') as input_file,(files/name).open('xb') as output_file:
                        while block:=input_file.read(1<<20):output_file.write(block)
                    if sha(files/name)!=digest or identity(source)!=first:raise ValueError('Readonly guest copy differs')
                    copied.append(dict(volume=volume,relative=relative,file=name,sha256=digest,bytes=source.stat().st_size))
                recheck()
        result['guestFiles']=copied;result['guestMountsNormallyReleased']=True
        result['passed']=all(row['passed'] for row in result['checks'].values()) and all('sha256' in row for row in copied)
    except Exception as error:result['error']=str(error)
    finally:
        result['diskIdentityChecks']={str(vm):identity(vm/'Disk.img')==before[str(vm)] for vm in (regular,experimental)}
        if not all(result['diskIdentityChecks'].values()):result['passed']=False
        listing=plistlib.loads(audit.run_tool(['/usr/bin/hdiutil','info','-plist']))
        result['targetAttachments']=[row['image-path'] for row in listing.get('images',[])
            if row.get('image-path') and any(vm==Path(row['image-path']) or vm in Path(row['image-path']).parents
                                           for vm in (regular,experimental))]
        if result['targetAttachments']:result['passed']=False
        # Only files created in this new diagnostic directory are handed back.
        (folder/'result.json').write_text(json.dumps(result,indent=2)+'\n')
        for path in folder.rglob('*'):
            if path.is_symlink():raise ValueError('Unexpected linked diagnostic output')
            os.chown(path,plan['outputUID'],plan['outputGID'])
        os.chown(folder,plan['outputUID'],plan['outputGID'])
    print(json.dumps({k:v for k,v in result.items() if k!='targetAttachments'}),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
