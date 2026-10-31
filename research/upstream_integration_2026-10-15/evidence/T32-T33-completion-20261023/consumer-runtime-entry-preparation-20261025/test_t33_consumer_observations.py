"""Compose the real evidence validators with isolated runtime reply fixtures."""
import base64
import copy
from pathlib import Path
import tempfile
import unittest

import test_t32_t33_runtime_evidence as fixtures
from t33_consumer_observations import collect


class ConsumerObservationTests(unittest.TestCase):
    def run_observations(self, *, legacy_failure=False, file_failure=False, bad_page=False):
        fixture = fixtures.RuntimeEvidenceTests(); fixture.setUp()
        calls = []
        def rpc(method, params):
            calls.append(method)
            if method == 'files.read':
                if file_failure:
                    raise RuntimeError('EPERM')
                data = b'complete fixture'
                return dict(path=params['path'], binary=True, encoding='base64', truncated=False,
                    size=len(data), content=base64.b64encode(data).decode())
            if method == 'apps.foreground':
                return copy.deepcopy(fixture.front)
            if method == 'ui.describe':
                reply = copy.deepcopy(fixture.description)
                if bad_page:
                    reply['elements']['elements'][0]['value'] = '26.0 (23A341)'
                return reply
            return {}
        def legacy(call, rpc, output, result):
            result['observations'] = dict(display=dict(state='failed' if legacy_failure else 'passed'))
            return not legacy_failure
        with tempfile.TemporaryDirectory() as temporary:
            result = dict(runtimeValidated=False)
            passed = collect(None, rpc, Path(temporary), result,
                expected_build='23Z999999', base_collect=legacy)
            image_exists = (Path(temporary) / 'settings-about.jpg').exists()
            return passed, result, calls, image_exists

    def test_combined_replies_require_visual_review_and_only_retain_file_digest(self):
        passed, result, _, image = self.run_observations()
        self.assertTrue(passed); self.assertTrue(image)
        self.assertTrue(result['settingsBuildEvidence']['visualReviewRequired'])
        self.assertFalse(result['runtimeValidated'])
        self.assertNotIn('content', result['completeGigalockerAfterUnlockAttempt'])

    def test_legacy_failure_cannot_be_covered_by_page_success(self):
        passed, result, _, image = self.run_observations(legacy_failure=True)
        self.assertFalse(passed); self.assertTrue(image)
        self.assertEqual(result['observations']['display']['state'], 'failed')

    def test_file_failure_does_not_skip_independent_page_or_cleanup(self):
        passed, result, calls, image = self.run_observations(file_failure=True)
        self.assertFalse(passed); self.assertTrue(image)
        self.assertEqual(result['observations']['completeGigalockerAfterUnlockAttempt']['state'], 'failed')
        self.assertEqual(calls[-1], 'apps.terminate')

    def test_wrong_build_cannot_save_a_passing_page(self):
        passed, result, calls, image = self.run_observations(bad_page=True)
        self.assertFalse(passed); self.assertFalse(image)
        self.assertEqual(result['observations']['settingsBuild']['state'], 'failed')
        self.assertEqual(calls[-1], 'apps.terminate')


if __name__ == '__main__':
    unittest.main()
