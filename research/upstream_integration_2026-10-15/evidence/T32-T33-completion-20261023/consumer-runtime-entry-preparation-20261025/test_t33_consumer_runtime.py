"""Check approval and explicit build gates before a runtime observer can run."""
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import observe_t33_consumer_runtime as entry


class ConsumerRuntimeTests(unittest.TestCase):
    def test_missing_approval_does_not_invoke_observer_main(self):
        module = SimpleNamespace(approved_plan=Mock(side_effect=ValueError('approval')), main=Mock())
        with tempfile.TemporaryDirectory() as temporary, patch.object(entry.budgeted, 'load_observer', return_value=module):
            with self.assertRaisesRegex(ValueError, 'approval'):
                entry.main(['--work-directory', str(Path(temporary).resolve()), '--execute-approved-runtime-plan', 'a' * 64])
        module.main.assert_not_called()

    def test_missing_expected_build_does_not_configure_requests(self):
        for expected in (None, '', 'not-a-build', True):
            with self.subTest(expected=expected):
                module = SimpleNamespace(approved_plan=lambda _: dict(expectedBuildVersion=expected))
                with self.assertRaisesRegex(ValueError, 'expected build'):
                    entry.configure_observer(module, Path('/tmp'), 'a' * 64)
                self.assertFalse(hasattr(module, 'collect_observations'))

    def test_configured_collector_receives_only_the_approved_build(self):
        old = Mock()
        module = SimpleNamespace(approved_plan=Mock(return_value=dict(expectedBuildVersion='23Z999999')),
                                 collect_observations=old)
        with patch.object(entry, 'collect', return_value=False) as collector:
            entry.configure_observer(module, Path('/tmp'), 'a' * 64)
            self.assertFalse(module.collect_observations('call', 'rpc', 'out', 'result'))
        collector.assert_called_once_with('call', 'rpc', 'out', 'result', expected_build='23Z999999', base_collect=old)
        module.approved_plan.assert_called_once_with('a' * 64)


if __name__ == '__main__':
    unittest.main()
