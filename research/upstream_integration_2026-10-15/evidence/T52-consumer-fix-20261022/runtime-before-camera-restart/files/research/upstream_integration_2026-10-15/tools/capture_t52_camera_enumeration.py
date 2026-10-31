#!/usr/bin/env python3
"""Observe native camera enumeration while launching only the named T52 app."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import sys
import threading
import time
import uuid

from run_t52_location_consumer import VM, BUNDLE, DATA, ROOT
sys.path.insert(0, str(ROOT / 'scripts'))
from host_control_client import endpoint, request

APP = '/private/var/containers/Bundle/Application/FE3CFC90-BF86-41D6-8123-31520D687DEA/T52Acceptance.app/T52Acceptance'
ORIGINAL_SHA = '02795c7a8bf30799bd309832f1bad6f70200fcc5b2bdc04cc417c773108faaee'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--instance-id', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(); args.output.mkdir(exist_ok=False)
    assert json.loads((VM / '.vphone-runtime.json').read_text())['instanceID'] == args.instance_id
    target = endpoint(VM.name, VM / 'vphone.sock')
    lock = threading.Lock()
    class Log:
        def record(self, target, payload, response):
            saved = dict(response)
            if 'data' in saved:
                data = base64.b64decode(saved.pop('data'), validate=True)
                saved['dataSHA256'] = hashlib.sha256(data).hexdigest()
            with lock, (args.output / 'requests.jsonl').open('a') as stream:
                stream.write(json.dumps(dict(time=time.time(), request=payload, response=saved)) + '\n')
    def call(payload):
        result = request(target, payload, Log(), 20)
        if result.get('ok') is not True: raise RuntimeError(str(result))
        return result
    def rpc(method, params): return call(dict(t='rpc', method=method, params=params))['result']
    def processes():
        return [p for p in rpc('processes.list', {})['processes'] if p['name'] in ('cameracaptured', 'T52Acceptance')]
    before = processes()
    camera, = [p for p in before if p['name'] == 'cameracaptured']
    assert camera['executable'] == '/usr/libexec/cameracaptured'
    assert hashlib.sha256(base64.b64decode(call(dict(t='file_get', transport='api', path=APP))['data'], validate=True)).hexdigest() == ORIGINAL_SHA
    rpc('screen.unlock', {})
    rpc('apps.terminate', dict(bundle_id=BUNDLE))
    run = 't52-enumeration-' + uuid.uuid4().hex
    phase = args.output / 'request.json'
    phase.write_text(json.dumps(dict(mode='camera', runID=run)) + '\n')
    call(dict(t='file_put', transport='api', path=DATA + '/Library/Caches/t52-request.json', load=str(phase.resolve()), perm='644'))
    result = dict(vmInstanceID=args.instance_id, runID=run, before=before, accepted=False)
    def capture():
        # Keep the stream below the host RPC's five-second response deadline.
        try: result['logs'] = rpc('logs.syslog', dict(seconds=4, process='cameracaptured', max_lines=2000))
        except Exception as error: result['logError'] = str(error)
    thread = threading.Thread(target=capture)
    thread.start()
    try:
        time.sleep(.3)
        result['launch'] = rpc('apps.launch', dict(bundle_id=BUNDLE))
        thread.join(timeout=20)
        if thread.is_alive(): raise RuntimeError('Log stream did not finish')
        record = json.loads(base64.b64decode(call(dict(t='file_get', transport='api', path=DATA + '/Library/Caches/t52-application.json'))['data'], validate=True))
        assert record['runID'] == run
        (args.output / 'record.json').write_text(json.dumps(record, indent=2) + '\n')
        result['captured'] = True
    except Exception as error:
        result['error'] = str(error)
    finally:
        try: result['probeStop'] = rpc('apps.terminate', dict(bundle_id=BUNDLE))
        except Exception as error: result['probeStopError'] = str(error)
        result['after'] = processes()
        assert not any(p['name'] == 'T52Acceptance' for p in result['after'])
        after_camera, = [p for p in result['after'] if p['name'] == 'cameracaptured']
        assert after_camera['pid'] == camera['pid'] and after_camera['start_time'] == camera['start_time']
        result['cameraDaemonUnchanged'] = True
        (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k not in ('logs', 'before', 'after')}))
    return 0 if result.get('captured') and 'logError' not in result else 1


if __name__ == '__main__': raise SystemExit(main())
