#!/usr/bin/env python3
"""Capture one separately approved camera-daemon restart in the current T52 VM."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import sys
import threading
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts'))
from host_control_client import endpoint, request
VM = ROOT / '.build/t51rt/lib/t52-v2'
BUNDLE = 'org.vphone.acceptance.t52.20261022'
EXPECTED = {'libcamfix.dylib': 'af3865decfe65e3ff01dc6865e6b579a0e401b322bf4a5afdeeeb0a49e86e428',
            'libvcamcaptured.dylib': '1bb6602a22a4da2ffa2ddd30dafcdc34f99362df42e0aa7f1d0ed6bea7bcef45'}


def checked_camera_process(rows):
    current = [p for p in rows if p['name'] == 'cameracaptured']
    assert len(current) == 1
    process = current[0]
    assert process['executable'] == '/usr/libexec/cameracaptured'
    assert process['pid'] == 70 and process['uid'] == 501
    assert process['start_time'] == 1792683621.488895
    assert not any(p.get('bundle_id') == BUNDLE for p in rows)
    return process


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--instance-id', required=True)
    parser.add_argument('--execute-approved-restart', action='store_true', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(); args.output.mkdir(exist_ok=False)
    runtime = json.loads((VM / '.vphone-runtime.json').read_text())
    assert runtime['operation'] == 'boot' and runtime['instanceID'] == args.instance_id
    assert args.instance_id == '0C9D0EF5-5072-42CC-B7DD-86096210D871'
    target = endpoint(VM.name, VM / 'vphone.sock')
    lock = threading.Lock()
    class Log:
        def record(self, target, payload, response):
            value = dict(response)
            if 'data' in value:
                data = base64.b64decode(value.pop('data'), validate=True)
                value.update(dataBytes=len(data), dataSHA256=hashlib.sha256(data).hexdigest())
            with lock, (args.output / 'requests.jsonl').open('a') as f:
                f.write(json.dumps(dict(time=time.time(), request=payload, response=value)) + '\n')
    def call(payload):
        result = request(target, payload, Log(), 20)
        if result.get('ok') is not True: raise RuntimeError(str(result))
        return result
    def rpc(method, params): return call(dict(t='rpc', method=method, params=params))['result']
    for name, expected in EXPECTED.items():
        result = call(dict(t='file_get', transport='api', path='/usr/lib/' + name))
        assert hashlib.sha256(base64.b64decode(result['data'], validate=True)).hexdigest() == expected
    result = dict(vmInstanceID=args.instance_id, libraries=EXPECTED, captures={}, accepted=False)
    def capture(label, process, action, windows=1):
        saved = {}; failed = []
        chunks = {}
        def stream(index):
            # Overlap bounded API captures so the three-second deferred
            # constructor and its later callbacks have no sampling gap.
            time.sleep(index * 3)
            try: chunks[index] = rpc('logs.syslog', dict(seconds=4, process=process, max_lines=2000))
            except Exception as error: failed.append(str(error))
        threads = [threading.Thread(target=stream, args=(index,)) for index in range(windows)]
        for thread in threads: thread.start()
        time.sleep(.3)
        operation = action()
        for thread in threads:
            thread.join(timeout=22)
            if thread.is_alive(): raise RuntimeError('Log capture did not finish')
        seen = set(); entries = []
        for index in sorted(chunks):
            for entry in chunks[index].get('entries', []):
                key = json.dumps(entry, sort_keys=True)
                if key not in seen:
                    entries.append(entry); seen.add(key)
        saved.update(entries=entries, count=len(entries))
        record = dict(action=operation, log=saved, chunks=chunks, errors=failed)
        (args.output / (label + '.json')).write_text(json.dumps(record, indent=2) + '\n')
        result['captures'][label] = dict(entries=saved.get('count', 0), errors=failed)
    current = checked_camera_process(rpc('processes.list', {})['processes'])
    # Save the exact checked identity before the single TERM attempt. Never
    # resend a signal after an uncertain reply or signal a replacement PID.
    (args.output / 'signal-intent.json').write_text(json.dumps(dict(process=current, signal='TERM', attempts=1), indent=2) + '\n')
    try:
        capture('cameracaptured-initialization', 'cameracaptured',
                lambda: rpc('processes.kill', dict(pid=current['pid'], signal='TERM', force=True)), windows=7)
        rpc('screen.unlock', {})
        capture('probe-initialization', 'T52Acceptance', lambda: rpc('apps.launch', {'bundle_id': BUNDLE}))
        result['loaded'] = rpc('environment.loaded', {'processes': ['T52Acceptance', 'cameracaptured']})
        result['processes'] = [p for p in rpc('processes.list', {})['processes'] if p['name'] in ('cameracaptured', 'T52Acceptance', 'vphoned')]
        after = [p for p in rpc('processes.list', {})['processes'] if p['name'] == 'cameracaptured']
        assert len(after) == 1 and after[0]['pid'] != 70 and after[0]['uid'] == 501
        result['replacementCameraProcess'] = after[0]
    except Exception as error:
        result['error'] = str(error)
    finally:
        try: result['probeStop'] = rpc('apps.terminate', {'bundle_id': BUNDLE})
        except Exception as error: result['probeStopError'] = str(error)
        (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result['captures']))
    return 1 if any(k in result for k in ('error', 'probeStopError')) else 0


if __name__ == '__main__': raise SystemExit(main())
