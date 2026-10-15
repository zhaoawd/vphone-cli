"""Observe the authorized V4 Task 8 VM and query guest state read-only."""
from pathlib import Path
import json
import subprocess
import time

E = Path(__file__).resolve().parent
CLI = '/Library/Application Support/vphone-launchpad/Bundles/2.6.20261016-local/VPhone.bundle/Contents/MacOS/vphone-cli'
BASE = [CLI, 'guest', 'send', 'task8-copy', '--library-root', '/private/tmp/vphone-task8-acceptance-vms', '--timeout', '15']
OUT = E / 'boot-watch-v4-kernel-v8.json'
OBS = E / 'boot-watch-v4-kernel-v8-observations.jsonl'
assert not OUT.exists() and not OBS.exists()
started = time.monotonic()
result = {'passed': False, 'scope': 'Guest capabilities and uname/sysctl only', 'attempts': []}
target = None


def send(message):
    command = BASE + [json.dumps(message, separators=(',', ':'))]
    try:
        p = subprocess.run(command, capture_output=True, text=True, timeout=20)
        record = {'command': command, 'exit_code': p.returncode, 'stdout': p.stdout, 'stderr': p.stderr,
                  'elapsed_seconds': round(time.monotonic() - started, 3)}
        try:
            record['response'] = json.loads(p.stdout)
        except json.JSONDecodeError:
            pass
    except subprocess.TimeoutExpired as error:
        record = {'command': command, 'client_timeout': True, 'error': str(error),
                  'elapsed_seconds': round(time.monotonic() - started, 3)}
    result['attempts'].append(record)
    observation.write(json.dumps(record) + '\n')
    observation.flush()
    return record


try:
    with OBS.open('x') as observation:
        while time.monotonic() - started < 360:
            cap = send({'t': 'capabilities'})
            body = cap.get('response', {})
            if body.get('ok') is True:
                current = body.get('target', {})
                assert current.get('vm') == 'task8-copy'
                assert isinstance(current.get('pid'), int) and current['pid'] > 0
                assert current.get('instance_id')
                if target is None:
                    target = current
                else:
                    assert current == target, 'VM control instance changed during boot observation'
                result['target'] = target
            ready = (cap.get('exit_code') == 0 and body.get('ok') is True and target is not None
                     and body.get('guest_connected') is True and body.get('commands', {}).get('shell') is True)
            print(json.dumps({'elapsed_seconds': round(time.monotonic() - started, 1),
                              'guest_ready': ready, 'target': target}), flush=True)
            if ready:
                shell = send({'t': 'shell', 'cmd': 'uname -a; sysctl kern.osrelease hw.machine',
                              'timeout_ms': 10000, 'target': target})
                response = shell.get('response', {})
                output = response.get('stdout', '')
                if (shell.get('exit_code') == 0 and response.get('ok') is True
                        and type(response.get('code')) is int and response['code'] == 0
                        and response.get('timed_out') is False and response.get('truncated') is False
                        and isinstance(output, str)
                        and all(text in output for text in ('Darwin', 'kern.osrelease:', 'hw.machine:'))):
                    result['passed'] = True
                    result['guest_state'] = response
                    break
            time.sleep(15)
except BaseException as error:
    result['error'] = repr(error)
    raise
finally:
    result['elapsed_seconds'] = round(time.monotonic() - started, 3)
    OUT.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'attempts'}), flush=True)
    if not result['passed']:
        raise RuntimeError('Guest boot readiness was not established')
