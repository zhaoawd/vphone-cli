#!/usr/bin/env python3
"""Read stage checkpoints and selected process state for the isolated T52 run."""
import json
from pathlib import Path
import subprocess
import time

root = Path(__file__).resolve().parents[3]
work = root / '.build/t52-real-20261021'
vm = root / '.build/t51rt/lib/t52-v2'
checkpoint = json.loads((vm / '.create-checkpoint/checkpoint.json').read_text())
rows = []
output = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,etime=,command='], text=True)
processes = []
for line in output.splitlines():
    fields = line.split(None, 3)
    if len(fields) != 4:
        continue
    pid, parent, elapsed, command = fields
    processes.append((int(pid), int(parent), elapsed, command))
owned = {pid for pid, _, _, command in processes
         if (' vm create t52-v2 ' in command and command.startswith('/Library/'))
         or (command.startswith('/bin/zsh ') and 'cfw_install_host.sh ' in command and str(vm) in command)}
while True:
    descendants = {pid for pid, parent, _, _ in processes if parent in owned}
    if descendants.issubset(owned):
        break
    owned.update(descendants)
for pid, parent, elapsed, command in processes:
    if (str(vm) not in command and pid not in owned) or '/bin/zsh -c ' in command or '/usr/bin/osascript ' in command:
        continue
    # Keep the active leaf operation; fixed resource/module paths identify it.
    if 'plan_gate.py ' in command:
        command = 'plan_gate.py ' + command.split('plan_gate.py ', 1)[1]
    elif 'cfw_disk_txn.py ' in command:
        command = 'cfw_disk_txn.py ' + command.split('cfw_disk_txn.py ', 1)[1]
    elif 'cfw_env_install.py ' in command:
        command = 'cfw_env_install.py ' + command.split('cfw_env_install.py ', 1)[1]
    elif ' verify-plan ' in command:
        command = 'cfw verify-plan'
    elif '/vphone-vm ' in command:
        command = 'vphone-vm ' + command.split('/vphone-vm ', 1)[1]
    elif 'cfw_install_host.sh ' in command or 'vm create ' in command:
        continue
    else:
        continue
    rows.append(dict(pid=int(pid), parent=int(parent), elapsed=elapsed, command=command[:400]))
result = dict(observedAt=time.time(), stages=[dict(stage=row['stage'], status=row['status'], error=row.get('error'))
              for row in checkpoint['stages']], processes=rows)
with (work / 'cfw-fix/monitor.jsonl').open('a') as stream:
    stream.write(json.dumps(result) + '\n')
print(json.dumps(result, indent=2))
