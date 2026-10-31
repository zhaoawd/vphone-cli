#!/usr/bin/env python3
"""Verify two fixed locations through the named app's CLLocationManager."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts'))
from host_control_client import endpoint, request
from verify_t52_application_observation import verify

VM = ROOT / '.build/t51rt/lib/t52-v2'
BUNDLE = 'org.vphone.acceptance.t52.20261022'
DATA = '/private/var/mobile/Containers/Data/Application/FFA16ABD-DF93-4C3A-9157-6F04783AF75C'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--phase-timeout', type=float, default=20, help='Bounded wait for normal permission UI and callbacks (1...120 seconds)')
    p.add_argument('--instance-id', default='1B6A2DA7-7B19-41ED-BB2D-3FF385497E21')
    args = p.parse_args()
    if not 1 <= args.phase_timeout <= 120: p.error('phase-timeout must be 1...120 seconds')
    args.output.mkdir(exist_ok=False)
    runtime = json.loads((VM / '.vphone-runtime.json').read_text())
    assert runtime['instanceID'] == args.instance_id
    target = endpoint(VM.name, VM / 'vphone.sock')

    class Recorder:
        def record(self, target, payload, response):
            captured = dict(response)
            if 'data' in captured:
                b = base64.b64decode(captured.pop('data'), validate=True)
                captured.update(dataSHA256=hashlib.sha256(b).hexdigest(), dataBytes=len(b))
            with (args.output / 'requests.jsonl').open('a') as f:
                f.write(json.dumps(dict(time=time.time(), request=payload, response=captured)) + '\n')

    recorder = Recorder()

    def call(payload, timeout=20):
        return request(target, payload, recorder, timeout)

    def rpc(method, params):
        r = call(dict(t='rpc', method=method, params=params))
        if r.get('ok') is not True:
            raise RuntimeError(str(r))
        return r['result']

    assert rpc('agent.health', {}).get('setup_pending') is False
    assert rpc('screen.unlock', {}).get('locked') is False
    info = rpc('apps.info', {'bundle_id': BUNDLE})
    assert info['data_path'] == DATA
    results = []
    generation = None
    try:
        for index, (lat, lon, alt) in enumerate([(31.2, 121.5, 20), (30.25, 120.15, 35)]):
            run_id = 't52-location-' + uuid.uuid4().hex
            expected = dict(latitude=lat, longitude=lon, altitude=alt,
                            horizontalAccuracy=5, verticalAccuracy=6, speed=2, course=90)
            source = call(dict(t='location_source_set', mode='fixed', owner='t52-app-acceptance',
                               coordinate_system='wgs84', producer_sequence=0, lat=lat, lon=lon,
                               alt=alt, hacc=5, vacc=6, speed=2, course=90, heartbeat_s=1,
                               persist=False, timestamp=time.time()))
            if source.get('ok') is not True:
                raise RuntimeError(str(source))
            generation = source['generation']
            rpc('apps.terminate', {'bundle_id': BUNDLE})
            phase_file = args.output / f'point-{index}-request.json'
            phase_file.write_text(json.dumps(dict(mode='location', runID=run_id)) + '\n')
            upload = call(dict(t='file_put', transport='api', path=DATA + '/Library/Caches/t52-request.json',
                               load=str(phase_file.resolve()), perm='644'))
            if upload.get('ok') is not True:
                raise RuntimeError(str(upload))
            rpc('apps.launch', {'bundle_id': BUNDLE})
            processes = rpc('processes.list', {})['processes']
            pid = next(p['pid'] for p in processes if p.get('bundle_id') == BUNDLE)
            deadline = time.monotonic() + args.phase_timeout
            last_error = 'No consumer record'
            while time.monotonic() < deadline:
                response = call(dict(t='file_get', transport='api', path=DATA + '/Library/Caches/t52-application.json'))
                if response.get('ok') is True:
                    record = json.loads(base64.b64decode(response['data'], validate=True))
                    (args.output / f'point-{index}-record.json').write_text(json.dumps(record, indent=2) + '\n')
                    try:
                        result = verify(record, run_id=run_id, pid=pid, mode='location', expected=expected)
                        results.append(dict(result, expected=expected, sourceGeneration=generation))
                        break
                    except ValueError as error:
                        last_error = str(error)
                time.sleep(.75)
            else:
                raise RuntimeError(last_error)
            stopped = call(dict(t='location_source_stop', generation=generation))
            assert stopped.get('ok') is True
            generation = None
        result = dict(state='passed', vmInstanceID=runtime['instanceID'], points=results)
    except Exception as error:
        result = dict(state='failed', vmInstanceID=runtime['instanceID'], points=results, error=str(error))
    finally:
        if generation:
            stopped = call(dict(t='location_source_stop', generation=generation))
            if stopped.get('ok') is not True:
                raise RuntimeError('Could not stop the exact location source: ' + str(stopped))
        cleanup = call(dict(t='rpc', method='apps.terminate', params={'bundle_id': BUNDLE}))
        result['probeStop'] = cleanup
    (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    return 0 if result['state'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
