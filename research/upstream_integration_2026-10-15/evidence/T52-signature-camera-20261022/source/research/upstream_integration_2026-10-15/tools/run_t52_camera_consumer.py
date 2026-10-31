#!/usr/bin/env python3
"""Two QR consumers and a timed neutral control in the named acceptance VM."""
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
from run_t52_location_consumer import VM, BUNDLE, DATA


def check_receipt(response, generation, *, require_version=True):
    receipt = response.get('transport_receipt', {})
    publication, observation = (receipt.get(k) for k in ('vphoned_published_frame_index', 'libvcam_observed_frame_index'))
    if (response.get('ok') is not True or (require_version and response.get('protocol_version') != 3) or
            response.get('generation') != generation or receipt.get('generation') != generation or
            not response.get('presentation_id') or receipt.get('presentation_id') != response['presentation_id'] or
            receipt.get('semantics') != 'presentation_frame_copied' or
            type(publication) is not int or type(observation) is not int or not 0 < observation <= publication):
        raise ValueError('Matching two-level camera receipt was not observed: ' + str(response))
    return receipt


def check_neutral(record, run_id, pid):
    # Reuse the common strict identity, event and error checks. Only the
    # expected absence of metadata differs from a successful QR phase.
    try:
        verify(record, run_id=run_id, pid=pid, mode='camera', expected='neutral-control-must-not-decode')
    except ValueError as error:
        if str(error) != 'Virtual device or consumer QR metadata differs':
            raise
    else:
        raise ValueError('Neutral control unexpectedly decoded QR content')
    events = record['events']
    devices = [e for e in events if e.get('type') == 'camera_device']
    if (not devices or any(e.get('uniqueID') != 'vphone:vcam:0' for e in devices) or
            not any(e.get('type') == 'camera_started' for e in events) or
            any(e.get('type') == 'camera_metadata' for e in events)):
        raise ValueError('Neutral consumer was not active or produced QR metadata')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--frames', type=Path, required=True)
    p.add_argument('--instance-id', required=True)
    args = p.parse_args()
    args.output.mkdir(exist_ok=False)
    runtime = json.loads((VM / '.vphone-runtime.json').read_text())
    assert runtime['instanceID'] == args.instance_id
    target = endpoint(VM.name, VM / 'vphone.sock')

    class Recorder:
        def record(self, target, payload, response):
            captured = dict(response)
            if 'data' in captured:
                data = base64.b64decode(captured.pop('data'), validate=True)
                captured.update(dataSHA256=hashlib.sha256(data).hexdigest(), dataBytes=len(data))
            with (args.output / 'requests.jsonl').open('a') as stream:
                stream.write(json.dumps(dict(time=time.time(), request=payload, response=captured)) + '\n')
    recorder = Recorder()

    def call(payload, timeout=25):
        return request(target, payload, recorder, timeout)

    def rpc(method, params):
        response = call(dict(t='rpc', method=method, params=params))
        if response.get('ok') is not True: raise RuntimeError(str(response))
        return response['result']

    def read_record():
        response = call(dict(t='file_get', transport='api', path=DATA + '/Library/Caches/t52-application.json'))
        if response.get('ok') is not True: raise RuntimeError(str(response))
        return json.loads(base64.b64decode(response['data'], validate=True))

    phases, active = [], None
    result = dict(state='failed', vmInstanceID=args.instance_id, phases=phases)
    try:
        assert rpc('agent.health', {}).get('setup_pending') is False
        assert rpc('screen.unlock', {}).get('locked') is False
        for name, expected in [('a', 't52-20261022-A'), ('neutral', None), ('b', 't52-20261022-B')]:
            # Seed neutral before opening a new metadata configuration. The
            # previous live client can acknowledge this transition; on the
            # first iteration acknowledgement may wait for the client startup.
            baseline = 't52-neutral-' + uuid.uuid4().hex
            active = baseline
            baseline_response = call(dict(t='camera_present', path=str((args.frames / 'neutral.png').resolve(strict=True)),
                                          source='image', generation=baseline, role='neutral', fps=8))
            if baseline_response.get('ok') is not True and 'two-level transport receipt unavailable' not in baseline_response.get('error', ''):
                raise RuntimeError(str(baseline_response))
            rpc('apps.terminate', {'bundle_id': BUNDLE})
            run_id = 't52-camera-' + uuid.uuid4().hex
            phase_file = args.output / (name + '-request.json')
            phase_file.write_text(json.dumps(dict(mode='camera', runID=run_id)) + '\n')
            uploaded = call(dict(t='file_put', transport='api', path=DATA + '/Library/Caches/t52-request.json',
                                 load=str(phase_file.resolve()), perm='644'))
            if uploaded.get('ok') is not True: raise RuntimeError(str(uploaded))
            rpc('apps.launch', {'bundle_id': BUNDLE})
            processes = rpc('processes.list', {})['processes']
            pid = next(row['pid'] for row in processes if row.get('bundle_id') == BUNDLE)
            startup = time.monotonic() + 15
            while time.monotonic() < startup:
                record = read_record()
                (args.output / (name + '-startup.json')).write_text(json.dumps(record, indent=2) + '\n')
                if record.get('runID') == run_id:
                    if any(e.get('type') == 'camera_error' for e in record.get('events', [])):
                        raise RuntimeError('Consumer initialization failed: ' + str(record))
                    if any(e.get('type') == 'camera_started' for e in record.get('events', [])):
                        break
                time.sleep(.5)
            else: raise RuntimeError('Camera consumer did not start')
            baseline_status = call(dict(t='camera_status', generation=baseline,
                                        presentation_id=baseline_response.get('presentation_id')))
            receipt = check_receipt(baseline_status, baseline, require_version=False)
            generation = baseline
            path = (args.frames / (name + '.png')).resolve(strict=True)
            if expected is not None:
                generation = 't52-camera-' + uuid.uuid4().hex
                active = generation
                source = call(dict(t='camera_present', path=str(path), source='image', generation=generation,
                                   role='qr', fps=8))
                receipt = check_receipt(source, generation)
            deadline = time.monotonic() + 20
            neutral_started = None
            while time.monotonic() < deadline:
                record = read_record()
                (args.output / (name + '-record.json')).write_text(json.dumps(record, indent=2) + '\n')
                try:
                    if expected is None:
                        check_neutral(record, run_id, pid)
                        if neutral_started is None: neutral_started = time.monotonic()
                        if time.monotonic() - neutral_started < 6:
                            time.sleep(.5); continue
                        assert any(row.get('pid') == pid and row.get('bundle_id') == BUNDLE
                                   for row in rpc('processes.list', {})['processes'])
                        observed = dict(state='passed', mode='neutral', runID=run_id, pid=pid,
                                        noQRSeconds=time.monotonic() - neutral_started)
                    else:
                        observed = verify(record, run_id=run_id, pid=pid, mode='camera', expected=expected)
                        try:
                            verify(record, run_id=run_id, pid=pid, mode='camera', expected=expected + '-wrong')
                        except ValueError:
                            observed['wrongExpectedRejected'] = True
                        else: raise RuntimeError('Wrong QR expectation was accepted')
                    phases.append(dict(observed, generation=generation, receipt=receipt,
                                       frameSHA256=hashlib.sha256(path.read_bytes()).hexdigest()))
                    break
                except ValueError as error:
                    last_error = str(error)
                    if record.get('runID') == run_id and any(e.get('type') in ('camera_error', 'location_error', 'camera_metadata')
                           for e in record.get('events', [])):
                        raise
                time.sleep(.5)
            else: raise RuntimeError(last_error)
        result['state'] = 'passed'
    except Exception as error:
        result['error'] = str(error)
    finally:
        # Clear the visible last QR through the normal neutral transport, then
        # stop that exact neutral source. No guest frame or probe file is removed.
        if active:
            stopped = call(dict(t='camera_stop', generation=active, policy='neutral'))
            result['neutralCleanup'] = stopped
            neutral = stopped.get('neutral_generation')
            if neutral:
                result['sourceStop'] = call(dict(t='camera_stop', generation=neutral, policy='keep_last'))
            if stopped.get('ok') is not True or result.get('sourceStop', {}).get('ok') is not True:
                result.update(state='failed', cleanupError='Camera source cleanup did not complete')
        result['probeStop'] = call(dict(t='rpc', method='apps.terminate', params={'bundle_id': BUNDLE}))
    (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    return 0 if result['state'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
