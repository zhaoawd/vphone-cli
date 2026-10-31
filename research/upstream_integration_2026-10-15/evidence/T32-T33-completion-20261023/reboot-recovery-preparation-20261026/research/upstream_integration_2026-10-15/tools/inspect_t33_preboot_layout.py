#!/usr/bin/env python3
"""Inspect only Preboot path metadata on the stopped EXP disk, mounted readonly."""
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import sys
import time

ROOT=Path(__file__).resolve().parents[3]
WORK=ROOT/'.build/t32-t33-completion-20261023/exp-bounded-preflight-20261024'


def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as stream:
        while block:=stream.read(1<<20):h.update(block)
    return h.hexdigest()


def main():
    if os.geteuid()!=0:raise ValueError('Native readonly mount authentication required')
    for name,digest in json.loads((WORK/'preboot-layout-inputs.json').read_text()).items():
        if sha(name)!=digest:raise ValueError('Readonly inspection code changed')
    sys.path.insert(0,str(ROOT/'scripts'))
    import cfw_verify_effects as audit
    import cfw_disk_txn as txn
    vm=ROOT/'.build/t33q-20261024';before=(vm/'Disk.img').stat();started=time.monotonic()
    result=dict(scope='preboot readonly metadata and named SystemVersion fields',VMStarts=0,CFWWrites=0,securityWindows=0)
    def describe(path,root):
        s=path.lstat();row=dict(path=str(path.relative_to(root)),mode=stat.S_IMODE(s.st_mode),nlink=s.st_nlink,
                                kind='symlink' if stat.S_ISLNK(s.st_mode) else 'directory' if stat.S_ISDIR(s.st_mode) else 'file' if stat.S_ISREG(s.st_mode) else 'special')
        if stat.S_ISLNK(s.st_mode):row['link']=os.readlink(path)
        return row
    def expired(*_):raise TimeoutError('Preboot metadata scan exceeded 20 seconds')
    try:
        with audit.locked_vm(vm):
            txn.require_unheld(vm/'Disk.img',os.getpid(),'readonly Preboot inspection disk')
            with audit.readonly_roots(vm/'Disk.img',{'preboot'},Path('/private/tmp')) as (roots,recheck):
                root=roots['preboot'];result['rootEntries']=[describe(p,root) for p in sorted(root.iterdir())]
                components=[];relative=Path('Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist')
                for count in range(1,len(relative.parts)+1):
                    path=root/Path(*relative.parts[:count])
                    if not os.path.lexists(path):components.append(dict(path=str(path.relative_to(root)),kind='missing'));break
                    row=describe(path,root);components.append(row)
                    if row['kind']=='symlink':break
                result['requestedPathComponents']=components
                signal.signal(signal.SIGALRM,expired);signal.setitimer(signal.ITIMER_REAL,20)
                interesting=[];visited=0
                try:
                    for directory,dirs,files in os.walk(root,followlinks=False):
                        relative_dir=Path(directory).relative_to(root)
                        if len(relative_dir.parts)>10:dirs[:]=[];continue
                        visited+=len(dirs)+len(files)
                        if visited>20000:raise ValueError('Preboot metadata scan exceeded 20000 entries')
                        for name in sorted(dirs+files):
                            if name in {'Cryptexes','OS','cryptex1','current','SystemVersion.plist'}:
                                interesting.append(describe(Path(directory)/name,root))
                finally:signal.setitimer(signal.ITIMER_REAL,0)
                result.update(relevantEntries=interesting,visitedEntries=visited);recheck()
        result['normalUnmountPassed']=True
    except Exception as error:result['error']=str(error)
    after=(vm/'Disk.img').stat();result['diskIdentityUnchanged']=all(getattr(before,k)==getattr(after,k) for k in ('st_dev','st_ino','st_size','st_mtime_ns','st_ctime_ns'))
    result['elapsedSeconds']=time.monotonic()-started
    output=WORK/'preboot-layout.json'
    with output.open('x') as stream:json.dump(result,stream,indent=2);stream.write('\n')
    os.chown(output,501,20);print(json.dumps(result),flush=True)
    return 0 if result.get('normalUnmountPassed') and result['diskIdentityUnchanged'] else 1


if __name__=='__main__':raise SystemExit(main())
