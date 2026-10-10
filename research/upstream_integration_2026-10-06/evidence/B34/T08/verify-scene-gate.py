#!/usr/bin/env python3
"""回放实际 A/B/A 场景允许条件实验，并核对方向、请求和恢复证据。"""
import importlib.util
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('rotation_probe', HERE.parents[1] / 'B33/T08/rotation_probe.py')
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
p = HERE / 'scene-gate-1a6e985e17da/scene-gate.json'
data = json.loads(p.read_text())
assert not data.get('failure')
expected = [('baseline-180', False, 1, 26, 'no_error_without_rotation'),
            ('allowed-180', True, 2, 30, 'rotated'),
            ('restored-180', False, 1, 26, 'target_seen_but_not_stable')]
assert len(data['rows']) == len(expected)
rows = []
for row, (phase, overridden, orientation, mask, verdict) in zip(data['rows'], expected):
    assert row['phase'] == phase and row['gate_override'] == overridden
    actual = probe.classify(row['matching_samples'], row['request_id'], 4, 2, 30)
    assert actual['verdict'] == verdict, actual
    assert row['policy']['scenes'][0]['orientation'] == orientation
    gates = row['gate_events']
    assert gates and all('research.vphone.b31.rotation' in e['receiver'] for e in gates)
    allows = [e for e in gates if e['selector'] == '_isAllowedToHavePortraitUpsideDown']
    assert allows and all(e['native'] == 0 and e['returned'] == int(overridden) for e in allows)
    sanitizers = [e for e in gates if e['selector'] == '_sanitizedMask:forApplication:']
    assert sanitizers and all(e['input'] == 30 and e['returned'] == mask for e in sanitizers)
    assert all(s['pid'] == data['app_pid'] for s in row['matching_samples'])
    rows.append({'phase': phase, 'override': overridden, 'system_supported_mask': mask, 'classification': actual})
assert data['restoration']['springboard_gate'] is True
assert data['restoration']['springboard'] is True and data['restoration']['app'] is True
assert data['restoration']['home_button'] is True
assert data['restoration']['rotation']['reply']['result']['degrees'] == 0
clean = json.loads((HERE / 'rotation-7a6b72017d0e/rotation-probe.json').read_text())
assert not clean.get('failure') and clean['bug_reproduced'] is True
assert clean['rows'][0]['analysis']['verdict'] == 'no_error_without_rotation'
print(json.dumps({'evidence': str(p.relative_to(HERE)), 'causal_counterfactual_verified': True,
                  'scope': 'fixed research guest and controlled scene only', 'rows': rows,
                  'restoration_verified': True}, indent=2, ensure_ascii=False))
