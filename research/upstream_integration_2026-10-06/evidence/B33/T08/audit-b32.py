#!/usr/bin/env python3
"""复核历史 A/B/A 记录；该检查不驱动真实 UIKit 请求。"""
import hashlib
import json
from pathlib import Path

here = Path(__file__).resolve().parent
old = here.parents[1] / 'B32/T08'
matrix = json.loads((old / 'fixture-aba.json').read_text())
result = {'scope': 'historical_evidence_only', 'live_reproduction': False, 'rows': []}
pid = matrix['front']['pid']
for phase, mask, expected_error in [('A-native', 26, 101), ('B-home-button-true', 30, None), ('A-restored', 26, 101)]:
    row = next(r for r in matrix['rows'] if r['phase'] == phase)
    raw = (old / (phase + '.jsonl')).read_bytes()
    samples = [json.loads(line) for line in raw.decode().splitlines()]
    requested = [s for s in samples if isinstance(s.get('geometry_request'), dict) and s['geometry_request'].get('request_id') == phase]
    assert requested, phase
    for s in requested:
        assert s['pid'] == pid and s['geometry_request']['requested_mask'] == 4
        assert s['current_scene_mask'] == mask and s['scene_client_mask'] == mask
        assert s['effective_controller_mask'] == mask
        assert s['scene_orientation'] == 1 and s['scene_locked'] is False
        assert s['activation_state'] == 0
        error = s['geometry_request']['error']
        assert (error['code'] if error else None) == expected_error
    for stage in ['policy_before', 'policy_after']:
        policy = row[stage]
        assert policy['pid'] == pid
        assert len(policy['scenes']) == 1
        scene = policy['scenes'][0]
        assert scene['current_scene_mask'] == mask and scene['client_mask'] == mask
        assert scene['orientation'] == 1
    readback = row['api']['reply']['result']
    assert readback['degrees'] == 0 and readback['locked'] is False
    result['rows'].append({'phase': phase, 'pid': pid, 'mask': mask, 'request_mask': 4, 'scene_orientation': 1, 'error_code': expected_error, 'samples': len(requested), 'sample_span_seconds': requested[-1]['time'] - requested[0]['time'], 'call_to_last_sample_seconds': requested[-1]['time'] - requested[0]['geometry_request']['call_time'] if 'call_time' in requested[0]['geometry_request'] else None, 'jsonl_sha256': hashlib.sha256(raw).hexdigest()})
result['missing_evidence'] = ['SpringBoard request receipt and processing', 'request completion callback or FBS server reply', 'long observation window', 'positive 90-degree request in B condition']
(here / 'b32-audit.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
