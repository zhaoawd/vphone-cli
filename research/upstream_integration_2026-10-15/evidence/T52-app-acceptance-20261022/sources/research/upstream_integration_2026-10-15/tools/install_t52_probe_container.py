#!/usr/bin/env python3
"""Apply the explicitly approved T52 probe registration/container transition."""
import base64
import hashlib
import json
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts'))
from host_control_client import endpoint, request

WORK = ROOT / '.build/t52-app-acceptance-20261022'
VM = ROOT / '.build/t51rt/lib/t52-v2'
BUNDLE = 'org.vphone.acceptance.t52.20261022'
OLD = '/var/mobile/T52Acceptance-20261022.app'
UPLOAD = '/var/mobile/Library/Caches/t52-acceptance-8eb8ded2.ipa'


def main():
    result = dict(state='preflight', startedAt=time.time())

    def save():
        (WORK / 'container-transition-result.json').write_text(json.dumps(result, indent=2) + '\n')

    plan = json.loads((WORK / 'container-install-plan.json').read_text())
    ipa = Path(plan['ipa'])
    if hashlib.sha256(ipa.read_bytes()).hexdigest() != '8eb8ded29a3e309a2e6acb19f3978006e8e80db66aad86a07b1280d9217f1e19':
        raise RuntimeError('Approved IPA changed')
    runtime = json.loads((VM / '.vphone-runtime.json').read_text())
    if runtime['instanceID'] != '1B6A2DA7-7B19-41ED-BB2D-3FF385497E21':
        raise RuntimeError('Acceptance VM instance changed')
    target = endpoint(VM.name, VM / 'vphone.sock')

    class Recorder:
        def record(self, target, payload, response):
            captured = dict(response)
            if 'data' in captured:
                data = base64.b64decode(captured.pop('data'), validate=True)
                captured['dataSHA256'] = hashlib.sha256(data).hexdigest()
                captured['dataBytes'] = len(data)
            with (WORK / 'container-transition-requests.jsonl').open('a') as stream:
                stream.write(json.dumps(dict(time=time.time(), request=payload, response=captured)) + '\n')

    recorder = Recorder()

    def rpc(method, params):
        response = request(target, dict(t='rpc', method=method, params=params), recorder, 25)
        if response.get('ok') is not True:
            raise RuntimeError(f'{method}: {response}')
        return response['result']

    def old_files():
        observed = {}
        for name in ('Info.plist', 'T52Acceptance', '_CodeSignature/CodeResources'):
            response = request(target, dict(t='file_get', transport='api', path=OLD + '/' + name), recorder, 15)
            if response.get('ok') is not True:
                raise RuntimeError('Could not preserve old probe bytes: ' + name)
            observed[name] = hashlib.sha256(base64.b64decode(response['data'], validate=True)).hexdigest()
        return observed

    save()
    try:
        info = rpc('apps.info', {'bundle_id': BUNDLE})
        if info.get('bundle_path') != '/private' + OLD:
            raise RuntimeError('Registered path differs from the approved probe')
        processes = rpc('processes.list', {})
        if any(p.get('bundle_id') == BUNDLE or p.get('name') == 'T52Acceptance'
               for p in processes['processes']):
            raise RuntimeError('Probe unexpectedly running')
        entries = rpc('files.list', {'path': '/var/mobile/Library/Caches'})['entries']
        if any(p['name'] == UPLOAD.rsplit('/', 1)[1] for p in entries):
            raise RuntimeError('Upload path already exists')
        before = old_files()
        result.update(oldFiles=before, oldDataPath=info['data_path'])
        save()
        removed = rpc('apps.unregister', {'path': OLD, 'force': True})
        if removed.get('unregistered') is not True:
            raise RuntimeError('Probe registration was not removed')
        result.update(state='old_registration_removed', unregistered=removed)
        save()
        uploaded = request(target, dict(t='file_put', transport='api', path=UPLOAD,
                           load=str(ipa), perm='644'), recorder, 25)
        if uploaded.get('ok') is not True:
            raise RuntimeError('IPA upload failed: ' + str(uploaded))
        result.update(state='ipa_uploaded')
        save()
        installed = request(target, dict(t='rpc', method='apps.install',
                            params={'path': UPLOAD, 'registration': 'User'}), recorder, 30)
        result.update(state='installation_replied', installation=installed)
        save()
        if installed.get('ok') is not True:
            raise RuntimeError('Installation not verified; inspect state before retry: ' + str(installed))
        current = rpc('apps.info', {'bundle_id': BUNDLE})
        if not current.get('bundle_path', '').startswith('/private/var/containers/Bundle/Application/'):
            raise RuntimeError('Expected a native bundle container')
        if current.get('data_path') != info['data_path'] or old_files() != before:
            raise RuntimeError('Old files or data path changed')
        result.update(state='installed_and_verified', current=current,
                      oldFilesPreserved=True, oldDataPathPreserved=True, finishedAt=time.time())
        save()
        print(json.dumps(result, indent=2))
    except Exception as error:
        result.update(error=f'{type(error).__name__}: {error}', observedAt=time.time())
        save()
        raise


if __name__ == '__main__':
    main()
