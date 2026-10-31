#!/usr/bin/env python3
"""Deploy only the approved T52 v2-default classic publisher cache."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts'))
from host_control_client import endpoint, request
VM = ROOT / '.build/t51rt/lib/t52-v2'
SHA = '0c3c906aabd670968fe4947bbf68c1130f9af0c5c93216dad8ec8c80ed9332b8'
CACHE = '/var/root/Library/Caches/vphoned'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--instance-id', required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args(); args.output.mkdir(exist_ok=False)
    assert json.loads((VM / '.vphone-runtime.json').read_text())['instanceID'] == args.instance_id
    candidate = ROOT / '.build/t52-camera-interface-20261022/vphoned-v2'
    assert hashlib.sha256(candidate.read_bytes()).hexdigest() == SHA
    target = endpoint(VM.name, VM / 'vphone.sock')
    class Log:
        def record(self, target, payload, response):
            value = dict(response)
            if 'data' in value:
                data = base64.b64decode(value.pop('data'), validate=True)
                value.update(dataSHA256=hashlib.sha256(data).hexdigest(), dataBytes=len(data))
            with (args.output / 'requests.jsonl').open('a') as f:
                f.write(json.dumps(dict(time=time.time(), request=payload, response=value)) + '\n')
    def call(payload):
        r = request(target, payload, Log(), 20)
        if r.get('ok') is not True: raise RuntimeError(str(r))
        return r
    def rpc(method, params): return call(dict(t='rpc', method=method, params=params))['result']
    entries = rpc('files.list', {'path': '/var/root/Library/Caches'})['entries']
    existing = [entry for entry in entries if entry['name'] == 'vphoned']
    before = None
    if existing:
        assert len(existing) == 1 and existing[0]['is_symlink'] is False and existing[0]['type'] == 'file'
        before = base64.b64decode(call(dict(t='file_get', transport='api', path=CACHE))['data'], validate=True)
        (args.output / 'before-vphoned').write_bytes(before)
    service = rpc('services.status', {'label': 'com.vphone.vphoned'})
    (args.output / 'before-service.json').write_text(json.dumps(service, indent=2) + '\n')
    call(dict(t='file_put', transport='api', path=CACHE, load=str(candidate), perm='755'))
    actual = base64.b64decode(call(dict(t='file_get', transport='api', path=CACHE))['data'], validate=True)
    assert actual == candidate.read_bytes()
    processes = rpc('processes.list', {})['processes']
    pid = service['pid']
    matching = [row for row in processes if row['pid'] == pid]
    assert len(matching) == 1 and matching[0]['name'] == 'vphoned'
    assert matching[0]['executable'] in ('/usr/bin/vphoned', CACHE, '/private' + CACHE)
    rpc('processes.kill', {'pid': pid, 'signal': 'TERM', 'force': True})
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        try:
            caps = call(dict(t='capabilities'))
            if caps.get('commands', {}).get('camera_present') is True:
                break
        except RuntimeError: pass
        time.sleep(.5)
    else: raise RuntimeError('Updated publisher did not advertise camera readiness')
    result = dict(state='passed', instanceID=args.instance_id, publisherSHA256=SHA,
                  priorCacheSHA256=hashlib.sha256(before).hexdigest() if before is not None else None,
                  oldInstalledPublisherPreserved=True, capabilities=caps,
                  service=rpc('services.status', {'label': 'com.vphone.vphoned'}))
    (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(dict(state='passed', publisherSHA256=SHA, cameraPresent=True)))


if __name__ == '__main__': main()
