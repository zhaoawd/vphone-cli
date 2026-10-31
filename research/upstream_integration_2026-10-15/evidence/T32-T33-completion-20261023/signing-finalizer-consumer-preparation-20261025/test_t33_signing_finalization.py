"""Reject incomplete native results and unsafe finalization without a VM."""
import copy
import unittest
from unittest.mock import patch

import finalize_t33_signing_acceptance as finalizer


class SigningFinalizationTests(unittest.TestCase):
    def good(self):
        return dict(state='failed', VMStarts=0, securityWindows=0, originalVMWritten=False,
                    baseline=dict(files=10, fullReadbackPassed=True), targetAttachments=[])

    def test_failed_native_may_be_archived_without_becoming_success(self):
        finalizer.validate_native(self.good())

    def test_missing_scope_or_preservation_is_rejected(self):
        changes = [('VMStarts', 1), ('securityWindows', 1), ('originalVMWritten', True),
                   ('baseline', dict(files=9, fullReadbackPassed=True)),
                   ('targetAttachments', ['disk']), ('state', 'running'),
                   ('preservationOrCleanupError', 'failure')]
        for key, value in changes:
            with self.subTest(key=key):
                result = copy.deepcopy(self.good()); result[key] = value
                with self.assertRaises(ValueError):
                    finalizer.validate_native(result)

    def test_preservation_does_not_accept_a_remaining_attachment(self):
        with patch.object(finalizer.runner.base, 'approved'), \
             patch.object(finalizer.runner.base, 'verify_inputs'), \
             patch.object(finalizer.runner.base, 'verify_execution_inputs'), \
             patch.object(finalizer.runner, 'unrelated'), \
             patch.object(finalizer.runner.base, 'target_attachments', return_value=['disk']), \
             patch.object(finalizer.runner.base, 'baseline') as baseline:
            with self.assertRaisesRegex(ValueError, 'still attached'):
                finalizer.preserve({})
            baseline.assert_not_called()


if __name__ == '__main__':
    unittest.main()
