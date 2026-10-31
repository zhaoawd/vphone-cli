#!/usr/bin/env python3
"""Run bounded read-only EXP source checks; never install or start a VM."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
import time

ROOT=Path(__file__).resolve().parents[3]
BASE=ROOT/'.build/t32-t33-completion-20261023'
OUT=BASE/'exp-bounded-preflight-20261024'
CACHE=ROOT/'.build/t33q-20261024/.cfw_temp/CryptexSystemOS.dmg'
BUNDLE=BASE/'exp-cryptex-links-package-20261024-r3/VPhone.bundle'
sys.path.insert(0,str(ROOT/'scripts'))
import cfw_verify_effects as audit
from patchers import cryptex_source


def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as stream:
        while block:=stream.read(1<<20):h.update(block)
    return h.hexdigest()


def bounded(name,argv):
    started=time.monotonic();timed_out=False;sent=[]
    env=dict(os.environ,PATH='/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin',PYTHONDONTWRITEBYTECODE='1')
    with (OUT/(name+'.log')).open('xb') as log:
        child=subprocess.Popen([str(x) for x in argv],stdout=log,stderr=subprocess.STDOUT,
                               env=env,start_new_session=True,stdin=subprocess.DEVNULL)
        try:child.wait(timeout=45)
        except subprocess.TimeoutExpired:
            timed_out=True
            if os.getpgid(child.pid)!=child.pid:raise ValueError('Diagnostic process group identity differs')
            os.killpg(child.pid,signal.SIGTERM);sent.append('TERM')
            try:child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid,signal.SIGKILL);sent.append('KILL');child.wait(timeout=3)
    row=dict(command=[str(x) for x in argv],exitCode=child.returncode,elapsedSeconds=time.monotonic()-started,
             deadlineSeconds=45,timedOut=timed_out,signalsToOwnedDiagnosticGroup=sent)
    print(json.dumps(dict(step=name,**row)),flush=True)
    return row


def main():
    OUT.mkdir();result=dict(scope='readonly retained cache; source algorithms only',VMStarts=0,
                           securityWindows=0,CFWInstalled=False,steps={},passed=False)
    expected=json.loads((BASE/'exp-cryptex-links-acceptance-20261024/current-target-snapshot.json').read_text())
    with audit.locked_vm(CACHE.parent.parent):
        before=CACHE.stat();digest=sha(CACHE)
        if digest!=expected['files']['.cfw_temp/CryptexSystemOS.dmg']['sha256']:
            raise ValueError('Retained cache changed after prepared baseline')
        mount=Path(tempfile.mkdtemp(prefix='t33-ro-preflight-',dir='/private/tmp'));device=None
        try:
            attached=subprocess.run(['/usr/bin/hdiutil','attach','-readonly','-nobrowse','-owners','off',
                '-plist','-mountpoint',str(mount),str(CACHE)],capture_output=True,check=True,timeout=30)
            (OUT/'attach.plist').write_bytes(attached.stdout)
            info=plistlib.loads(attached.stdout);device=info['system-entities'][0]['dev-entry']
            if not os.statvfs(mount).f_flag & os.ST_RDONLY:raise ValueError('Cache mount is writable')
            start=time.monotonic();tree=cryptex_source.tree(mount)
            result['tree']=dict(entries=len(tree),sha256=hashlib.sha256(cryptex_source.gate.canonical(tree)).hexdigest(),
                                elapsedSeconds=time.monotonic()-start)
            chunks=mount/'System/Library/Caches/com.apple.dyld';header=chunks/'dyld_shared_cache_arm64e'
            entry=BUNDLE/'Contents/Resources/scripts/patchers/cfw.py';python=ROOT/'.venv/bin/python3'
            commands=[('hv-vmm',[python,'-B',entry,'patch-hv-vmm-dsc',chunks,'--dry-run']),
                      ('camera',[python,'-B',entry,'patch-camera-dsc',chunks,header,'--dry-run']),
                      ('swapend',[python,'-B',entry,'patch-iomfb-swapend',chunks,'--target-size','0x560','--dry-run']),
                      ('build-plist',[python,'-B',entry,'patch-build-version',
                        mount/'System/Library/CoreServices/SystemVersion.plist','23Z999999','--dry-run'])]
            for name,argv in commands:
                row=bounded(name,argv);result['steps'][name]=row
                if row['timedOut'] or row['exitCode']!=0:raise ValueError('Read-only source check failed: '+name)
                text=(OUT/(name+'.log')).read_text()
                if name=='hv-vmm':
                    matched=re.search(r'DSC patch complete: (\d+) cstring',text)
                    if matched is None or int(matched[1])==0:raise ValueError('hv_vmm source check found no planned effects')
                    row['plannedCStringChanges']=int(matched[1])
            start=time.monotonic();after_tree=cryptex_source.tree(mount)
            if tree!=after_tree:raise ValueError('Source tree changed during dry runs')
            result['treeUnchanged']=True;result['finalTreeReadSeconds']=time.monotonic()-start
            result['passed']=True
        except Exception as error:result['error']=str(error)
        finally:
            if device is not None:
                detached=subprocess.run(['/usr/bin/hdiutil','detach',device],capture_output=True,text=True,timeout=30)
                result['normalDetach']=dict(device=device,exitCode=detached.returncode,stdout=detached.stdout,stderr=detached.stderr)
                detached.check_returncode()
            after=CACHE.stat();result['cacheSHA256After']=sha(CACHE)
            result['cacheBytesUnchanged']=result['cacheSHA256After']==digest and before==after
            if not result['cacheBytesUnchanged']:result['passed']=False
            (OUT/'cache-preflight.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result),flush=True)
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
