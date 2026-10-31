#!/usr/bin/env python3
"""Transition one publisher cache through host RPC; preserve the old executable."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
WORK = ROOT / '.build/t52-consumer-fix-20261022'
VM = ROOT / '.build/t51rt/lib/t52-v2'
CACHE = '/var/root/Library/Caches/vphoned'
BEFORE = '0c3c906aabd670968fe4947bbf68c1130f9af0c5c93216dad8ec8c80ed9332b8'
AFTER = '158112408243280d3639947a1c3ea3453550d5ea4573d570323d5ec2c7806d10'
API = 'f5ce73f00f5694b1639d735af8106436aaf2cfd1bd3dc7211aef6041149cd2a8'


def sha(data):
    return hashlib.sha256(data).hexdigest()


def transition(call, rpc, candidate, *, before=BEFORE, after=AFTER, nonce=None):
    nonce = nonce or uuid.uuid4().hex
    if len(nonce) != 32 or any(c not in '0123456789abcdef' for c in nonce):
        raise ValueError('Invalid transaction identifier')
    staged = CACHE + '.t52-' + nonce + '.new'
    retained = CACHE + '.t52-' + nonce + '.previous'
    entries = rpc('files.list', {'path': '/var/root/Library/Caches'})['entries']
    names = {row['name']: row for row in entries}
    if any(name in names for name in (Path(staged).name, Path(retained).name, 'vphoned-api', 'vphoned.api-v2.pending')):
        raise ValueError('Conflicting staging path, API cache or pending update')
    row = names.get('vphoned', {})
    if row.get('type') != 'file' or row.get('is_symlink') is not False or row.get('perm') != '755':
        raise ValueError('Publisher cache type or mode differs')
    def read(path):
        return base64.b64decode(call(dict(t='file_get', transport='api', path=path))['data'], validate=True)
    if sha(read(CACHE)) != before or sha(candidate.read_bytes()) != after:
        raise ValueError('Publisher input or candidate digest differs')
    call(dict(t='file_put', transport='api', path=staged, load=str(candidate), perm='755'))
    if sha(read(staged)) != after or sha(read(CACHE)) != before:
        raise ValueError('Staged publisher readback or prior cache changed')
    try:
        rpc('files.rename', {'from': CACHE, 'to': retained})
        rpc('files.rename', {'from': staged, 'to': CACHE})
    except Exception:
        # An RPC timeout can happen after rename. Inspect actual bytes before
        # deciding whether to restore the original name. Never overwrite it.
        current = {r['name'] for r in rpc('files.list', {'path': '/var/root/Library/Caches'})['entries']}
        if 'vphoned' not in current and Path(retained).name in current and sha(read(retained)) == before:
            rpc('files.rename', {'from': retained, 'to': CACHE})
        elif 'vphoned' in current and Path(retained).name in current and \
                sha(read(CACHE)) == after and sha(read(retained)) == before:
            return dict(state='published', retained=retained, publisherSHA256=after, responseRecovered=True)
        raise
    if sha(read(CACHE)) != after or sha(read(retained)) != before:
        raise ValueError('Published or retained publisher readback differs')
    return dict(state='published', retained=retained, publisherSHA256=after, responseRecovered=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--instance-id', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(exist_ok=False)
    assert json.loads((VM / '.vphone-runtime.json').read_text())['instanceID'] == args.instance_id
    assert json.loads((VM / 'launchpad.json').read_text())['bundle'] == '2.6.2-local.cc05d88f441f'
    sys.path.insert(0, str(ROOT / 'scripts'))
    from host_control_client import endpoint, request
    target = endpoint(VM.name, VM / 'vphone.sock')
    class Log:
        def record(self, target, payload, response):
            response = dict(response)
            if 'data' in response:
                data = base64.b64decode(response.pop('data'), validate=True)
                response.update(dataSHA256=sha(data), dataBytes=len(data))
            with (args.output / 'requests.jsonl').open('a') as stream:
                stream.write(json.dumps(dict(time=time.time(), request=payload, response=response)) + '\n')
    def call(payload):
        response = request(target, payload, Log(), 25)
        if response.get('ok') is not True: raise RuntimeError(str(response))
        return response
    def rpc(method, params): return call(dict(t='rpc', method=method, params=params))['result']
    assert rpc('device.info', {})['agent']['binary_hash'] == API
    source = call(dict(t='location_source_status'))
    assert source.get('state') == 'off', source
    before_service = rpc('services.status', {'label': 'com.vphone.vphoned'})
    pid = before_service['pid']
    rows = [p for p in rpc('processes.list', {})['processes'] if p['pid'] == pid]
    assert len(rows) == 1 and rows[0]['name'] == 'vphoned'
    assert rows[0]['executable'] in ('/usr/bin/vphoned', CACHE, '/private' + CACHE)
    result = transition(call, rpc, WORK / 'vphoned-v2-r2')
    (args.output / 'cache-transition.json').write_text(json.dumps(result, indent=2) + '\n')
    # The API daemon and VM remain running; only the exact old classic publisher
    # receives TERM after both old and new executable bytes have been verified.
    rpc('processes.kill', {'pid': pid, 'signal': 'TERM', 'force': True})
    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:
        service = rpc('services.status', {'label': 'com.vphone.vphoned'})
        caps = call(dict(t='capabilities'))
        if service.get('pid') not in (None, 0, pid) and caps.get('commands', {}).get('camera_present') is True:
            result.update(state='passed', oldPublisherPID=pid, newPublisherPID=service['pid'], instanceID=args.instance_id)
            (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
            print(json.dumps(result)); return
        time.sleep(.3)
    raise RuntimeError('Publisher did not reconnect with a new PID')


if __name__ == '__main__': main()
