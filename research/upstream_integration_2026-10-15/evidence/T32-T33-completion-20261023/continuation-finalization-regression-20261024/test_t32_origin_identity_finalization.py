"""Read-only finalization rejects process reuse, incomplete proof and drift."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import finalize_t32_origin_identity_acceptance as finalizer


class ContinuationFinalizationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve(); self.work = self.root / 'work'; self.work.mkdir()
        self.identity = dict(rootPID=123, rootStart='Sat Oct 24 12:32:05 2026')

    def test_reused_pid_or_failed_process_query_refuses(self):
        for code, stdout, stderr in [(0, 'another start', ''), (1, '', 'permission denied'), (2, '', '')]:
            with patch.object(finalizer.subprocess, 'run', return_value=subprocess.CompletedProcess([], code, stdout, stderr)):
                with self.assertRaisesRegex(ValueError, 'identity'): finalizer.root_running(self.identity)
        with patch.object(finalizer.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', '')):
            self.assertFalse(finalizer.root_running(self.identity))

    def test_native_exit_without_result_does_not_retry_or_finalize(self):
        with patch.object(finalizer, 'WORK', self.work), patch.object(finalizer, 'root_running', return_value=False):
            with self.assertRaisesRegex(ValueError, 'without a saved result'):
                finalizer.wait_for_native(self.identity, 1)
        self.assertFalse((self.work / 'execution').exists())

    def test_waits_for_native_exit_before_reading_result(self):
        native = dict(state='failed', error='preserve')
        def write_result(_):
            path = self.work / 'execution'; path.mkdir()
            (path / 'result.json').write_text(json.dumps(native))
        with patch.object(finalizer, 'WORK', self.work), \
             patch.object(finalizer, 'root_running', side_effect=[True, False]), \
             patch.object(finalizer.time, 'sleep', side_effect=write_result) as wait:
            self.assertEqual(finalizer.wait_for_native(self.identity, 1), native)
            wait.assert_called_once()

    def test_success_cannot_omit_an_independent_phase(self):
        with patch.object(finalizer, 'WORK', self.work):
            with self.assertRaisesRegex(ValueError, 'three complete phase reports'):
                finalizer.check_phase_reports(dict(targets=[dict(variant='regular')]),
                    dict(state='offline-qualified-on-off-on-passed'))

    def test_changed_reapplied_bytes_are_rejected_even_if_transition_claims_pass(self):
        folder = self.work / 'execution/regular'; folder.mkdir(parents=True)
        for phase in ('on', 'off', 'reapplied'):
            row = dict(transactionID=phase, generationID='retained',
                independentAudit=dict(passed=True, transactionID=phase, generationID='retained'),
                sourceReceipt={}, binding={}, targets={'system:/file':dict(sha256=phase)})
            (folder / (phase + '.json')).write_text(json.dumps(row))
        (folder / 'transition.json').write_text(json.dumps(dict(passed=True, runtimeValidated=False)))
        with patch.object(finalizer, 'WORK', self.work), patch.object(finalizer.runner.base, 'verify_origin'):
            with self.assertRaisesRegex(ValueError, 'reapplication differ'):
                finalizer.check_phase_reports(dict(targets=[dict(variant='regular', targets=['system:/file'],
                    generationID='retained')]), dict(state='offline-qualified-on-off-on-passed'))

    def test_other_disk_identity_change_refuses_archive(self):
        disk = self.root / 'Disk.img'; disk.write_bytes(b'original')
        (self.work / 'unrelated-disk-identities-before.json').write_text(json.dumps({
            'Disk.img':dict(dev=disk.stat().st_dev, ino=disk.stat().st_ino, size=999)}))
        native = dict(VMStarts=0, securityWindows=0, originalVMWritten=False,
                      baseline=dict(files=10, fullReadbackPassed=True), targetAttachments=[])
        with patch.object(finalizer, 'ROOT', self.root), patch.object(finalizer, 'WORK', self.work), \
             patch.object(finalizer.runner.base, 'approved'), patch.object(finalizer.runner.base, 'verify_inputs'), \
             patch.object(finalizer.runner.base, 'verify_execution_inputs'), patch.object(finalizer.runner.base, 'baseline'):
            with self.assertRaisesRegex(ValueError, 'Unrelated disk identity changed'):
                finalizer.preservation({}, native)
        self.assertEqual(disk.read_bytes(), b'original')


if __name__ == '__main__':
    unittest.main()
