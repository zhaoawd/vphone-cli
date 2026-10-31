#!/usr/bin/env python3
"""Read-only host checks after the approved default GUI acceptance."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import time

root = Path(__file__).resolve().parents[3]
work = root / '.build/t52-real-20261021/gui-shutdown-fix'
vm = root / '.build/t51rt/lib/t52-v2'
candidate = json.loads((work / 'candidate.json').read_text())
helper = json.loads((work / 'boot-window/helper-state.json').read_text())
stopped = json.loads((work / 'default-shutdown-result.json').read_text())
assert stopped['state'] == 'passed' and not stopped['forcedFrameworkStop']
assert helper['state'] == 'stopped' and helper['attempt'] == 1
assert helper['cdhash'] == candidate['signatures']['vphone-vm'] and helper['stoppedAt'] < helper['deadline']
processes = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,command='], text=True).splitlines()
assert not any(line.split(None, 2)[0] == str(helper['pid']) for line in processes if line.split()), 'Helper PID remains'
assert not any('/vphone-vm ' in line and str(vm / 'config.plist') in line for line in processes), 'Target remains running'
original = [line for line in processes if line.strip().startswith('33355 ') and '/vphone-vm ' in line and '/vm-2607/config.plist' in line]
assert len(original) == 1
images = plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist']))
attached = [item.get('image-path') for item in images.get('images', []) if str(vm) in item.get('image-path', '')]
assert not attached
baseline = json.loads((work.parent / 'protected-vms-final.json').read_text())['machines']
protected = {}
for machine, files in baseline.items():
    protected[machine] = {}
    for name, item in files.items():
        path = root / '.build/t51rt/lib' / machine / name
        if item.get('stillAbsent'):
            assert not path.exists() and not path.is_symlink(), (machine, name)
            protected[machine][name] = dict(stillAbsent=True)
            continue
        info = path.stat()
        old = item['actual']
        actual = dict(device=info.st_dev, inode=info.st_ino, size=info.st_size, mtimeNs=info.st_mtime_ns)
        if 'sha256' in old:
            actual['sha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        assert actual == old, (machine, name, actual, old)
        protected[machine][name] = dict(unchanged=True, actual=actual)
(work / 'protected-vms-final.json').write_text(json.dumps(dict(observedAt=time.time(), machines=protected), indent=2) + '\n')
checker = Path('/Library/Application Support/vphone-launchpad/Bundles/2.6.2-local.cd529f26a150/VPhone.bundle/Contents/MacOS/vphone-cli')
for version, label in [('2.6.2-local.cd529f26a150', 'old'), (candidate['version'], 'new')]:
    result = subprocess.run([str(checker), 'core-bundle', 'verify', '--version', version], capture_output=True, text=True, check=True)
    receipt = json.loads(result.stdout)
    if label == 'new':
        assert receipt['sha256'] == candidate['archiveSHA256'] and receipt['cdhashes'] == candidate['signatures']
    (work / (label + '-bundle-final-verified.json')).write_text(result.stdout)
serial = root / '.build/t52-entrypoints-20261021/ui-logs/t52-v2.log'
(work / 'default-shutdown-serial.log').write_bytes(serial.read_bytes())
cleanup = dict(observedAt=time.time(), state='passed', scopedHelperStopped=True, helperPIDAbsent=True,
    targetVMStopped=True, attachedTargetImages=attached, protectedOriginalVM=original[0].strip(),
    helperSeconds=helper['stoppedAt'] - helper['startedAt'], maxSeconds=600, attachments=1,
    persistentAllowlistChanged=False, systemBundlesVerified=['2.6.2-local.cd529f26a150', candidate['version']],
    protectedVMsPreserved=True)
(work / 'final-cleanup.json').write_text(json.dumps(cleanup, indent=2) + '\n')
(work / 'boot-window/cleanup.json').write_text(json.dumps(dict(state=helper, independentlyConfirmedAbsent=True,
    stoppedBeforeDeadline=True, persistentAllowlistChanged=False), indent=2) + '\n')
print(json.dumps(cleanup, indent=2))
