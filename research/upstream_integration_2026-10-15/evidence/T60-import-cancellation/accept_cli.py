"""Run against an explicitly supplied repository CLI, using only a temporary library."""
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tarfile
import tempfile
import time

binary = str(Path(sys.argv[1]).resolve())

def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def identity(pid):
    return subprocess.run(['/bin/ps','-p',str(pid),'-o','lstart=,comm='], capture_output=True, text=True).stdout.strip()

def children(pid):
    output = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,comm='], text=True)
    return [int(row.split(None, 2)[0]) for row in output.splitlines()
            if len(row.split(None, 2)) == 3 and int(row.split(None, 2)[1]) == pid
            and row.split(None, 2)[2] == '/usr/bin/tar']

with tempfile.TemporaryDirectory(prefix='vphone-import-cli-') as temporary:
    root = Path(temporary)
    archive = root / 'source.tar'
    manifest = plistlib.dumps(dict(platformType='vresearch101', machineIdentifier=b'abc', cpuCount=2,
        memorySize=2 << 30, screenConfig=dict(width=1290,height=2796,pixelsPerInch=460,scale=3.0),
        networkConfig=dict(mode='nat',macAddress=''), diskImage='Disk.img',nvramStorage='nvram.bin',sepStorage='SEPStorage'))
    with archive.open('wb') as stream:
        def member(name, data):
            entry=tarfile.TarInfo(name); entry.size=len(data)
            stream.write(entry.tobuf()); stream.write(data)
            stream.write(b'\0' * (-len(data) % 512))
        member('source/config.plist', manifest)
        entry=tarfile.TarInfo('source/Disk.img'); entry.size=1 << 30
        stream.write(entry.tobuf()); stream.seek(entry.size, 1)
        member('source/marker', b'original archive data')
        stream.write(b'\0' * 1024)
    before = digest(archive)
    for backend in (() if '--normal-only' in sys.argv else ('system-tar','native')):
        for number in (signal.SIGINT, signal.SIGTERM):
            library = root / f'{backend}-{number}'; library.mkdir()
            existing=library/'existing'; existing.mkdir(); (existing/'marker').write_bytes(b'keep')
            command=[binary,'vm','import',str(archive),'--library-root',str(library),'--name','copy','--archive-backend',backend]
            process=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            owned=[]
            identities={}
            try:
                deadline=time.monotonic()+20
                while not list(library.glob('.import-*/contents/source/Disk.img')):
                    assert process.poll() is None, process.communicate()
                    assert time.monotonic()<deadline, 'no active extraction'
                    time.sleep(.002)
                process.send_signal(signal.SIGSTOP)
                owned=children(process.pid)
                identities={pid:identity(pid) for pid in owned}
                if backend == 'system-tar':
                    assert owned, 'tar child already exited before cancellation injection'
                    for pid in owned: os.kill(pid, signal.SIGSTOP)
                # Resume a transfer whose tar consumer is stopped: cancellation must
                # unblock its pipe write and reap that child, not merely set a flag.
                process.send_signal(number); process.send_signal(signal.SIGCONT)
                out,err=process.communicate(timeout=25)
                remaining=list(library.glob('.import-*'))
                alive=[]
                for pid in owned:
                    if identity(pid)==identities[pid]: alive.append(pid)
                result=dict(backend=backend,signal=int(number),exit=process.returncode,
                    staging=len(remaining),published=(library/'copy').exists(),tar_alive=alive,
                    existing_unchanged=(existing/'marker').read_bytes()==b'keep')
                print(json.dumps(result), flush=True)
                assert process.returncode==128+number, (out,err)
                assert not remaining and not result['published'] and not alive
                assert result['existing_unchanged']
            finally:
                if process.poll() is None: process.kill(); process.wait()
                for pid in owned:
                    if identity(pid)==identities[pid]:
                        try: os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError: pass
    normal_archive=root/'normal.tar'
    with tarfile.open(normal_archive,'w') as writer:
        for name,data in [('source/config.plist',manifest),('source/Disk.img',b'normal data')]:
            entry=tarfile.TarInfo(name); entry.size=len(data)
            writer.addfile(entry,io.BytesIO(data))
    for backend in ('system-tar','native'):
        library=root/f'normal-{backend}'
        result=subprocess.run([binary,'vm','import',str(normal_archive),'--library-root',str(library),
            '--name','copy','--archive-backend',backend],capture_output=True,timeout=20)
        assert result.returncode==0, result.stderr
        assert (library/'copy'/'Disk.img').read_bytes()==b'normal data'
        assert not list(library.glob('.import-*'))
        print(json.dumps(dict(backend=backend,normal_import=True,exit=result.returncode,staging=0)),flush=True)
    assert digest(archive)==before
    print(json.dumps(dict(source_archive_sha256=before,source_unchanged=True)), flush=True)
