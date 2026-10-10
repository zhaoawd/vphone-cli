#!/usr/bin/env python3
"""按本轮批准对源 VM 发一次 SIGINT；不停止监测程序，不强制终止。"""
import json
import os
from pathlib import Path
import signal
import subprocess
import time

repo = Path(__file__).resolve().parents[5]
vm = repo / 'vm-new'
evidence = Path(__file__).resolve().parent
state = json.loads((vm / '.vphone-runtime.json').read_text())
pid = state['pid']
command = subprocess.check_output(['ps', '-p', str(pid), '-o', 'command='], text=True).strip()
assert '/vphone-vm --config ' in command and '/vm-new/config.plist' in command
before = subprocess.run(['lsof', str(vm / 'Disk.img')], capture_output=True, text=True)
assert before.returncode == 0
result = {'authorized': 'normal shutdown only; pause if automatically restarted', 'initial_runtime': state, 'command': command, 'before_disk_handles': before.stdout, 'signal': 'SIGINT', 'samples': []}
os.kill(pid, signal.SIGINT)
start = time.monotonic()
quiet_since = None
while time.monotonic() - start < 50:
    st = os.statvfs(repo)
    assert st.f_bavail * st.f_frsize >= 5 * 1024**3, 'STOP: disk below 5 GiB'
    current = json.loads((vm / '.vphone-runtime.json').read_text())
    handles = subprocess.run(['lsof', str(vm / 'Disk.img')], capture_output=True, text=True)
    process = subprocess.run(['ps', '-p', str(pid), '-o', 'pid=,stat=,command='], capture_output=True, text=True)
    row = {'seconds': time.monotonic() - start, 'runtime_pid': current['pid'], 'source_disk_handles': handles.stdout, 'initial_process': process.stdout}
    result['samples'].append(row)
    if current['pid'] != pid and handles.returncode == 0:
        result['result'] = 'source_restarted_pause_experiment'
        break
    if handles.returncode == 1 and not handles.stdout and not handles.stderr and not process.stdout:
        quiet_since = quiet_since or time.monotonic()
        if time.monotonic() - quiet_since >= 10:
            result['result'] = 'stopped_and_quiet_for_10_seconds'
            break
    else:
        quiet_since = None
    time.sleep(0.5)
else:
    result['result'] = 'normal_stop_not_confirmed_pause_experiment'
(evidence / 'source-normal-stop.json').write_text(json.dumps(result, indent=2) + '\n')
print(result['result'])
assert result['result'] == 'stopped_and_quiet_for_10_seconds'
