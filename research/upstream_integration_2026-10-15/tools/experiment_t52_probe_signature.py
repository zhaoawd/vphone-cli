#!/usr/bin/env python3
"""Compare one named probe executable in the existing T52 acceptance VM."""
import argparse
import base64
import hashlib
import json
import plistlib
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts'))
from host_control_client import endpoint, request

VM = ROOT / '.build/t51rt/lib/t52-v2'
WORK = ROOT / '.build/t52-app-acceptance-20261022'
BUNDLE = 'org.vphone.acceptance.t52.20261022'
APP = '/var/containers/Bundle/Application/FE3CFC90-BF86-41D6-8123-31520D687DEA/T52Acceptance.app'
INSTANCE = '1B6A2DA7-7B19-41ED-BB2D-3FF385497E21'


def validate_candidate(path):
    signed = subprocess.run([str(ROOT / '.build/debug/vphone-cli'), 'dump-entitlements', str(path)],
                            capture_output=True, check=True)
    entitlements = plistlib.loads(signed.stdout)
    if entitlements.get('com.apple.private.security.container-required') != BUNDLE:
        raise ValueError('Candidate must retain the named formal data-container entitlement')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--candidate', type=Path, required=True)
    p.add_argument('--expected-current', required=True)
    p.add_argument('--info-plist', type=Path)
    p.add_argument('--defer-launch', action='store_true', help='Record installed_launch_pending; consumer script must verify launch separately')
    p.add_argument('--instance-id', default=INSTANCE)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    validate_candidate(args.candidate)
    args.output.mkdir(exist_ok=False)
    assert json.loads((VM / '.vphone-runtime.json').read_text())['instanceID'] == args.instance_id
    target = endpoint(VM.name, VM / 'vphone.sock')

    class Recorder:
        def record(self, target, payload, response):
            record = dict(response)
            if 'data' in record:
                data = base64.b64decode(record.pop('data'), validate=True)
                record.update(dataBytes=len(data), dataSHA256=hashlib.sha256(data).hexdigest())
            with (args.output / 'requests.jsonl').open('a') as f:
                f.write(json.dumps(dict(time=time.time(), request=payload, response=record)) + '\n')

    recorder = Recorder()

    def call(payload, timeout=20):
        r = request(target, payload, recorder, timeout)
        if r.get('ok') is not True:
            raise RuntimeError(str(r))
        return r

    def rpc(method, params):
        return call(dict(t='rpc', method=method, params=params))['result']

    info = rpc('apps.info', {'bundle_id': BUNDLE})
    assert info['bundle_path'] == '/private' + APP
    assert rpc('agent.health', {}).get('setup_pending') is False
    assert rpc('screen.unlock', {}).get('locked') is False
    if any(x.get('bundle_id') == BUNDLE for x in rpc('processes.list', {})['processes']):
        rpc('apps.terminate', {'bundle_id': BUNDLE})
    assert not any(x.get('bundle_id') == BUNDLE for x in rpc('processes.list', {})['processes'])
    path = APP + '/T52Acceptance'
    before = base64.b64decode(call(dict(t='file_get', transport='api', path=path))['data'], validate=True)
    assert hashlib.sha256(before).hexdigest() == args.expected_current
    (args.output / 'before').write_bytes(before)
    candidate = args.candidate.resolve()
    before_info = None
    if args.info_plist:
        import plistlib
        before_info = base64.b64decode(call(dict(t='file_get', transport='api', path=APP + '/Info.plist'))['data'], validate=True)
        assert plistlib.loads(args.info_plist.read_bytes())['CFBundleIdentifier'] == BUNDLE
        (args.output / 'before-Info.plist').write_bytes(before_info)
        call(dict(t='file_put', transport='api', path=APP + '/Info.plist', load=str(args.info_plist.resolve()), perm='644'))
    result = dict(instanceID=args.instance_id, beforeSHA256=args.expected_current,
                  candidateSHA256=hashlib.sha256(candidate.read_bytes()).hexdigest())
    call(dict(t='file_put', transport='api', path=path, load=str(candidate), perm='755'))
    current = base64.b64decode(call(dict(t='file_get', transport='api', path=path))['data'], validate=True)
    assert current == candidate.read_bytes()
    rpc('apps.register', {'path': APP, 'registration': 'User'})
    after_info = rpc('apps.info', {'bundle_id': BUNDLE})
    assert after_info['data_path'] == info['data_path'], 'Registered data container changed'
    assert after_info['entitlements'].get('com.apple.private.security.container-required') == BUNDLE
    result.update(dataPath=after_info['data_path'], dataContainerPreserved=True)
    if args.defer_launch:
        result.update(state='installed_launch_pending', passed=False)
        (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result))
        return 0
    run = subprocess.run([str(ROOT / '.venv/bin/python'), '-B',
                          str(Path(__file__).with_name('reproduce_t52_probe_launch.py')),
                          '--output', str(args.output / 'launch'), '--instance-id', args.instance_id], capture_output=True, text=True)
    (args.output / 'launch.log').write_text(run.stdout + run.stderr)
    result.update(launchExitCode=run.returncode, passed=run.returncode == 0)
    if run.returncode != 0:
        call(dict(t='file_put', transport='api', path=path,
                  load=str((args.output / 'before').resolve()), perm='755'))
        if before_info is not None:
            call(dict(t='file_put', transport='api', path=APP + '/Info.plist',
                      load=str((args.output / 'before-Info.plist').resolve()), perm='644'))
        rpc('apps.register', {'path': APP, 'registration': 'User'})
        restored = base64.b64decode(call(dict(t='file_get', transport='api', path=path))['data'], validate=True)
        assert restored == before
        result['restoredOriginal'] = True
    (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    return run.returncode


if __name__ == '__main__':
    raise SystemExit(main())
