#!/usr/bin/env python3
"""Boot only the approved diagnostic VM, and stop its window at API readiness."""
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / '.build/t52-camera-diagnostics-20261022'
VM = ROOT / '.build/t51rt/lib/t52-v2'
VERSION = '2.6.2-local.56be1ce20ded'
CDHASH = '89cb8ee4c9f47b15a1c63bd73c99b53a0d43a541'
sys.path.insert(0, str(ROOT / 'scripts'))
from host_control_client import endpoint, request


def wait_until_ready(child, *, vm, previous_instance, recorder, timeout=110):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if child.poll() is not None:
            raise RuntimeError('VM launcher exited: ' + str(child.returncode))
        try:
            target = endpoint(vm.name, vm / 'vphone.sock')
            caps = request(target, dict(t='capabilities'), recorder, 5)
            health = request(target, dict(t='rpc', method='agent.health', params={}), recorder, 5)
            runtime = json.loads((vm / '.vphone-runtime.json').read_text())
            if (caps.get('guest_connected') is True and health.get('ok') is True and
                    runtime['operation'] == 'boot' and runtime['instanceID'] != previous_instance):
                return dict(runtime=runtime, capabilities=caps, health=health)
        except (OSError, RuntimeError, ValueError):
            pass
        time.sleep(.05)
    raise RuntimeError('Diagnostic VM did not become ready')


def main():
    assert json.loads((VM / 'launchpad.json').read_text())['bundle'] == VERSION
    assert not list(VM.glob('.cfw_disk.*'))
    check = json.loads((WORK / 'postcheck.json').read_text())
    assert check['classification'] == 'already_current' and check['replace'] == []
    helper = json.loads((WORK / 'boot-window/helper-state.json').read_text())
    assert helper['state'] == 'running' and helper['cdhash'] == CDHASH and helper['attempt'] == 1
    assert helper['maxSeconds'] == 900 and helper['deadline'] - time.time() > 120
    assert not (WORK / 'boot-window/stop-authorized-helper').exists()
    cli = Path('/Library/Application Support/vphone-launchpad/Bundles') / VERSION / 'VPhone.bundle/Contents/MacOS/vphone-cli'
    command = [str(cli), 'vm', 'launch', VM.name, '--library-root', str(VM.parent), '--api-listen', '127.0.0.1:54073']
    env = os.environ.copy(); env['VPHONE_API_TOKEN'] = secrets.token_hex(32)
    with (WORK / 'api-launch.log').open('xb') as log:
        child = subprocess.Popen(command, cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
                                 stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    (WORK / 'api-launch.json').write_text(json.dumps(dict(pid=child.pid, command=command,
        startedAt=time.time(), tokenStored=False), indent=2) + '\n')
    class Log:
        def record(self, target, payload, response):
            with (WORK / 'boot-readiness.jsonl').open('a') as f:
                f.write(json.dumps(dict(time=time.time(), request=payload, response=response)) + '\n')
    try:
        session = wait_until_ready(child, vm=VM,
            previous_instance='55A25B78-4CAD-4053-9C3E-9CFCD3E75F64', recorder=Log())
        (WORK / 'running-session.json').write_text(json.dumps(session, indent=2) + '\n')
        runtime = session['runtime']
        print(json.dumps(dict(state='ready', pid=runtime['pid'], instanceID=runtime['instanceID'])))
    finally:
        # Stop the window even when readiness fails. Its independent root
        # supervisor also enforces the absolute authorization end.
        (WORK / 'boot-window/stop-authorized-helper').touch(exist_ok=True)


if __name__ == '__main__': main()
