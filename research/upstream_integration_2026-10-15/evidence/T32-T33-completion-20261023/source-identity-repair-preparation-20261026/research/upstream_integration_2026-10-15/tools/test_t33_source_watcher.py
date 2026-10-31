"""The observer must never restart or advance an incomplete native worker."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import watch_t33_source_acceptance as observer


class RebootWatcherTests(unittest.TestCase):
    def test_live_worker_cannot_finalize_or_prepare_runtime(self):
        with patch.object(observer.finalizer.previous, 'root_running', return_value=True), \
             patch.object(observer.finalizer, 'finalize') as final, \
             patch.object(observer.consumer, 'prepare') as prepare:
            with self.assertRaises(ValueError): observer.finish_stopped({'pid': 1})
            final.assert_not_called(); prepare.assert_not_called()

    def test_interrupted_worker_with_no_result_is_not_restarted(self):
        with tempfile.TemporaryDirectory() as temporary, \
             patch.object(observer.current, 'WORK', Path(temporary)), \
             patch.object(observer.finalizer.previous, 'root_running', return_value=False), \
             patch.object(observer.finalizer, 'finalize') as final, \
             patch.object(observer.consumer, 'prepare') as prepare:
            result = observer.finish_stopped({'pid': 1})
            self.assertEqual(result['state'], 'interrupted-without-result')
            self.assertFalse(result['automaticRetry'])
            final.assert_not_called(); prepare.assert_not_called()
            self.assertEqual(list(Path(temporary).iterdir()), [])

    def test_failed_offline_result_cannot_prepare_a_runtime_plan(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary); (work / 'execution').mkdir(); (work / 'execution/result.json').write_text('{}')
            with patch.object(observer.current, 'WORK', work), \
                 patch.object(observer.finalizer.previous, 'root_running', return_value=False), \
                 patch.object(observer.finalizer, 'finalize', return_value=dict(offlineAcceptancePassed=False)), \
                 patch.object(observer.consumer, 'prepare') as prepare:
                result = observer.finish_stopped({'pid': 1})
                self.assertEqual(result['state'], 'offline-finalized'); prepare.assert_not_called()

    def test_only_successful_finalization_prepares_an_unapproved_plan(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary); (work / 'execution').mkdir(); (work / 'execution/result.json').write_text('{}')
            with patch.object(observer.current, 'WORK', work), \
                 patch.object(observer.finalizer.previous, 'root_running', return_value=False), \
                 patch.object(observer.finalizer, 'finalize', return_value=dict(offlineAcceptancePassed=True)), \
                 patch.object(observer.consumer, 'prepare', return_value=dict(state='runtime-plan-prepared-not-approved')) as prepare:
                result = observer.finish_stopped({'pid': 1})
                self.assertEqual(result['state'], 'runtime-plan-prepared-not-approved')
                self.assertEqual(result['VMStarts'], 0); self.assertEqual(result['securityWindows'], 0)
                prepare.assert_called_once_with()


if __name__ == '__main__':
    unittest.main()
