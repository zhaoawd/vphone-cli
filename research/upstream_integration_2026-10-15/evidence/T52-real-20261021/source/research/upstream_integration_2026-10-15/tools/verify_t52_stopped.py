#!/usr/bin/env python3
"""Verify normal shutdown of the observed T52 instance without sending signals."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

root = Path(__file__).resolve().parents[3]
work = root / '.build/t52-real-20261021'
vm = root / '.build/t51rt/lib/t52-v2'
parser = argparse.ArgumentParser()
parser.add_argument('--serial', type=Path, default=root / '.build/t52-entrypoints-20261021/ui-logs/t52-v2.log')
parser.add_argument('--runtime', type=Path, default=work / 'post-update-runtime.json')
parser.add_argument('--output', type=Path, default=work / 'post-update-stop-result.json')
args = parser.parse_args()
runtime = json.loads(args.runtime.read_text())
serial_path = args.serial
deadline = time.monotonic() + 50
while time.monotonic() < deadline:
    process = subprocess.run(['/bin/ps', '-p', str(runtime['pid']), '-o', 'command='], capture_output=True, text=True)
    if str(vm / 'config.plist') not in process.stdout:
        break
    time.sleep(.5)
else:
    raise RuntimeError('Observed VM process did not stop within 50 seconds')
serial = serial_path.read_text(errors='replace')
guest_stopped = 'Guest stopped' in serial
forced = any(value in serial for value in ('graceful shutdown timed out', 'no graceful shutdown path available', '[vphone] VM stopped'))
assert guest_stopped and not forced, 'Normal guest shutdown marker missing or forced fallback observed'
holders = subprocess.run(['/usr/sbin/lsof', '-nP', '-t', '--', str(vm / 'Disk.img')], capture_output=True, text=True)
assert holders.returncode == 1 and not holders.stdout and not holders.stderr, 'Disk holders remain'
fd = os.open(vm, os.O_RDONLY | os.O_DIRECTORY)
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
finally:
    os.close(fd)
before = json.loads((work / 'metadata-after.json').read_text())['files']
preserved = {name: hashlib.sha256((vm / name).read_bytes()).hexdigest() == before[name]['sha256']
             for name in ('config.plist', 'launchpad.json', 'restore-info.json', 'udid-prediction.txt')}
assert all(preserved.values()), preserved
result = dict(state='passed', observedAt=time.time(), instanceID=runtime['instanceID'], pid=runtime['pid'],
              guestStopped=guest_stopped, forcedFrameworkStop=forced, diskReleased=True, directoryLockFree=True,
              preserved=preserved, serialPath=str(serial_path))
args.output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
