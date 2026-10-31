#!/usr/bin/env python3
"""Execute only a separately approved, backed-up T32 GUI/hash observation."""
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time

ROOT=Path(__file__).resolve().parents[3]
WORK=ROOT/'.build/t32-t33-followup-20261023'
sys.path.insert(0,str(ROOT/'scripts'))
from host_control_client import endpoint,request


def approved_plan(expected):
    raw=(WORK/'runtime-plan.json').read_bytes()
    if hashlib.sha256(raw).hexdigest()!=expected:raise ValueError('Runtime plan changed')
    approval=json.loads((WORK/'runtime-approval.json').read_text())
    if approval.get('approved') is not True or approval.get('planSHA256')!=expected:
        raise ValueError('New runtime/security-window approval required')
    plan=json.loads(raw)
    for path,digest in plan['frozenTools'].items():
        if hashlib.sha256(Path(path).read_bytes()).hexdigest()!=digest:raise ValueError('Frozen input changed: '+path)
    if hashlib.sha256((WORK/'runtime-backup.json').read_bytes()).hexdigest()!=plan['backupManifestSHA256']:
        raise ValueError('Verified backup manifest changed')
    return plan


def compare_images(first,second):
    from PIL import Image,ImageStat
    images=[Image.open(path).convert('RGB') for path in (first,second)]
    if images[0].size!=images[1].size or min(images[0].size)<100:
        raise ValueError('Display dimensions differ or are invalid')
    if any(max(ImageStat.Stat(image).var)<1 for image in images):raise ValueError('Display frame is uniform')
    if images[0].tobytes()==images[1].tobytes():raise ValueError('Display frames did not change')
    return dict(dimensions=list(images[0].size),distinct=True,nonUniform=True,
                scope='host display frames during the named system-app transition; patch causality unproven')


def main():
    if len(sys.argv)!=3 or sys.argv[1]!='--execute-approved-runtime-plan':
        raise ValueError('Explicit approved plan SHA-256 required')
    marker=WORK/'boot-window/stop-authorized-helper'
    child=None;target=None;result=dict(state='failed',runtimeValidated=False,patchCausalityValidated=False)
    output=WORK/'runtime-observation'
    try:
        plan=approved_plan(sys.argv[2]);output.mkdir(mode=0o700)
        vm=Path(plan['vm']);binary=Path(plan['vmExecutable'])
        current=(vm/'Disk.img').stat()
        if dict(dev=current.st_dev,ino=current.st_ino,size=current.st_size,mtime_ns=current.st_mtime_ns,
                ctime_ns=current.st_ctime_ns)!=plan['expectedDiskIdentity']:
            raise ValueError('Disk identity changed after the approved baseline')
        if hashlib.sha256(binary.read_bytes()).hexdigest()!=plan['vmSHA256']:raise ValueError('VM binary changed')
        backup=json.loads((WORK/'runtime-backup.json').read_text())
        for name,record in backup['files'].items():
            if name in ('nvram.bin','SEPStorage','Disk.img'):
                s=(vm/name).stat()
                if dict(dev=s.st_dev,ino=s.st_ino,size=s.st_size,mtime_ns=s.st_mtime_ns)!=record['sourceIdentity']:
                    raise ValueError('Persistent VM state changed after backup: '+name)
            else:
                if hashlib.sha256((vm/name).read_bytes()).hexdigest()!=record['sha256']:
                    raise ValueError('Static VM input changed: '+name)
        state=json.loads((WORK/'boot-window/helper-state.json').read_text())
        if state['state']!='running' or state['attempt']!=1 or state['deadline']-time.time()<200:
            raise ValueError('Single approved helper window is not ready')
        class Log:
            def record(self,target,payload,response):
                saved=dict(response)
                for field in ('data','image'):
                    if isinstance(saved.get(field),str):
                        data=base64.b64decode(saved.pop(field),validate=True)
                        saved[field+'Bytes']=len(data);saved[field+'SHA256']=hashlib.sha256(data).hexdigest()
                with (output/'requests.jsonl').open('a') as f:f.write(json.dumps(dict(request=payload,response=saved,time=time.time()))+'\n')
        env=os.environ.copy();env['VPHONE_API_TOKEN']=secrets.token_hex(32)
        command=[str(binary),'--config',str(vm/'config.plist'),'--no-vphoned-update','--api-listen','127.0.0.1:0']
        with (output/'serial.log').open('xb') as log:
            child=subprocess.Popen(command,cwd=vm,env=env,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        result.update(pid=child.pid,command=command,tokenStored=False)
        deadline=time.monotonic()+180
        while time.monotonic()<deadline:
            if child.poll() is not None:raise RuntimeError('VM exited before readiness')
            try:
                target=endpoint(vm.name,vm/'vphone.sock')
                caps=request(target,dict(t='capabilities'),Log(),5)
                if caps.get('guest_connected') and caps.get('screen_available'):break
            except (OSError,ValueError,RuntimeError):pass
            time.sleep(.25)
        else:raise RuntimeError('GUI/API readiness deadline')
        runtime=json.loads((vm/'.vphone-runtime.json').read_text())
        if runtime['pid']!=child.pid or runtime['operation']!='boot':raise ValueError('Runtime identity differs')
        result['runtime']=runtime
        marker.touch(exist_ok=True)
        until=time.monotonic()+15
        while not (WORK/'boot-window/amfid-cleanup.json').exists() and time.monotonic()<until:time.sleep(.1)
        cleanup=json.loads((WORK/'boot-window/amfid-cleanup.json').read_text())
        supervisor=json.loads((WORK/'boot-window/supervisor-stop.json').read_text())
        if not cleanup['passed'] or not supervisor['withinDeadline']:raise ValueError('Helper cleanup did not pass')
        for pid in [supervisor['workerPID'],supervisor['supervisorPID']]:
            if subprocess.run(['/bin/ps','-p',str(pid),'-o','pid='],capture_output=True).returncode==0:
                raise ValueError('Helper or supervisor still present')
        if subprocess.run(['/usr/bin/pgrep','-x','debugserver'],capture_output=True).returncode!=1:
            raise ValueError('Debugger remains')
        def call(payload):
            r=request(target,payload,Log(),20)
            if not r.get('ok'):raise RuntimeError(str(r))
            return r
        def rpc(method,params):return call(dict(t='rpc',method=method,params=params))['result']
        result['snapshot']=rpc('device.snapshot',{})
        hashes=[]
        for index in range(3):
            r=call(dict(t='file_get',path='/private/xarts/AA.gl'))
            data=base64.b64decode(r['data'],validate=True)
            hashes.append(dict(time=time.time(),bytes=len(data),sha256=hashlib.sha256(data).hexdigest()))
            time.sleep(1)
        result['gigalockerHashes']=hashes
        rpc('screen.unlock',{})
        rpc('apps.terminate',dict(bundle_id='com.apple.Preferences'))
        time.sleep(1)
        first=output/'before-settings.png';second=output/'settings.png'
        call(dict(t='screenshot',path=str(first)))
        rpc('apps.launch',dict(bundle_id='com.apple.Preferences'));time.sleep(2)
        foreground=rpc('apps.foreground',{})
        if foreground.get('bundle_id')!='com.apple.Preferences':raise ValueError('Settings foreground not confirmed')
        result['foreground']=foreground
        call(dict(t='screenshot',path=str(second)))
        result['display']=compare_images(first,second)
        rpc('apps.terminate',dict(bundle_id='com.apple.Preferences'))
        result['state']='observed'
    except Exception as error:result['error']=str(error)
    finally:
        marker.touch(exist_ok=True)
        if child is not None and child.poll() is None and target is not None:
            try:
                class StopLog:
                    def record(self,t,p,r):
                        with (output/'shutdown.jsonl').open('a') as f:f.write(json.dumps(dict(request=p,response=r))+'\n')
                result['shutdown']=request(target,dict(t='rpc',method='system.shutdown',params=dict(force=True)),StopLog(),20)
                result['vmExitCode']=child.wait(timeout=50)
            except Exception as error:result['shutdownError']=str(error)
        if child is not None:
            result['VMStillRunning']=child.poll() is None
            result['guestStopped']='Guest stopped' in (output/'serial.log').read_text(errors='replace')
        if output.exists():(output/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result));return 0 if result.get('state')=='observed' and result.get('guestStopped') and not result.get('VMStillRunning') else 1


if __name__=='__main__':raise SystemExit(main())
