#!/usr/bin/env python3
"""Compare the existing API location bridge with the named public-API consumer."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import sys
import time
import uuid

from run_t52_location_consumer import VM, BUNDLE, DATA
from verify_t52_application_observation import verify
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'scripts'))
from host_control_client import endpoint, request

BRIDGE = '/var/mobile/Library/Caches/vphone-location.json'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--instance-id', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(); args.output.mkdir(exist_ok=False)
    assert json.loads((VM / '.vphone-runtime.json').read_text())['instanceID'] == args.instance_id
    target = endpoint(VM.name, VM / 'vphone.sock')
    class Recorder:
        def record(self, target, payload, response):
            saved = dict(response)
            if 'data' in saved:
                data = base64.b64decode(saved.pop('data'), validate=True)
                saved.update(dataBytes=len(data), dataSHA256=hashlib.sha256(data).hexdigest())
            with (args.output / 'requests.jsonl').open('a') as f:
                f.write(json.dumps(dict(time=time.time(), request=payload, response=saved)) + '\n')
    def call(payload):
        result = request(target, payload, Recorder(), 20)
        if result.get('ok') is not True: raise RuntimeError(str(result))
        return result
    def rpc(method, params): return call(dict(t='rpc', method=method, params=params))['result']
    def get(path): return base64.b64decode(call(dict(t='file_get', transport='api', path=path))['data'], validate=True)
    def directory(): return rpc('files.list', dict(path='/var/mobile/Library/Caches'))['entries']
    assert call(dict(t='location_source_status'))['state'] == 'off'
    assert not any(row['name'] == 'vphone-location.json' for row in directory()), 'Existing bridge must be preserved'
    result = dict(vmInstanceID=args.instance_id, accepted=False, transport='guest_api_location.set')
    expected = dict(latitude=30.25, longitude=120.15, altitude=35,
                    horizontalAccuracy=5, verticalAccuracy=6, speed=2, course=90)
    point = dict(latitude=30.25, longitude=120.15, altitude=35,
                 horizontal_accuracy=5, vertical_accuracy=6, speed=2, course=90)
    published = None
    try:
        rpc('screen.unlock', {})
        rpc('apps.terminate', dict(bundle_id=BUNDLE))
        result['publication'] = rpc('location.set', point)
        published = get(BRIDGE)
        assert json.loads(published) == point
        (args.output / 'bridge-published.json').write_bytes(published)
        run_id = 't52-api-location-' + uuid.uuid4().hex
        phase = args.output / 'request.json'; phase.write_text(json.dumps(dict(mode='location', runID=run_id)) + '\n')
        call(dict(t='file_put', transport='api', path=DATA + '/Library/Caches/t52-request.json',
                  load=str(phase.resolve()), perm='644'))
        rpc('apps.launch', dict(bundle_id=BUNDLE))
        pid = next(row['pid'] for row in rpc('processes.list', {})['processes'] if row.get('bundle_id') == BUNDLE)
        result.update(pid=pid, runID=run_id)
        until = time.monotonic() + 15
        while time.monotonic() < until:
            record = json.loads(get(DATA + '/Library/Caches/t52-application.json'))
            (args.output / 'consumer-record.json').write_text(json.dumps(record, indent=2) + '\n')
            try:
                result['consumerVerification'] = verify(record, run_id=run_id, pid=pid, mode='location', expected=expected)
                result['consumerPassed'] = True
                break
            except ValueError as error:
                result.update(consumerPassed=False, consumerError=str(error))
            time.sleep(.5)
        result['recordMatchesRun'] = record.get('runID') == run_id and record.get('pid') == pid
        result['callbacks'] = sum(event.get('type') == 'location_callback' for event in record.get('events', []))
        result['fileAccess'] = [event.get('fileAccess') for event in record.get('events', []) if event.get('type') == 'runtime_diagnostic']
    except Exception as error:
        result.update(state='diagnostic_request_failed', error=str(error))
    finally:
        result['probeStop'] = rpc('apps.terminate', dict(bundle_id=BUNDLE))
        if published is not None:
            # Only clear this experiment's simulation state after comparing
            # the exact bytes; another producer's state must be preserved.
            assert get(BRIDGE) == published, 'Bridge changed; preserve it for review'
            result['sourceStop'] = rpc('location.clear', {})
            assert not any(row['name'] == 'vphone-location.json' for row in directory())
    (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__': main()
