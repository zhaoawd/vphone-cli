#!/usr/bin/env python3
"""Run the installed read-only probe and restore the preserved consumer app."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time
import uuid

from run_t52_location_consumer import VM, BUNDLE, DATA, ROOT
sys.path.insert(0, str(ROOT / 'scripts'))
from host_control_client import endpoint, request

RESTORE = ROOT / '.build/t52-app-acceptance-20261022/consumer-probe-access-container/T52Acceptance.app/T52Acceptance'
RESTORE_SHA = '02795c7a8bf30799bd309832f1bad6f70200fcc5b2bdc04cc417c773108faaee'
APP = '/private/var/containers/Bundle/Application/FE3CFC90-BF86-41D6-8123-31520D687DEA/T52Acceptance.app'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--instance-id', required=True)
    parser.add_argument('--expected-current', required=True)
    parser.add_argument('--required-event', choices=('camera_discovery_readonly', 'provider_query_diagnostic'), default='camera_discovery_readonly')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(); args.output.mkdir(exist_ok=False)
    assert hashlib.sha256(RESTORE.read_bytes()).hexdigest() == RESTORE_SHA
    assert json.loads((VM / '.vphone-runtime.json').read_text())['instanceID'] == args.instance_id
    target = endpoint(VM.name, VM / 'vphone.sock')
    class Log:
        def record(self, target, payload, response):
            saved = dict(response)
            if 'data' in saved:
                data = base64.b64decode(saved.pop('data'), validate=True)
                saved['dataSHA256'] = hashlib.sha256(data).hexdigest()
            with (args.output / 'requests.jsonl').open('a') as f:
                f.write(json.dumps(dict(time=time.time(), request=payload, response=saved)) + '\n')
    def call(payload):
        result = request(target, payload, Log(), 20)
        if result.get('ok') is not True: raise RuntimeError(str(result))
        return result
    def rpc(method, params): return call(dict(t='rpc', method=method, params=params))['result']
    def get(path): return base64.b64decode(call(dict(t='file_get', transport='api', path=path))['data'], validate=True)
    assert hashlib.sha256(get(APP + '/T52Acceptance')).hexdigest() == args.expected_current
    result = dict(vmInstanceID=args.instance_id, accepted=False)
    try:
        rpc('screen.unlock', {})
        rpc('apps.terminate', dict(bundle_id=BUNDLE))
        run = 't52-readonly-' + uuid.uuid4().hex
        phase = args.output / 'request.json'
        phase.write_text(json.dumps(dict(mode='camera', runID=run)) + '\n')
        call(dict(t='file_put', transport='api', path=DATA + '/Library/Caches/t52-request.json', load=str(phase.resolve()), perm='644'))
        rpc('apps.launch', dict(bundle_id=BUNDLE))
        until = time.monotonic() + 25
        observation = 0
        while time.monotonic() < until:
            # Dispatch metadata can exceed the host's 1 MiB inline limit.
            # Preserve every observation through its bounded file download.
            downloaded = args.output.resolve() / f'observation-{observation:03d}.json'
            observation += 1
            call(dict(t='file_get', transport='api', path=DATA + '/Library/Caches/t52-application.json', save=str(downloaded)))
            record = json.loads(downloaded.read_text())
            if record.get('runID') == run and any(e['type'] == args.required_event for e in record['events']):
                (args.output / 'record.json').write_text(json.dumps(record, indent=2) + '\n')
                result['captured'] = True
                break
            time.sleep(.25)
        else: raise RuntimeError('No matching read-only discovery record')
    except Exception as error:
        result.update(captured=False, error=str(error))
    finally:
        # An uncertain stop reply must not suppress the restoration path.
        # The deployment tool independently checks that the app is stopped
        # before replacing its executable and then checks the readback.
        try:
            result['probeStop'] = rpc('apps.terminate', dict(bundle_id=BUNDLE))
        except Exception as error:
            result['probeStopError'] = str(error)
        restore = subprocess.run([sys.executable, str(Path(__file__).with_name('experiment_t52_probe_signature.py')),
            '--candidate', str(RESTORE), '--expected-current', args.expected_current,
            '--instance-id', args.instance_id, '--defer-launch', '--output', str(args.output / 'restoration')],
            capture_output=True, text=True)
        (args.output / 'restoration.log').write_text(restore.stdout + restore.stderr)
        if restore.returncode: raise RuntimeError('Restore failed: ' + restore.stderr)
        assert hashlib.sha256(get(APP + '/T52Acceptance')).hexdigest() == RESTORE_SHA
        result['probeRestored'] = True
        (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    return 0 if result.get('captured') else 1


if __name__ == '__main__': raise SystemExit(main())
