#!/usr/bin/env python3
"""研究副本方向允许条件实验；仅覆盖受控应用和对应的 SpringBoard 场景参与者。"""
from pathlib import Path
import importlib.util
import json
import plistlib
import sys
import time
import uuid

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]
spec = importlib.util.spec_from_file_location('b33client', HERE.parents[1] / 'B33/T08/client.py')
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
client.check()
sys.path.insert(0, str(REPO / '.build/research-b33/python'))
import frida

ep = json.loads((REPO / '.build/research-b33/frida-endpoint.private.json').read_text())
device = frida.get_device_manager().add_remote_device(f"{ep['ip']}:{ep['port']}", token=Path(ep['token_file']).read_text())
front = client.rpc('apps.foreground')['reply']['result']
assert front['verified'] and front['bundle_id'] == 'research.vphone.b31.rotation'
springboard = next(p for p in device.enumerate_processes() if p.name == 'SpringBoard')
install = json.loads((REPO / '.build/research-b33/fixture-install.json').read_text())['reply']['result']
data = install['data_container']
assert install['bundle_id'] == front['bundle_id']
code = (HERE.parents[1] / 'B32/T08/fixture-policy.js').read_text() + '\n' + (HERE / 'request-boundary.js').read_text() + '\n' + (HERE / 'scene-gate.js').read_text()
out = REPO / '.build/research-b33' / ('scene-gate-' + uuid.uuid4().hex[:12])
out.mkdir(mode=0o700)
record = {'app_pid': front['pid'], 'springboard_pid': springboard.pid, 'read_only_springboard': False,
          'overrides_scope': 'fixture home-button condition and exact fixture SpringBoard scene delegate only', 'rows': [], 'restoration': {}}
sessions = []

def save():
    raw = json.dumps(record, indent=2, ensure_ascii=False) + '\n'
    assert Path(ep['token_file']).read_text().strip() not in raw
    assert (client.run / 'token').read_text().strip() not in raw
    (out / 'scene-gate.json').write_text(raw)

try:
    for name, pid in [('app', front['pid']), ('springboard', springboard.pid)]:
        session = device.attach(pid)
        script = session.create_script(code)
        script.load()
        sessions.append((name, session, script))
    app, sb = sessions[0][2], sessions[1][2]
    record['condition'] = app.exports_sync.arm()
    app_spec = [
        ['UIWindowScene', 'requestGeometryUpdateWithPreferences:errorHandler:'],
        ['UIWindowScene', '_performIOSGeometryRequestWithPreferences:errorHandler:'],
        ['UIWindowScene', '_interfaceOrientationForSupportedOrientations:preferredOrientation:'],
        ['UIWindowScene', '_updateClientSettingsToInterfaceOrientation:withAnimationDuration:'],
        ['UIApplication', '_fallbackInterfaceOrientationForSupportedOrientations:preferredOrientation:currentOrientation:'],
        ['FBSScene', '_updateClientSettings:'],
        ['FBSScene', 'updateClientSettings:withTransitionContext:'],
        ['FBSScene', 'updater:didUpdateSettings:withDiff:transitionContext:completion:']]
    sb_spec = [
        ['FBScene', 'clientToken:didUpdateClientSettings:withDiff:transitionContext:'],
        ['SBSceneManager', '_scene:didUpdateClientSettings:'],
        ['SBTraitsSceneOrientationRequestsAssistant', '_startSceneOrientationRequestWithDesiredOrientations:error:'],
        ['SBTraitsOrientationDefaultTreeResolver', '_targetOrientationForResolutionInfo:validatedInputs:rawInputs:participant:parent:'],
        ['SBTraitsOrientationDefaultTreeResolver', '_node:validatesNewSettings:'],
        ['FBScene', 'updateSettings:withTransitionContext:completion:']]
    record['hooks'] = {'app': app.exports_sync.tracearm(app_spec), 'springboard': sb.exports_sync.tracearm(sb_spec)}
    assert not any(h.get('missing') for group in record['hooks'].values() for h in group)
    app.exports_sync.sethome(1)
    app.exports_sync.invalidate()
    time.sleep(2)
    initial = app.exports_sync.policy()
    assert initial['pid'] == front['pid'] and initial['scenes'][0]['current_scene_mask'] == 30
    record['initial_policy'] = initial
    for phase, override in [('baseline-180', False), ('allowed-180', True), ('restored-180', False)]:
        mask = 4
        sb.exports_sync.gaterestore()
        client.rpc('display.rotation', {'orientation': '0'})
        time.sleep(2)
        client.check()
        request = phase + '-' + uuid.uuid4().hex
        app.exports_sync.tracebegin(request)
        sb.exports_sync.tracebegin(request)
        sb.exports_sync.gatebegin(request, override)
        plist = out / (phase + '.plist')
        plist.write_bytes(plistlib.dumps({'mask': 30, 'request_id': request, 'geometry_mask': mask}))
        put = client.ctl('file_put', path=data + '/Documents/policy.plist', load=str(plist), perm='644')
        assert put['ok']
        deadline = time.monotonic() + 11
        while time.monotonic() < deadline:
            client.check()
            time.sleep(.5)
        row = {'phase': phase, 'request_id': request, 'mask': mask, 'put': put,
               'app_events': app.exports_sync.traceend(), 'springboard_events': sb.exports_sync.traceend(),
               'policy': app.exports_sync.policy(), 'api': client.rpc('display.rotation'), 'gate_events': sb.exports_sync.gateend(), 'gate_override': override}
        log = out / (phase + '.jsonl')
        row['get_log'] = client.ctl('file_get', path=data + '/Documents/rotation.jsonl', save=str(log))
        assert row['get_log']['ok']
        row['matching_samples'] = [json.loads(x) for x in log.read_text().splitlines()
                                   if (json.loads(x).get('geometry_request') or {}).get('request_id') == request]
        assert len(row['matching_samples']) >= 40
        record['rows'].append(row)
        save()
        print(phase, 'app', len(row['app_events']), 'springboard', len(row['springboard_events']),
              'orientation', row['policy']['scenes'][0]['orientation'], flush=True)
except Exception as exc:
    record['failure'] = {'type': type(exc).__name__, 'message': str(exc)}
finally:
    if sessions:
        try:
            if len(sessions) > 1: record['restoration']['springboard_gate'] = sessions[1][2].exports_sync.gaterestore()
            sessions[0][2].exports_sync.sethome(None)
            sessions[0][2].exports_sync.invalidate()
            record['restoration']['home_button'] = True
            record['restoration']['rotation'] = client.rpc('display.rotation', {'orientation': '0'})
        except Exception as exc:
            record['restoration']['error'] = str(exc)
    for name, session, script in reversed(sessions):
        try:
            script.unload()
            session.detach()
            record['restoration'][name] = True
        except Exception as exc:
            record['restoration'][name] = {'error': str(exc)}
    save()
print(out)
if record.get('failure'):
    raise SystemExit(2)
