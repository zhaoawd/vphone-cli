#!/usr/bin/env python3
"""Verify the named installation, change only t52-v2 host binding, then verify.

Run after the user-authenticated install script. This never starts a VM,
updates guest disks, changes AMFI, or overwrites an installed Core Bundle.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import time

root = Path(__file__).resolve().parents[3]
work = root / '.build/t52-api-proxy-deploy-20261022'
candidate = json.loads((work / 'candidate.json').read_text())
baseline = json.loads((work / 'pre-deployment.json').read_text())
vm = root / '.build/t51rt/lib/t52-v2'
checker = Path('/Library/Application Support/vphone-launchpad/Bundles/2.6.2-local.af333c78ac3b/VPhone.bundle/Contents/MacOS/vphone-cli')
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
assert digest(checker) == 'e297ce7989dba9bb2f810d398ddbc2c572f58f27d0213f7a75ea96e3de3f5a54'


def inspect_processes():
    processes = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,command='], text=True).splitlines()
    assert not any('/vphone-vm ' in line and str(vm / 'config.plist') in line for line in processes), 'Target running'
    original = [line.strip() for line in processes if '/vphone-vm ' in line and '/vm-2607/config.plist' in line]
    assert original == baseline['originalVM'], 'Original VM state changed'
    helpers = [line.strip() for line in processes if '/usr/bin/python' in line and '/scoped-amfidont.py' in line
               and not line.split(None, 2)[-1].startswith('/bin/zsh')]
    assert not helpers, 'Unexpected temporary helper'
    held = subprocess.run(['/usr/sbin/lsof', '-nP', '-t', '--', str(vm / 'Disk.img')], capture_output=True, text=True)
    assert held.returncode == 1 and not held.stdout and not held.stderr, 'Disk held or inspection failed'


def inspect_files(binding_changed):
    for machine, files in baseline['machines'].items():
        for name, before in files.items():
            if machine == 't52-v2' and name == 'launchpad.json' and binding_changed:
                continue
            path = root / '.build/t51rt/lib' / machine / name
            info = path.stat()
            after = dict(device=info.st_dev, inode=info.st_ino, size=info.st_size, mtimeNs=info.st_mtime_ns)
            if 'sha256' in before:
                after['sha256'] = digest(path)
            assert after == before, (machine, name)


def verify_bundle(version, label):
    result = subprocess.run([str(checker), 'core-bundle', 'verify', '--version', version],
                            check=True, capture_output=True, text=True)
    (work / (label + '-receipt.json')).write_text(result.stdout)
    return json.loads(result.stdout)


installed = Path(candidate['storeDestination']) / 'VPhone.bundle'
receipt = verify_bundle(candidate['version'], 'installed-user-verified')
assert receipt['sha256'] == candidate['archiveSHA256'] and receipt['cdhashes'] == candidate['cdhashes']
for name, key in [('vphone-cli', 'cliSHA256'), ('vphone-vm', 'vmSHA256')]:
    assert digest(installed / 'Contents/MacOS' / name) == candidate[key]
inspect_processes()
inspect_files(binding_changed=False)
assert digest(vm / 'launchpad.json') == baseline['bindingSHA256'], 'Binding differs from deployment selection'
with (work / 'binding-change.log').open('w') as log:
    subprocess.run([str(checker), 'vm', 'bind-core-bundle', 't52-v2', '--library-root', str(vm.parent),
        '--version', candidate['version'], '--expected-binding-sha256', baseline['bindingSHA256']],
        check=True, stdout=log, stderr=subprocess.STDOUT, timeout=60)
new_binding = json.loads((vm / 'launchpad.json').read_text())
expected = dict(baseline['binding'], bundle=candidate['version'])
assert new_binding == expected, 'Only the host selection may change'
inspect_processes()
inspect_files(binding_changed=True)
verify_bundle(candidate['version'], 'installed-final-verified')
verify_bundle('2.6.2-local.af333c78ac3b', 'baseline-final-verified')
result = dict(state='deployed_and_verified', observedAt=time.time(), sourceCommit=candidate['sourceCommit'],
    version=candidate['version'], archiveSHA256=candidate['archiveSHA256'],
    storeDestination=candidate['storeDestination'], installed=True, installedBytesVerified=True,
    bindingChanged=True, binding=new_binding, bindingSHA256=digest(vm / 'launchpad.json'),
    guestDiskMetadataAndConfigurationHashesPreserved=True, otherVMsPreserved=True,
    originalVM=baseline['originalVM'], targetVMRunning=False, diskReleased=True,
    previousBundlePreserved=True, guestResourcesUnchanged=True, frameworkLibrariesUnchanged=True,
    VMStarted=False, AMFIChanged=False, newVersionRuntimeNotTested=True, pushed=False)
(work / 'deployment-result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
