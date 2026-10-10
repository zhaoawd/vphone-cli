#!/usr/bin/env python3
"""T08 研究脚本：保存连续方向样本，分别判定旋转、拒绝和无错误未旋转。"""
import argparse
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import sys
import time
import uuid

BUNDLE = 'research.vphone.b31.rotation'
HERE = Path(__file__).resolve().parent
REPO = HERE.parents[4]


def classify(rows, request_id, requested_mask, target, expected_mask, seconds=10):
    samples = [r for r in rows if (r.get('geometry_request') or {}).get('request_id') == request_id]
    result = {'request_id': request_id, 'requested_mask': requested_mask,
              'target_orientation': target, 'expected_supported_mask': expected_mask,
              'samples': len(samples), 'required_span_seconds': seconds,
              'verdict': 'invalid_evidence', 'reasons': []}
    if not samples:
        result['reasons'].append('no_matching_request_samples')
        return result
    times = [r['time'] for r in samples]
    result['sample_span_seconds'] = times[-1] - times[0]
    result['pids'] = sorted({r['pid'] for r in samples})
    result['orientations'] = sorted({r['scene_orientation'] for r in samples})
    result['first_sample_time'], result['last_sample_time'] = times[0], times[-1]
    reasons = result['reasons']
    if len(result['pids']) != 1:
        reasons.append('pid_changed')
    if any(b <= a for a, b in zip(times, times[1:])):
        reasons.append('timestamps_not_strictly_increasing')
    if any(b - a > 1 for a, b in zip(times, times[1:])):
        reasons.append('sampling_gap_exceeds_one_second')
    if result['sample_span_seconds'] < seconds:
        reasons.append('observation_window_too_short')
    for name in ['current_scene_mask', 'scene_client_mask', 'effective_controller_mask']:
        if any(r.get(name) != expected_mask for r in samples):
            reasons.append(name + '_unexpected')
    if any(r.get('activation_state') != 0 for r in samples):
        reasons.append('scene_not_foreground_active')
    if any(r.get('scene_locked') is not False for r in samples):
        reasons.append('scene_locked_or_unknown')
    if any(r['geometry_request'].get('requested_mask') != requested_mask for r in samples):
        reasons.append('requested_mask_changed')
    errors = [r['geometry_request'].get('error') for r in samples]
    result['error_observed'] = any(e is not None for e in errors)
    result['target_seen'] = any(r['scene_orientation'] == target for r in samples)
    tail = [r for r in samples if r['time'] >= times[-1] - 1]
    result['target_stable_at_end'] = len(tail) >= 4 and all(r['scene_orientation'] == target for r in tail)
    if reasons:
        return result
    if result['error_observed']:
        result['verdict'] = ('unsupported_rejected' if all(
            e is None or (e.get('domain') == 'UISceneErrorDomain' and e.get('code') == 101)
            for e in errors) and not result['target_seen'] and not (expected_mask & requested_mask)
            else 'error_or_inconsistent_result')
    elif result['target_stable_at_end']:
        result['verdict'] = 'rotated'
    elif not result['target_seen']:
        result['verdict'] = 'no_error_without_rotation'
    else:
        result['verdict'] = 'target_seen_but_not_stable'
    return result


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + '\n')


def live(args):
    spec = importlib.util.spec_from_file_location('b33_client', HERE / 'client.py')
    client = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(client)
    client.check()  # 在任何客户机修改或输出目录创建前检查源停机及磁盘余量。
    health = client.rpc()
    assert health['http_status'] == 200
    layout = client.rpc('bootstrap.inspect')
    assert layout['http_status'] == 200
    assert layout['reply']['result'].get('layout') == 'roothide', 'RootHide acceptance required before live probe'
    rotation_before = client.rpc('display.rotation')
    assert rotation_before['http_status'] == 200
    assert rotation_before['reply']['result']['locked'] is False, 'rotation lock must already be disabled'
    # 安装输入必须来自本轮真实安装返回；不使用历史容器路径。
    install = json.loads(args.install_result.read_text())['reply']['result']
    assert install['bundle_id'] == BUNDLE
    data = install['data_container']
    assert data.startswith(('/private/var/mobile/Containers/Data/Application/', '/var/mobile/Containers/Data/Application/'))
    assert len(Path(data).parts) in (7, 8) and '..' not in Path(data).parts
    build = json.loads(args.fixture_build.read_text())
    ipa = Path(build['ipa'])
    assert hashlib.sha256(ipa.read_bytes()).hexdigest() == build['ipa_sha256']
    sys.path.insert(0, str(REPO / '.build/research-b33/python'))
    import frida
    assert frida.__version__ == '17.17.0'
    endpoint = json.loads(args.endpoint.read_text())
    token = Path(endpoint['token_file']).read_text().strip()
    output = REPO / '.build/research-b33' / ('rotation-' + uuid.uuid4().hex[:12])
    output.mkdir(mode=0o700)
    private_tokens = [token, (client.run / 'token').read_text().strip()]

    def save(name, value):
        raw = json.dumps(value, indent=2, ensure_ascii=False) + '\n'
        assert all(secret not in raw for secret in private_tokens)
        (output / name).write_text(raw)

    def result(method, params=None):
        reply = client.rpc(method, params)
        assert reply['http_status'] == 200 and 'error' not in reply['reply'], reply
        return reply

    def foreground(pid=None):
        reply = result('apps.foreground')['reply']['result']
        assert reply.get('verified') and reply.get('bundle_id') == BUNDLE
        if pid is not None:
            assert reply['pid'] == pid, 'fixture PID changed'
        return reply

    result('screen.unlock')
    result('apps.launch', {'bundle_id': BUNDLE})
    deadline = time.monotonic() + 10
    while True:
        front = client.rpc('apps.foreground')['reply'].get('result', {})
        if front.get('verified') and front.get('bundle_id') == BUNDLE:
            break
        assert time.monotonic() < deadline, 'fixture did not become foreground'
        time.sleep(.25)
    device = frida.get_device_manager().add_remote_device(
        f"{endpoint['ip']}:{endpoint['port']}", token=token)
    session = device.attach(front['pid'])
    # B32 接口复用原字节；实际方法锚点由本轮进程解析，失败即停止。
    policy_path = HERE.parents[1] / 'B32' / 'T08' / 'fixture-policy.js'
    script = session.create_script(policy_path.read_text())
    script.load()
    record = {'runtime_validated': False, 'front': front, 'health': health,
              'layout': layout, 'rotation_before': rotation_before, 'fixture': build,
              'policy_script_sha256': hashlib.sha256(policy_path.read_bytes()).hexdigest(),
              'frida_client_version': frida.__version__, 'window_seconds': args.seconds,
              'minimal': args.minimal,
              'rows': [], 'restoration': {}}
    try:
        record['condition'] = script.exports_sync.arm()
        initial_policy = script.exports_sync.policy()
        assert initial_policy['pid'] == front['pid'] and initial_policy['bundle_id'] == BUNDLE
        assert len(initial_policy['scenes']) == 1
        scene_id = initial_policy['scenes'][0]['session_id']
        assert scene_id
        if args.minimal:
            s = initial_policy['scenes'][0]
            assert s['orientation'] == 1 and s['activation_state'] == 0
            assert s['current_scene_mask'] == 26 and s['client_mask'] == 26
        record['initial_policy'] = initial_policy
        # 同一 PID：A 拒绝、B 横屏阳性对照、B 回到竖屏、B 倒置、恢复 A。
        phases = [('A-baseline-0', None, 2, 1, 26), ('A-native-180', None, 4, 2, 26),
                  ('B-home-90', 1, 8, 3, 30), ('B-home-0', 1, 2, 1, 30),
                  ('B-home-180', 1, 4, 2, 30), ('A-restored-0', None, 2, 1, 26),
                  ('A-restored-180', None, 4, 2, 26)]
        if args.minimal:
            phases = [('B-home-180', 1, 4, 2, 30)]
        for phase, override, mask, target, supported in phases:
            client.check()
            foreground(front['pid'])
            script.exports_sync.sethome(override)
            script.exports_sync.invalidate()
            time.sleep(.6)
            request = phase + '-' + uuid.uuid4().hex
            policy = output / (phase + '.plist')
            policy.write_bytes(plistlib.dumps({'mask': 30, 'request_id': request, 'geometry_mask': mask}))
            row = {'phase': phase, 'request_id': request, 'override': override,
                   'policy_before': script.exports_sync.policy()}
            row['put'] = client.ctl('file_put', path=data + '/Documents/policy.plist', load=str(policy), perm='644')
            assert row['put']['ok'], row['put']
            deadline = time.monotonic() + args.seconds + 15
            log = output / (phase + '.jsonl')
            while True:
                client.check()
                row['get_log'] = client.ctl('file_get', path=data + '/Documents/rotation.jsonl', save=str(log))
                assert row['get_log']['ok'], row['get_log']
                samples = [json.loads(s) for s in log.read_text().splitlines()]
                verdict = classify(samples, request, mask, target, supported, args.seconds)
                if verdict.get('sample_span_seconds', 0) >= args.seconds or time.monotonic() >= deadline:
                    break
                time.sleep(.5)
            row.update(analysis=verdict, policy_after=script.exports_sync.policy(),
                       api=result('display.rotation'), foreground=foreground(front['pid']))
            observed_policy = row['policy_after']
            assert observed_policy['pid'] == front['pid'] and observed_policy['bundle_id'] == BUNDLE
            assert len(observed_policy['scenes']) == 1 and observed_policy['scenes'][0]['session_id'] == scene_id
            row['condition_observations'] = script.exports_sync.observations()
            shot = result('screen.screenshot')
            payload = shot['reply']['result'].pop('data')
            image = base64.b64decode(payload, validate=True)
            (output / (phase + '.jpeg')).write_bytes(image)
            shot['reply']['result'].update(saved_file=phase + '.jpeg', sha256=hashlib.sha256(image).hexdigest())
            row['screenshot'] = shot
            record['rows'].append(row)
            save('rotation-probe.json', record)
            print(phase, verdict['verdict'], flush=True)
            assert verdict['verdict'] != 'invalid_evidence', verdict
        verdicts = {r['phase']: r['analysis']['verdict'] for r in record['rows']}
        if args.minimal:
            controls = verdicts['B-home-180'] != 'invalid_evidence'
            record['controls_scope'] = 'starting conditions only; full positive/refusal controls require the separate full matrix'
        else:
            controls = all(verdicts[p] == 'rotated' for p in ['A-baseline-0', 'B-home-90', 'B-home-0', 'A-restored-0'])
            controls = controls and all(verdicts[p] == 'unsupported_rejected' for p in ['A-native-180', 'A-restored-180'])
        record['controls_passed'] = controls
        record['runtime_validated'] = controls
        record['bug_reproduced'] = controls and verdicts['B-home-180'] == 'no_error_without_rotation'
        record['rotation_passed'] = controls and verdicts['B-home-180'] == 'rotated'
    except Exception as exc:
        record['failure'] = {'type': type(exc).__name__, 'message': str(exc)}
    finally:
        # 先恢复进程内策略；客户机接口被源状态保护拒绝时仍保留恢复失败。
        try:
            script.exports_sync.sethome(None)
            script.exports_sync.invalidate()
            record['restoration']['native_home_button'] = True
            record['restoration']['portrait'] = result('display.rotation', {'orientation': '0'})
        except Exception as exc:
            record['restoration']['error'] = str(exc)
        finally:
            for name, cleanup in [('script_unload', script.unload), ('session_detach', session.detach)]:
                try:
                    cleanup()
                    record['restoration'][name] = True
                except Exception as exc:
                    record['restoration'][name] = {'error': str(exc)}
            save('rotation-probe.json', record)
    print(output)
    if any(isinstance(v, dict) and 'error' in v for v in record['restoration'].values()) or 'error' in record['restoration'] or record.get('failure'):
        return 2
    return 0 if record.get('rotation_passed') else (1 if record.get('bug_reproduced') else 2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='mode', required=True)
    replay = sub.add_parser('replay')
    replay.add_argument('jsonl', type=Path)
    replay.add_argument('--request-id', required=True)
    replay.add_argument('--request-mask', type=int, default=4)
    replay.add_argument('--target', type=int, default=2)
    replay.add_argument('--supported-mask', type=int, default=30)
    replay.add_argument('--seconds', type=float, default=10)
    run = sub.add_parser('live')
    run.add_argument('--install-result', type=Path, required=True)
    run.add_argument('--endpoint', type=Path, required=True, help='私有 JSON：ip、port、token_file；不归档')
    run.add_argument('--fixture-build', type=Path, default=HERE / 'fixture-build.json')
    run.add_argument('--minimal', action='store_true', help='只发送B条件180°；起始实际方向必须为1且原生集合为26')
    run.add_argument('--seconds', type=float, default=10)
    args = parser.parse_args()
    if args.seconds < 10:
        parser.error('至少连续观测 10 秒')
    if args.mode == 'live':
        return live(args)
    rows = [json.loads(s) for s in args.jsonl.read_text().splitlines()]
    verdict = classify(rows, args.request_id, args.request_mask, args.target, args.supported_mask, args.seconds)
    print(json.dumps(verdict, indent=2))
    return {'rotated': 0, 'no_error_without_rotation': 1}.get(verdict['verdict'], 2)


if __name__ == '__main__':
    sys.exit(main())
