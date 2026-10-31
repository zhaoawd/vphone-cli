#!/usr/bin/env python3
"""Read the current T52 instance and installed library bytes without VM writes."""
import argparse
import base64
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts'))
from host_control_client import endpoint, request

VM = ROOT / '.build/t51rt/lib/t52-v2'
BASELINE = ROOT / ('research/upstream_integration_2026-10-15/evidence/'
                   'T52-provider-fix-20261023/runtime/files/.build/'
                   't52-provider-fix-20261023/runtime-final/result.json')


class Recorder:
    def __init__(self):
        self.rows = []

    def record(self, target, payload, response):
        result = dict(response)
        if 'data' in result:
            content = base64.b64decode(result.pop('data'), validate=True)
            result['capturedData'] = dict(bytes=len(content), sha256=hashlib.sha256(content).hexdigest())
        self.rows.append(dict(request=payload, response=result))


def observe():
    baseline = json.loads(BASELINE.read_text())
    runtime_bytes = (VM / '.vphone-runtime.json').read_bytes()
    runtime = json.loads(runtime_bytes)
    if runtime != baseline['runtime']:
        raise ValueError('The current runtime differs from the provider acceptance instance')
    binding_bytes = (VM / 'launchpad.json').read_bytes()
    binding = json.loads(binding_bytes)
    bundle = Path('/Library/Application Support/vphone-launchpad/Bundles') / binding['bundle'] / 'VPhone.bundle'
    command = subprocess.check_output(['/bin/ps', '-p', str(runtime['pid']), '-o', 'command='], text=True).strip()
    if not command.startswith(str(bundle / 'Contents/MacOS/vphone-vm') + ' '):
        raise ValueError('The running executable differs from the bound Bundle')
    binding_sha = hashlib.sha256(binding_bytes).hexdigest()
    if '--binding-sha256 ' + binding_sha not in command or '--no-vphoned-update' not in command:
        raise ValueError('The running binding or daemon-update policy differs')
    target = endpoint(VM.name, VM / 'vphone.sock')
    recorder = Recorder()
    capabilities = request(target, dict(t='capabilities'), recorder, 10)
    if capabilities.get('ok') is not True or capabilities.get('guest_connected') is not True:
        raise ValueError('The guest is not connected')
    libraries = {}
    for name, expected in baseline['libraries'].items():
        response = request(target, dict(t='file_get', path='/usr/lib/' + name), recorder, 15)
        if response.get('ok') is not True:
            raise ValueError(f'Cannot read {name}')
        content = base64.b64decode(response['data'], validate=True)
        sha = hashlib.sha256(content).hexdigest()
        if sha != expected or len(content) != response['size']:
            raise ValueError(f'{name} differs from the accepted provider deployment')
        libraries[name] = dict(bytes=len(content), sha256=sha)
    if (VM / '.vphone-runtime.json').read_bytes() != runtime_bytes \
            or (VM / 'launchpad.json').read_bytes() != binding_bytes:
        raise ValueError('The runtime or binding changed during observation')
    return dict(state='passed', observedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                runtime=runtime, binding=binding, bindingSHA256=binding_sha,
                command=command, capabilities=capabilities, libraries=libraries,
                requests=recorder.rows, VMStarted=False, VMStopped=False,
                limitation='File reads do not repeat application consumption or prove current mappings')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = observe()
    with args.output.open('x') as stream:
        stream.write(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(dict(state=result['state'], libraries=len(result['libraries']),
                         instanceID=result['runtime']['instanceID'])))


if __name__ == '__main__':
    main()
