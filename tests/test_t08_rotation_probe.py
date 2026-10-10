"""T08 证据判定回归；不驱动 UIKit，不替代实际 VM 复现。"""
import copy
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / 'research/upstream_integration_2026-10-06/evidence/B33/T08/rotation_probe.py'
spec = importlib.util.spec_from_file_location('rotation_probe', PROBE)
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


def samples(orientation=1, mask=30, error=None):
    return [{'time': 100 + i * .25, 'pid': 985, 'scene_orientation': orientation,
             'scene_locked': False, 'activation_state': 0,
             'current_scene_mask': mask, 'scene_client_mask': mask,
             'effective_controller_mask': mask,
             'geometry_request': {'request_id': 'test', 'requested_mask': 4,
                                  'error': copy.deepcopy(error)}} for i in range(41)]


def classify(rows, mask=30):
    return probe.classify(rows, 'test', 4, 2, mask)


class RotationEvidenceTests(unittest.TestCase):
    def test_no_error_does_not_establish_rotation(self):
        r = classify(samples())
        self.assertEqual(r['verdict'], 'no_error_without_rotation')
        self.assertFalse(r['target_seen'])

    def test_stable_actual_orientation_establishes_rotation(self):
        self.assertEqual(classify(samples(2))['verdict'], 'rotated')

    def test_transient_target_is_separate_from_stable_rotation(self):
        rows = samples()
        rows[10]['scene_orientation'] = 2
        self.assertEqual(classify(rows)['verdict'], 'target_seen_but_not_stable')

    def test_rejected_unsupported_request_requires_actual_error(self):
        e = {'domain': 'UISceneErrorDomain', 'code': 101}
        self.assertEqual(classify(samples(mask=26, error=e), 26)['verdict'], 'unsupported_rejected')
        self.assertEqual(classify(samples(error=e))['verdict'], 'error_or_inconsistent_result')

    def test_stale_request_samples_cannot_extend_window(self):
        rows = samples()
        for row in rows[5:]:
            row['geometry_request']['request_id'] = 'older-request'
        r = classify(rows)
        self.assertEqual(r['samples'], 5)
        self.assertIn('observation_window_too_short', r['reasons'])

    def test_policy_background_lock_and_pid_are_preconditions(self):
        for field, value in [('pid', 999), ('activation_state', 1), ('scene_locked', True),
                             ('current_scene_mask', 26), ('scene_client_mask', 26),
                             ('effective_controller_mask', 26)]:
            with self.subTest(field=field):
                rows = samples()
                rows[10][field] = value
                self.assertEqual(classify(rows)['verdict'], 'invalid_evidence')

    def test_gaps_and_reordered_timestamps_do_not_pass(self):
        rows = samples()
        del rows[3:10]
        self.assertIn('sampling_gap_exceeds_one_second', classify(rows)['reasons'])
        rows = samples()
        rows[5], rows[6] = rows[6], rows[5]
        self.assertIn('timestamps_not_strictly_increasing', classify(rows)['reasons'])

    def test_real_b32_short_window_is_inadequate(self):
        import json
        p = ROOT / 'research/upstream_integration_2026-10-06/evidence/B32/T08/B-home-button-true.jsonl'
        rows = [json.loads(line) for line in p.read_text().splitlines()]
        r = probe.classify(rows, 'B-home-button-true', 4, 2, 30)
        self.assertEqual(r['samples'], 5)
        self.assertFalse(r['error_observed'])
        self.assertFalse(r['target_seen'])
        self.assertEqual(r['verdict'], 'invalid_evidence')
        self.assertEqual(r['reasons'], ['observation_window_too_short'])


if __name__ == '__main__':
    unittest.main()
