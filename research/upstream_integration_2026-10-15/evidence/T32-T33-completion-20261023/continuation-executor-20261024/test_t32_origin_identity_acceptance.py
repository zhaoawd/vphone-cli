"""Continuation regression checks without Store changes or mounted disks."""
import contextlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import execute_t32_origin_identity_acceptance as runner


class ContinuationAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve(); self.work = self.root / 'work'; self.work.mkdir()
        self.regular = dict(vm=str(self.root / 'regular'), generationID='retained-generation',
            variant='regular', beforeWriteBackup=str(self.root / 'backup'),
            expectedBinding=dict(bundle='old', guestEnvironment='old'),
            targets=['system:/file'], installCommand=['cli', 'on'], undoCommand=['cli', 'off'])
        self.exp = dict(vm=str(self.root / 'exp'), firstBindingBackup=str(self.root / 'exp-backup'), variant='exp')
        self.plan = dict(targets=[self.regular, self.exp], frozenInputs={},
            sourceBootFiles={'config.plist':dict(uid=os.getuid(), gid=os.getgid())},
            candidate=dict(version='new', bundle=str(self.root / 'VPhone.bundle'), cliSHA256='digest'),
            pythonRuntime=dict(root=str(self.root / 'runtime'), venv=str(self.root / 'runtime/venv'), environment={}),
            installCommand=['install'], verifyCommand=['verify'], regularBindingCommand=['bind'])

    @contextlib.contextmanager
    def execution_fixture(self):
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(runner, 'WORK', self.work))
            stack.enter_context(patch.object(runner.os, 'geteuid', return_value=0))
            for name in ('approved', 'verify_execution_inputs', 'verify_inputs'):
                stack.enter_context(patch.object(runner.base, name))
            stack.enter_context(patch.object(runner, 'preflight', return_value=dict(currentRegularFiles={})))
            stack.enter_context(patch.object(runner.base, 'runtime_environment', return_value={}))
            stack.enter_context(patch.object(runner.base, 'baseline', return_value=dict(fullReadbackPassed=True)))
            stack.enter_context(patch.object(runner.base, 'target_attachments', return_value=[]))
            stack.enter_context(patch.object(runner, 'verify_backup'))
            stack.enter_context(patch.object(runner.base.evidence, 'digest', return_value='digest'))
            yield stack

    def test_snapshot_refuses_symlinks_and_shared_files(self):
        source = self.root / 'file'; source.write_bytes(b'preserve')
        self.assertEqual(runner.file_snapshot(source)['bytes'], 8)
        link = self.root / 'link'; link.symlink_to(source)
        with self.assertRaises(OSError): runner.file_snapshot(link)
        os.link(source, self.root / 'hardlink')
        with self.assertRaisesRegex(ValueError, 'linked'): runner.file_snapshot(source)

    def test_missing_approval_prevents_preflight_and_execution_output(self):
        with patch.object(runner, 'WORK', self.work), patch.object(runner.os, 'geteuid', return_value=0), \
             patch.object(runner.base, 'approved', side_effect=ValueError('approval missing')), \
             patch.object(runner, 'preflight') as check, patch.object(runner.base, 'run') as child:
            with self.assertRaisesRegex(ValueError, 'approval'): runner.execute(self.plan)
            check.assert_not_called(); child.assert_not_called()
        self.assertFalse((self.work / 'execution').exists())

    def test_backup_failure_prevents_store_install_binding_and_target_work(self):
        with self.execution_fixture(), \
             patch.object(runner, 'backup_regular', side_effect=ValueError('backup differs')), \
             patch.object(runner, 'probe_runtime') as probe, patch.object(runner.base, 'run') as child, \
             patch.object(runner, 'run_regular') as regular, patch.object(runner.base, 'run_target') as exp:
            self.assertEqual(runner.execute(self.plan), 1)
            probe.assert_not_called(); child.assert_not_called(); regular.assert_not_called(); exp.assert_not_called()
        result = json.loads((self.work / 'execution/result.json').read_text())
        self.assertEqual(result['error'], 'backup differs'); self.assertEqual(result['targets'], [])

    def test_existing_runtime_probe_failure_never_installs_or_provisions(self):
        with self.execution_fixture(), patch.object(runner, 'backup_regular', return_value={}), \
             patch.object(runner, 'probe_runtime', side_effect=ValueError('locked runtime rejected')), \
             patch.object(runner.base, 'run') as child, patch.object(runner, 'run_regular') as regular:
            self.assertEqual(runner.execute(self.plan), 1)
            child.assert_not_called(); regular.assert_not_called()

    def test_regular_failure_preserves_record_and_never_creates_exp(self):
        retained = self.root / 'retained'; retained.write_bytes(b'keep')
        with self.execution_fixture(), patch.object(runner, 'backup_regular', return_value={}), \
             patch.object(runner, 'probe_runtime'), patch.object(runner.base, 'run'), \
             patch.object(runner, 'run_regular', side_effect=ValueError('original bytes differ')) as regular, \
             patch.object(runner.base, 'run_target') as exp:
            self.assertEqual(runner.execute(self.plan), 1)
            self.assertEqual(regular.call_count, 1); exp.assert_not_called()
        self.assertEqual(retained.read_bytes(), b'keep')
        result = json.loads((self.work / 'execution/result.json').read_text())
        self.assertEqual(result['state'], 'failed'); self.assertEqual(result['VMStarts'], 0)
        self.assertEqual(result['securityWindows'], 0); self.assertFalse(Path(self.exp['vm']).exists())

    def test_existing_outputs_refuse_before_backup_or_store_write(self):
        backup = Path(self.regular['beforeWriteBackup']); backup.mkdir()
        with patch.object(runner.base, 'require_capacity'), patch.object(runner.base, 'verify_inputs'), \
             patch.object(runner.base, 'store_cli', return_value=self.root / 'Store/version/VPhone.bundle/Contents/MacOS/cli'), \
             patch.object(runner.base, 'baseline') as baseline:
            with self.assertRaisesRegex(ValueError, 'existing continuation output'): runner.preflight(self.plan)
            baseline.assert_not_called()

    def test_regular_phases_keep_generation_and_require_exact_bytes(self):
        vm = Path(self.regular['vm']); vm.mkdir()
        (vm / 'launchpad.json').write_text(json.dumps(dict(bundle='new', guestEnvironment='old')))
        original = dict(sha256='a', mode=0o755, uid=0, gid=0)
        signed = dict(original, sha256='b'); states = [signed, original, signed]
        observations = [dict(targets={'system:/file': state}, transactionID=str(i)) for i, state in enumerate(states)]
        calls = [(row, {'system:/file':dict(state=original)} if i == 0 else None)
                 for i, row in enumerate(observations)]
        with patch.object(runner.base, 'run') as child, patch.object(runner.base, 'approved'), \
             patch.object(runner.base, 'verify_execution_inputs'), patch.object(runner.base, 'verify_inputs'), \
             patch.object(runner.base, 'require_capacity'), patch.object(runner.base, 'inspect_phase', side_effect=calls) as inspect, \
             patch.object(runner.base, 'verify_restored') as restored:
            result = runner.run_regular(self.plan, self.regular, self.work / 'regular', {})
            self.assertTrue(result['transition']['passed']); self.assertEqual(child.call_count, 4)
            self.assertEqual([call.args[2] for call in inspect.call_args_list], ['retained-generation'] * 3)
            restored.assert_called_once()

    def test_binding_refuses_unrelated_origin_change_before_cfw(self):
        vm = Path(self.regular['vm']); vm.mkdir()
        (vm / 'launchpad.json').write_text(json.dumps(dict(bundle='new', guestEnvironment='changed')))
        with patch.object(runner.base, 'run') as child:
            with self.assertRaisesRegex(ValueError, 'unrelated component origins'):
                runner.run_regular(self.plan, self.regular, self.work / 'regular', {})
            self.assertEqual(child.call_count, 1)


if __name__ == '__main__':
    unittest.main()
