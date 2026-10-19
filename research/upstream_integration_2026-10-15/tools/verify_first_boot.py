#!/usr/bin/env python3
"""Run the repository's first-boot sequence on an independent T32/T33 VM.

Commands and prompt/panic expressions come from VPhoneBootPatterns.swift.
Requires a new output directory and records actual serial shutdown evidence.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vm', required=True, type=Path)
    parser.add_argument('--vm-executable', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    vm, binary, out = args.vm.resolve(strict=True), args.vm_executable.resolve(strict=True), args.out.resolve()
    if vm.parent != ROOT or not vm.name.startswith('vm-t32-t33-'):
        raise ValueError('first boot is scoped to independent T32/T33 VMs')
    out.mkdir()
    source = ROOT/'sources/VPhoneCore/VPhoneBootPatterns.swift'
    text = source.read_text()
    commands = [json.loads(line.strip().removesuffix(',')) for line in
        text.split('public static let firstBootCommands: [String] = [',1)[1].split('\n    ]',1)[0].splitlines() if line.strip()]
    if len(commands) != 7 or commands[-1] != 'shutdown -h now':
        raise ValueError('first-boot command contract differs; review production sequence')
    prompt = re.search(r'public static let promptRegex = #"(.+)"#',text)[1]
    panic = re.search(r'public static let panicRegex = #"(.+)"#',text)[1]
    env = dict(os.environ, VPHONE_ROOT=str(out/'user-root'), VPHONE_PYTHON=str(ROOT/'.venv/bin/python3'))
    result = dict(schemaVersion=1,state='running',vm=str(vm),productionPatternsSHA256=hashlib.sha256(source.read_bytes()).hexdigest(),
                  commands=commands,commandsSent=0,promptMatched=False)
    preserved = {name:hashlib.sha256((vm/name).read_bytes()).hexdigest() for name in ('config.plist','.vphoned.signed')}
    def save(): (out/'result.json').write_text(json.dumps(result,indent=2)+'\n')
    save()
    try:
        with (out/'serial.log').open('wb') as log:
            child = subprocess.Popen([str(binary),'--config',str(vm/'config.plist'),'--headless','--no-vphoned-update'],
                cwd=vm,env=env,stdin=subprocess.PIPE,stdout=log,stderr=subprocess.STDOUT)
            result['pid'] = child.pid
            try:
                deadline = time.monotonic()+120
                while time.monotonic() < deadline:
                    serial = (out/'serial.log').read_text(errors='replace')
                    if re.search(panic,serial,re.I): raise RuntimeError('panic while waiting for first-boot prompt')
                    if re.search(prompt,serial): break
                    if child.poll() is not None: raise RuntimeError(f'VM exited before first-boot prompt: {child.returncode}')
                    time.sleep(1)
                else: raise RuntimeError('first-boot prompt deadline')
                result['promptMatched'] = True; save()
                for command in commands:
                    child.stdin.write((command+'\n').encode()); child.stdin.flush()
                    result['commandsSent'] += 1
                result['exitCode'] = child.wait(timeout=180)
            finally:
                if child.poll() is None:
                    child.send_signal(__import__('signal').SIGINT)
                    child.wait(timeout=50)
                child.stdin.close()
        serial = (out/'serial.log').read_text(errors='replace')
        result['guestStopped'] = 'Guest stopped' in serial
        result['forcedFrameworkStop'] = any(value in serial for value in ('graceful shutdown timed out','[vphone] VM stopped'))
        assert result['exitCode'] == 0 and result['guestStopped'] and not result['forcedFrameworkStop'], result
        held = subprocess.run(['/usr/sbin/lsof','-nP','-t','--',str(vm/'Disk.img')],capture_output=True,text=True,timeout=10)
        assert held.returncode == 1 and not held.stdout and not held.stderr, held
        fd = os.open(vm,os.O_RDONLY|os.O_DIRECTORY)
        try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        finally: os.close(fd)
        assert all(hashlib.sha256((vm/name).read_bytes()).hexdigest() == digest for name,digest in preserved.items())
        result.update(state='passed',diskAndDirectoryLockReleased=True,configAndDaemonUnchanged=True)
    except Exception as error:
        result.update(state='failed',error=f'{type(error).__name__}: {error}')
        raise
    finally: save()
    print(json.dumps(result))


if __name__ == '__main__': main()
