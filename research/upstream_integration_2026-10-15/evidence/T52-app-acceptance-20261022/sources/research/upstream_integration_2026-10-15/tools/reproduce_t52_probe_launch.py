#!/usr/bin/env python3
"""Assert actual probe launch in the already-running independent T52 VM."""
import argparse
import json
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts'))
from host_control_client import endpoint, request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--bundle-id', default='org.vphone.acceptance.t52.20261022')
    args = parser.parse_args()
    if not args.bundle_id.startswith('org.vphone.acceptance.t52.'):
        parser.error('Only a named T52 diagnostic app may be launched')
    args.output.mkdir(exist_ok=False)
    vm = ROOT / '.build/t51rt/lib/t52-v2'
    target = endpoint(vm.name, vm / 'vphone.sock')
    runtime = json.loads((vm / '.vphone-runtime.json').read_text())
    baseline = json.loads((ROOT / '.build/t52-app-acceptance-20261022/api-capabilities.json').read_text())
    if runtime['instanceID'] != baseline['target']['instance_id']:
        raise RuntimeError('Running acceptance instance changed')

    class Recorder:
        def record(self, target, payload, response):
            with (args.output / 'requests.jsonl').open('a') as stream:
                stream.write(json.dumps(dict(time=time.time(), request=payload, response=response)) + '\n')

    recorder = Recorder()
    health = request(target, dict(t='rpc', method='agent.health', params={}), recorder, 15)
    if health.get('result', {}).get('setup_pending') is not False:
        raise RuntimeError('Initial setup must be completed before the launch experiment')
    unlocked = request(target, dict(t='rpc', method='screen.unlock', params={}), recorder, 15)
    if unlocked.get('ok') is not True or unlocked.get('result', {}).get('locked') is not False:
        raise RuntimeError('The named guest must be unlocked before the launch experiment')
    result = request(target, dict(t='rpc', method='apps.launch', params={'bundle_id': args.bundle_id}), recorder, 20)
    processes = request(target, dict(t='rpc', method='processes.list', params={}), recorder, 15)
    matches = [p for p in processes.get('result', {}).get('processes', []) if p.get('bundle_id') == args.bundle_id]
    passed = result.get('ok') is True and any(p.get('pid', 0) > 0 for p in matches)
    summary = dict(state='passed' if passed else 'failed', bundleID=args.bundle_id,
                   observedAt=time.time(), launch=result, runningProcesses=matches,
                   vmInstanceID=runtime['instanceID'])
    (args.output / 'result.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(json.dumps(summary))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
