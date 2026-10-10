#!/usr/bin/env python3
"""仅清理本轮已记录的驱动；SIGINT 未退出时结束该辅助进程。"""
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import time

repo = Path(__file__).resolve().parents[5]
run = repo / '.build/research-b36'
record = json.loads((run / 'amfi-process.json').read_text())
assert os.geteuid() == 0
pid = record['driver_pid']

def alive():
    result = subprocess.run(['ps', '-p', str(pid), '-o', 'ppid=,stat=,command='],
                            capture_output=True, text=True)
    if result.returncode != 0:
        return False
    parent, state, command = result.stdout.strip().split(None, 2)
    if 'Z' in state:
        return False
    assert int(parent) == record['supervisor_pid']
    assert shlex.split(command)[-3:] == ['-u', record['driver'], '--run']
    return True

signals = []
if alive():
    os.kill(pid, signal.SIGINT)
    signals.append('SIGINT')
    time.sleep(2)
if alive():
    os.kill(pid, signal.SIGTERM)
    signals.append('SIGTERM')
for _ in range(40):
    if not alive():
        break
    time.sleep(.25)
if alive():
    os.kill(pid, signal.SIGKILL)
    signals.append('SIGKILL')
    for _ in range(40):
        if not alive():
            break
        time.sleep(.25)
rows = subprocess.check_output(['ps', '-axo', 'pid=,ppid=,stat=,comm='], text=True).splitlines()
result = dict(at=time.time(), driver_pid=pid, signals=signals, driver_gone=not alive(),
              debugserver=[x.strip() for x in rows if '/debugserver' in x],
              amfid=[x.strip() for x in rows if '/usr/libexec/amfid' in x])
(run / 'amfi-cleanup.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps(result))
assert result['driver_gone']
