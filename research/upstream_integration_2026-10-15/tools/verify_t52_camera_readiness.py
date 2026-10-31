#!/usr/bin/env python3
"""Assert camera presentation readiness in the existing independent T52 VM."""
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
    parser.add_argument('--instance-id', default='1B6A2DA7-7B19-41ED-BB2D-3FF385497E21')
    args = parser.parse_args()
    args.output.mkdir(exist_ok=False)
    vm = ROOT / '.build/t51rt/lib/t52-v2'
    runtime = json.loads((vm / '.vphone-runtime.json').read_text())
    if runtime['instanceID'] != args.instance_id:
        raise RuntimeError('Acceptance VM instance changed')
    target = endpoint(vm.name, vm / 'vphone.sock')

    class Recorder:
        def record(self, target, payload, response):
            with (args.output / 'requests.jsonl').open('a') as stream:
                stream.write(json.dumps(dict(time=time.time(), request=payload, response=response)) + '\n')

    recorder = Recorder()
    caps = request(target, dict(t='capabilities'), recorder, 10)
    status = request(target, dict(t='camera_status', generation='t52-readiness'), recorder, 15)
    ready = (caps.get('ok') is True and caps.get('guest_connected') is True
             and caps.get('commands', {}).get('camera_present') is True)
    result = dict(state='ready' if ready else 'not_ready', observedAt=time.time(),
                  vmInstanceID=runtime['instanceID'], cameraPresent=caps.get('commands', {}).get('camera_present'),
                  cameraStatus=status, consumerBehaviorVerified=False)
    (args.output / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    return 0 if ready else 1


if __name__ == '__main__':
    raise SystemExit(main())
