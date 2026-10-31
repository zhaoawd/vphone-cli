#!/usr/bin/env python3
"""Observe a GUI-started/stopped T52 candidate; never launch or signal a VM."""
import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(root / 'scripts'))
from host_control_client import endpoint, request
from t52_serial_evidence import read_launch_serial

vm = root / '.build/t51rt/lib/t52-v2'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('phase', choices=('prepare', 'running', 'stopped'))
parser.add_argument('--serial', type=Path, default=root / '.build/t52-entrypoints-20261021/ui-logs/t52-v2.log')
parser.add_argument('--work', type=Path, default=root / '.build/t52-real-20261021/gui-shutdown-fix')
parser.add_argument('--component-comparison', type=Path,
                    default=root / '.build/t52-real-20261021/component-comparison.json')
args = parser.parse_args()
work = args.work
candidate = json.loads((work / 'candidate.json').read_text())
binary = Path(candidate['storeDestination']) / 'VPhone.bundle/Contents/MacOS/vphone-vm'
digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()


def save(name, value):
    (work / name).write_text(json.dumps(value, indent=2) + '\n')


def metadata():
    return {name: digest(vm / name) for name in ('config.plist', 'launchpad.json', 'restore-info.json', 'udid-prediction.txt')}


class Recorder:
    def record(self, target, payload, response):
        recorded = dict(response)
        if isinstance(recorded.get('data'), str):
            data = base64.b64decode(recorded.pop('data'), validate=True)
            recorded['capturedData'] = dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
        with (work / 'default-shutdown-requests.jsonl').open('a') as stream:
            stream.write(json.dumps(dict(time=time.time(), request=payload, response=recorded)) + '\n')


recorder = Recorder()


def released():
    holders = subprocess.run(['/usr/sbin/lsof', '-nP', '-t', '--', str(vm / 'Disk.img')], capture_output=True, text=True)
    assert holders.returncode == 1 and not holders.stdout and not holders.stderr, 'Disk is held or inspection failed'
    fd = os.open(vm, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    finally:
        os.close(fd)


assert digest(binary) == candidate['vmSHA256'], 'Installed candidate bytes differ'
assert json.loads((vm / 'launchpad.json').read_text())['bundle'] == candidate['version']
if args.phase == 'prepare':
    released()
    serial_info = args.serial.stat() if args.serial.exists() else None
    save('default-shutdown-prepare.json', dict(metadata=metadata(), serial=str(args.serial),
        serialOffset=args.serial.stat().st_size if args.serial.exists() else 0,
        serialIdentity=dict(device=serial_info.st_dev, inode=serial_info.st_ino, birth=serial_info.st_birthtime) if serial_info else None,
        serialPrefixSHA256=digest(args.serial) if serial_info else None,
        candidateVersion=candidate['version'], observedAt=time.time()))
elif args.phase == 'running':
    baseline = json.loads((work / 'default-shutdown-prepare.json').read_text())
    assert metadata() == baseline['metadata']
    deadline = time.monotonic() + 120
    while True:
        try:
            target = endpoint(vm.name, vm / 'vphone.sock')
            caps = request(target, dict(t='capabilities'), recorder, 5)
            if caps.get('ok') and caps.get('guest_connected'):
                break
        except (OSError, RuntimeError):
            pass
        assert time.monotonic() < deadline, 'Guest control did not connect'
        time.sleep(1)
    runtime = json.loads((vm / '.vphone-runtime.json').read_text())
    command = subprocess.check_output(['/bin/ps', '-p', str(runtime['pid']), '-o', 'command='], text=True).strip()
    assert command.startswith(str(binary) + ' ')
    assert runtime['operation'] == 'boot' and Path(runtime['bundlePath']) == vm
    assert caps['boot_mode'] == 'normal'
    assert '--api-listen' not in command and caps['commands'].get('rpc') is False, 'Expected default startup without API session'
    assert '--headless' not in command, 'Expected graphical startup'
    assert '--binding-sha256 ' + baseline['metadata']['launchpad.json'] in command
    assert '--no-vphoned-update' in command
    system = request(target, dict(t='file_get', path='/System/Library/CoreServices/SystemVersion.plist'), recorder, 15)
    assert system.get('ok') is True
    version = plistlib.loads(base64.b64decode(system['data'], validate=True))
    assert (version['ProductVersion'], version['ProductBuildVersion']) == ('26.1', '23B85')
    comparison = json.loads(args.component_comparison.read_text())
    libraries = {}
    for name, expected in comparison['libraries'].items():
        response = request(target, dict(t='file_get', path='/usr/lib/' + name), recorder, 15)
        assert response.get('ok') is True
        data = base64.b64decode(response['data'], validate=True)
        actual = hashlib.sha256(data).hexdigest()
        assert len(data) == response['size'] and actual == expected['targetSHA256'], name
        libraries[name] = actual
    save('default-shutdown-running.json', dict(state='passed', runtime=runtime, command=command,
        capabilities=caps, systemVersion=version, libraries=libraries, observedAt=time.time()))
else:
    baseline = json.loads((work / 'default-shutdown-prepare.json').read_text())
    running = json.loads((work / 'default-shutdown-running.json').read_text())
    runtime = running['runtime']
    deadline = time.monotonic() + 50
    while True:
        process = subprocess.run(['/bin/ps', '-p', str(runtime['pid']), '-o', 'command='], capture_output=True, text=True)
        assert process.returncode in (0, 1) and not process.stderr
        if str(vm / 'config.plist') not in process.stdout:
            break
        assert time.monotonic() < deadline, 'Observed VM remains running'
        time.sleep(.5)
    assert str(args.serial) == baseline['serial']
    serial, selection = read_launch_serial(args.serial, baseline, running['observedAt'])
    for marker in ('guest shutdown via direct API VSOCK', 'guest shutdown request: apiAccepted', 'Guest stopped', 'vm launch exited with status 0'):
        assert marker in serial, marker
    for marker in ('[api] proxy listening', 'graceful shutdown timed out', '[vphone] VM stopped', 'no graceful shutdown path available'):
        assert marker not in serial, marker
    released()
    assert metadata() == baseline['metadata']
    save('default-shutdown-result.json', dict(state='passed', pid=runtime['pid'], instanceID=runtime['instanceID'],
        candidateVersion=candidate['version'], defaultGUI=True, hostHTTPListenerEnabled=False,
        directVSOCKRequestAccepted=True, guestStopped=True, forcedFrameworkStop=False,
        diskReleased=True, directoryLockFree=True, metadataPreserved=True, launcherExitCode=0, serialSelection=selection, observedAt=time.time()))
print(json.dumps(dict(phase=args.phase, state='passed', vm=str(vm))))
