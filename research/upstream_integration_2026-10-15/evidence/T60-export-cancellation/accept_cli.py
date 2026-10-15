"""Temporary-library export acceptance; never boots or edits an installed VM."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time

binary=str(Path(sys.argv[1]).resolve())

def digest(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream,'sha256').hexdigest()

def identity(pid):
    return subprocess.run(['/bin/ps','-p',str(pid),'-o','lstart=,comm='],capture_output=True,text=True).stdout.strip()

def children(pid):
    rows=subprocess.check_output(['/bin/ps','-axo','pid=,ppid=,comm='],text=True).splitlines()
    return [int(parts[0]) for row in rows if len(parts:=row.split(None,2))==3
            and int(parts[1])==pid and parts[2]=='/usr/bin/tar']

with tempfile.TemporaryDirectory(prefix='vphone-export-cli-') as temporary:
    root=Path(temporary); library=root/'library'; source=library/'source'; source.mkdir(parents=True)
    manifest=plistlib.dumps(dict(platformType='vresearch101',machineIdentifier=b'abc',cpuCount=2,
        memorySize=2<<30,screenConfig=dict(width=1290,height=2796,pixelsPerInch=460,scale=3.0),
        networkConfig=dict(mode='nat',macAddress=''),diskImage='Disk.img',nvramStorage='nvram.bin',sepStorage='SEPStorage'))
    (source/'config.plist').write_bytes(manifest)
    disk=source/'Disk.img'
    chunk=os.urandom(1<<20)
    with disk.open('wb') as stream:
        for _ in range(256): stream.write(chunk)
    before=digest(disk); manifest_before=digest(source/'config.plist')
    for backend in ('system-tar','native'):
        for number in (signal.SIGINT,signal.SIGTERM):
            work=root/f'{backend}-{number}'; work.mkdir()
            output=work/'export.tzst'
            sentinel=work/'existing.tzst'; sentinel.write_bytes(b'keep existing archive')
            process=subprocess.Popen([binary,'vm','export','source','--library-root',str(library),
                '--out',str(output),'--archive-backend',backend],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            owned=[]; identities={}; role=None
            try:
                deadline=time.monotonic()+20
                while not any(p.is_file() and p.stat().st_size>0 for p in work.glob('.vphone-export-*/**/output')):
                    assert process.poll() is None, process.communicate()
                    assert time.monotonic()<deadline, 'no provisional archive data'
                    time.sleep(.002)
                assert not output.exists(), 'published before transfer completion'
                process.send_signal(signal.SIGSTOP)
                owned=children(process.pid); identities={pid:identity(pid) for pid in owned}
                if backend=='system-tar':
                    assert len(owned)==2, ('expected producer and consumer',owned)
                    role='consumer' if number==signal.SIGINT else 'producer'
                    selected=[]
                    for pid in owned:
                        command=subprocess.check_output(['/bin/ps','-p',str(pid),'-o','args='],text=True)
                        if ('--format' in command)==(role=='producer'): selected.append(pid)
                    assert len(selected)==1, (role,selected)
                    os.kill(selected[0],signal.SIGSTOP)
                process.send_signal(number); process.send_signal(signal.SIGCONT)
                out,err=process.communicate(timeout=25)
                alive=[pid for pid in owned if identity(pid)==identities[pid]]
                result=dict(backend=backend,signal=int(number),blocked_role=role,exit=process.returncode,
                    staging=len(list(work.glob('.vphone-export-*'))),published=output.exists(),tar_alive=alive,
                    existing_unchanged=sentinel.read_bytes()==b'keep existing archive')
                print(json.dumps(result),flush=True)
                assert process.returncode==128+number,(out,err)
                assert result['staging']==0 and not result['published'] and not alive and result['existing_unchanged']
            finally:
                if process.poll() is None: process.kill(); process.wait()
                for pid in owned:
                    if identity(pid)==identities[pid]:
                        try: os.kill(pid,signal.SIGKILL)
                        except ProcessLookupError: pass
    assert digest(disk)==before and digest(source/'config.plist')==manifest_before
    print(json.dumps(dict(source_disk_sha256=before,source_manifest_sha256=manifest_before,source_unchanged=True)),flush=True)
    small=library/'small'; small.mkdir(); (small/'config.plist').write_bytes(manifest)
    (small/'Disk.img').write_bytes(b'normal exported data')
    for backend in ('system-tar','native'):
        work=root/f'normal-{backend}'; work.mkdir()
        output=work/'small.tzst'
        result=subprocess.run([binary,'vm','export','small','--library-root',str(library),
            '--out',str(work),'--archive-backend',backend],capture_output=True,timeout=20)
        assert result.returncode==0,result.stderr
        imported=root/f'imported-{backend}'
        result=subprocess.run([binary,'vm','import',str(output),'--library-root',str(imported),
            '--name','copy','--archive-backend',backend],capture_output=True,timeout=20)
        assert result.returncode==0,result.stderr
        assert (imported/'copy'/'Disk.img').read_bytes()==b'normal exported data'
        assert not list(work.glob('.vphone-export-*'))
        print(json.dumps(dict(backend=backend,normal_export_import=True,staging=0)),flush=True)
