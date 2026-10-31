#!/usr/bin/env python3
"""Capture camera initialization in one explicitly named diagnostic VM session."""
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
EXPECTED = {'libcamfix.dylib': 'e4d026ce6942b4d75ff1a123c0360143e8c6b4a9fd3d862523e61e98676a3747',
            'libvcamcaptured.dylib': 'a41d3f8438f9841de0751322bf87eece6b19a2e56e1123952a20aa1860f70c71'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--instance-id', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args(); args.output.mkdir(exist_ok=False)
    runtime = json.loads((VM / '.vphone-runtime.json').read_text())
    assert runtime['operation'] == 'boot' and runtime['instanceID'] == args.instance_id
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
    current = [p for p in rpc('processes.list', {})['processes'] if p['name'] == 'cameracaptured']
    assert len(current) == 1 and current[0]['executable'] == '/usr/libexec/cameracaptured'
    capture('cameracaptured-initialization', 'cameracaptured',
            lambda: rpc('processes.kill', dict(pid=current[0]['pid'], signal='TERM', force=True)), windows=7)
    rpc('apps.terminate', {'bundle_id': BUNDLE})
    rpc('screen.unlock', {})
    capture('probe-initialization', 'T52Acceptance', lambda: rpc('apps.launch', {'bundle_id': BUNDLE}))
    result['loaded'] = rpc('environment.loaded', {'processes': ['T52Acceptance', 'cameracaptured']})
    result['processes'] = [p for p in rpc('processes.list', {})['processes'] if p['name'] in ('cameracaptured', 'T52Acceptance', 'vphoned')]
    result['probeStop'] = rpc('apps.terminate', {'bundle_id': BUNDLE})
    (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result['captures']))


if __name__ == '__main__': main()
