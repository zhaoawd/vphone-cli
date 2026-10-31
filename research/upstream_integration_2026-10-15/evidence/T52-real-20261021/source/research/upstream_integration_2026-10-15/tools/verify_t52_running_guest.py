#!/usr/bin/env python3
"""Read the already-running bound T52 VM; never starts or stops a process."""
import base64
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import time

root = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(root / 'scripts'))
from host_control_client import endpoint, request

work = root / '.build/t52-real-20261021'
vm = root / '.build/t51rt/lib/t52-v2'
binary = Path('/Library/Application Support/vphone-launchpad/Bundles/'
              '2.6.2-local.cd529f26a150/VPhone.bundle/Contents/MacOS/vphone-vm')
comparison = json.loads((work / 'component-comparison.json').read_text())
result = dict(state='waiting', vm=str(vm), startedAt=time.time(), processActivationVerified=False)


def save(name, value):
    (work / name).write_text(json.dumps(value, indent=2) + '\n')


class Recorder:
    def record(self, target, payload, response):
        # Binary file responses are represented by digest and length in the log.
        recorded = dict(response)
        if isinstance(recorded.get('data'), str):
            data = base64.b64decode(recorded.pop('data'), validate=True)
            recorded['capturedData'] = dict(bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
        with (work / 'post-update-guest-requests.jsonl').open('a') as stream:
            stream.write(json.dumps(dict(time=time.time(), request=payload, response=recorded)) + '\n')


try:
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == 'e29cc792d83850bd81fd28b5f5d65dc08e0e7ed053ca37556d2e363a4e2cdd1a'
    deadline = time.monotonic() + 180
    last = None
    recorder = Recorder()
    while time.monotonic() < deadline:
        try:
            target = endpoint(vm.name, vm / 'vphone.sock')
            caps = request(target, dict(t='capabilities'), recorder, 5)
            last = caps
            if caps.get('ok') is True and caps.get('guest_connected') is True:
                break
        except (OSError, RuntimeError) as error:
            last = str(error)
        time.sleep(1)
    else:
        raise RuntimeError(f'Guest connection deadline: {last}')
    runtime = json.loads((vm / '.vphone-runtime.json').read_text())
    command = subprocess.check_output(['/bin/ps', '-p', str(runtime['pid']), '-o', 'command='], text=True).strip()
    assert command.startswith(str(binary) + ' '), command
    assert runtime['operation'] == 'boot' and Path(runtime['bundlePath']) == vm
    assert caps['boot_mode'] == 'normal'
    binding_sha = hashlib.sha256((vm / 'launchpad.json').read_bytes()).hexdigest()
    assert '--binding-sha256 ' + binding_sha in command, command
    assert '--no-vphoned-update' in command
    save('post-update-runtime.json', runtime)
    save('post-update-capabilities.json', caps)
    version = request(target, dict(t='file_get', path='/System/Library/CoreServices/SystemVersion.plist'), recorder, 15)
    assert version.get('ok') is True, version
    system = plistlib.loads(base64.b64decode(version['data'], validate=True))
    libraries = {}
    for name, expected in comparison['libraries'].items():
        response = request(target, dict(t='file_get', path='/usr/lib/' + name), recorder, 15)
        assert response.get('ok') is True, response
        data = base64.b64decode(response['data'], validate=True)
        digest = hashlib.sha256(data).hexdigest()
        assert len(data) == response['size'] and digest == expected['targetSHA256'], name
        libraries[name] = dict(bytes=len(data), sha256=digest, targetMatches=True)
    environment = request(target, dict(t='environment_status', components=str(binary.parent.parent / 'Resources/.build/guest-components-v2/stage')), recorder, 30)
    save('post-update-environment-status.json', environment)
    result.update(state='passed', readyAt=time.time(), runtime=runtime, command=command,
                  systemVersion=system, libraries=libraries, bindingSHA256=binding_sha,
                  guestConnected=True, daemonUpdateRequested=False,
                  limitation='File hashes verify installed bytes; application-specific library activation is not established by file reads')
except Exception as error:
    result.update(state='failed', error=f'{type(error).__name__}: {error}')
    raise
finally:
    save('post-update-guest-result.json', result)
print(json.dumps(result, indent=2))
