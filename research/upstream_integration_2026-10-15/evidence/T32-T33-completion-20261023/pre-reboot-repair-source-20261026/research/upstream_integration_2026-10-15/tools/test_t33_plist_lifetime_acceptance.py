"""Exercise new scope, inherited private inputs and one-shot preflight failure."""
from contextlib import ExitStack
import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import execute_t33_plist_lifetime_acceptance as current
import prepare_t33_plist_lifetime_acceptance as preparation
import launch_t33_plist_lifetime_acceptance as launcher
import test_t33_dev_overlay_acceptance as old_tests


class PlistLifetimeContinuationTests(unittest.TestCase):
    def setUp(self):
        self.originals = {name: getattr(current.runner, name) for name in
                          ('WORK', 'BACKUP', 'VERSION', 'ARCHIVE_SHA', 'CLI')}
        self.addCleanup(lambda: [setattr(current.runner, name, value) for name, value in self.originals.items()])
        current.configure()

    def plan(self):
        value = old_tests.DevOverlayContinuationTests().plan()
        value.update(regularCFWRepeated=False,
            priorFailedPlanSHA256='821b1d69278b77cb650a7a4b11cccc8bfb5b373928dcae8515e1307b0d8d15bc')
        value['targets'][0]['priorFailedTransactions'] = ['20261025T021021Z-hnTJT23g', '20261025T043518Z-1urmPFY7', '20261025T100633Z-Bvlz2q7C', '20261025T114952Z-zhZ5OOCf']
        host = dict(sha256='c'*64, bytes=2, dev=1, ino=2, mtime_ns=3, mode=0o644, uid=501, gid=20)
        value['protectedHostInputs'] = {'.ssh_forward': dict(current=host,
            backup=str(current.WORK / 'host-input-backup/.ssh_forward'), backupState=dict(host, ino=4),
            ownershipPolicy=current.HOST_ARCHIVE_POLICY)}
        return value

    def test_only_new_candidate_and_existing_unpublished_generation(self):
        current.validate(self.plan())
        for key, value in [('retirement', {}), ('regularCFWRepeated', True), ('priorFailedPlanSHA256', 'a'*64)]:
            plan = self.plan(); plan[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): current.validate(plan)
        for key, value in [('version', '2.6.2-local.e12747163c76'), ('archiveSHA256', 'b'*64)]:
            plan = self.plan(); plan['candidate'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): current.validate(plan)
        plan = self.plan(); plan['targets'][0]['priorFailedTransactions'].pop()
        with self.assertRaises(ValueError): current.validate(plan)

    def test_capacity_and_commands_remain_strict(self):
        for key, value in [('minimumInitialFreeBytes', 74*1024**3), ('minimumEachCFWFreeBytes', 49*1024**3),
                           ('VMStarts', 1), ('securityWindows', 1), ('automaticRetry', True),
                           ('automaticRollback', True), ('additionalDeletionAllowed', True)]:
            plan = self.plan(); plan[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): current.validate(plan)
        for key in ('installCommand', 'undoCommand', 'bindingCommand'):
            plan = self.plan(); plan['targets'][0][key] = ['boot']
            with self.subTest(key=key), self.assertRaises(ValueError): current.validate(plan)

    def test_private_input_identity_is_required_without_claiming_new_readback(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'private'; path.write_bytes(b'original desired plan')
            expected = current.runner.snapshot(path)
            self.assertEqual(preparation.inherited_private(path, expected), expected)
            path.write_bytes(b'modified desired plan')
            with self.assertRaises(ValueError): preparation.inherited_private(path, expected)

    def test_first_preflight_failure_consumes_invocation_and_cannot_replay(self):
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
            work = Path(temporary)
            stack.enter_context(patch.object(current, 'WORK', work))
            stack.enter_context(patch.object(current.os, 'geteuid', return_value=0))
            for name in ('approved', 'verify_execution_inputs'):
                stack.enter_context(patch.object(current.runner.base, name))
            stack.enter_context(patch.object(current, 'verify_host_inputs'))
            execute = stack.enter_context(patch.object(current.runner, 'execute', side_effect=ValueError('preflight failed')))
            for attempt, error in ((1, ValueError), (2, FileExistsError)):
                with self.subTest(attempt=attempt), self.assertRaises(error): current.execute(self.plan(), 'a'*64)
            self.assertEqual(execute.call_count, 1)
            self.assertEqual(json.loads((work/'preflight-stopped.json').read_text())['automaticRetry'], False)
            self.assertFalse((work/'execution').exists())

    def test_approval_refusal_precedes_claim_or_worker(self):
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
            work = Path(temporary)
            stack.enter_context(patch.object(current, 'WORK', work))
            stack.enter_context(patch.object(current.os, 'geteuid', return_value=0))
            stack.enter_context(patch.object(current.runner.base, 'approved', side_effect=ValueError('approval missing')))
            worker = stack.enter_context(patch.object(current.runner, 'execute'))
            with self.assertRaisesRegex(ValueError, 'approval missing'): current.execute(self.plan(), 'a'*64)
            worker.assert_not_called(); self.assertEqual(list(work.iterdir()), [])

    def test_launcher_starts_exactly_one_detached_worker(self):
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
            work = Path(temporary); plan = self.plan()
            stack.enter_context(patch.object(current, 'WORK', work))
            stack.enter_context(patch.object(launcher.os, 'geteuid', return_value=0))
            stack.enter_context(patch.object(current, 'validate', return_value=plan))
            stack.enter_context(patch.object(current.runner.base.evidence, 'read', return_value=json.dumps(plan).encode()))
            stack.enter_context(patch.object(current.runner.base.evidence, 'digest', return_value='a'*64))
            for name in ('approved', 'verify_inputs', 'verify_execution_inputs'):
                stack.enter_context(patch.object(current.runner.base, name))
            process = stack.enter_context(patch.object(launcher.subprocess, 'Popen'))
            process.return_value.pid = 123
            launcher.start()
            with self.assertRaisesRegex(ValueError, 'no replay'): launcher.start()
            self.assertEqual(process.call_count, 1)
            self.assertTrue(process.call_args.kwargs['start_new_session'])
            self.assertEqual(process.call_args.args[0][-1], 'a'*64)

    def test_launcher_approval_failure_cannot_start_worker(self):
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
            work = Path(temporary); plan = self.plan()
            stack.enter_context(patch.object(current, 'WORK', work))
            stack.enter_context(patch.object(launcher.os, 'geteuid', return_value=0))
            stack.enter_context(patch.object(current, 'validate', return_value=plan))
            stack.enter_context(patch.object(current.runner.base.evidence, 'read', return_value=json.dumps(plan).encode()))
            stack.enter_context(patch.object(current.runner.base.evidence, 'digest', return_value='a'*64))
            stack.enter_context(patch.object(current.runner.base, 'approved', side_effect=ValueError('approval missing')))
            process = stack.enter_context(patch.object(launcher.subprocess, 'Popen'))
            with self.assertRaisesRegex(ValueError, 'approval missing'): launcher.start()
            process.assert_not_called(); self.assertEqual(list(work.iterdir()), [])


    def test_host_backup_scope_and_metadata_are_required(self):
        for key, value in [('backup','/outside'),('current',{}),('backupState',{})]:
            plan=self.plan(); plan['protectedHostInputs']['.ssh_forward'][key]=value
            with self.subTest(key=key), self.assertRaises(ValueError):current.validate(plan)
        plan=self.plan(); plan['protectedHostInputs']['.ssh_forward']['backupState']['sha256']='a'*64
        with self.assertRaises(ValueError):current.validate(plan)

    def test_actual_host_marker_backup_is_immutable(self):
        import shutil
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
            root=Path(temporary);vm=root/'vm';vm.mkdir();backup=root/'flag-backup'
            source=vm/'.ssh_forward';source.write_bytes(b'1\n');shutil.copy2(source,backup)
            plan=dict(protectedHostInputs={'.ssh_forward':dict(current=current.runner.snapshot(source),
                backup=str(backup),backupState=current.runner.snapshot(backup))})
            stack.enter_context(patch.object(current.runner,'VM',vm))
            current.verify_host_inputs(plan)
            source.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError,'before execution'):current.verify_host_inputs(plan)
            current.verify_host_inputs(plan,current_inputs=False)
            backup.write_bytes(b'corrupt')
            with self.assertRaisesRegex(ValueError,'backup changed'):current.verify_host_inputs(plan,current_inputs=False)

    def test_archive_carrier_owner_is_separate_from_original_metadata(self):
        plan=self.plan()
        record=plan['protectedHostInputs']['.ssh_forward']
        record['current']['gid']=0; record['backupState']['gid']=20
        current.validate(plan)
        self.assertEqual(record['current']['gid'],0)
        record['ownershipPolicy']='discard source ownership'
        with self.assertRaises(ValueError):current.validate(plan)

    def test_diagnostic_model_is_complete_and_explicitly_not_disk_acceptance(self):
        root = current.runner.BASE
        chronology = json.loads((root / 'transport-chronology-analysis-20261025.json').read_bytes())
        chains = json.loads((root / 'recorded-effect-chains-20261025.json').read_bytes())
        preparation.diagnostic_evidence(chronology, chains)
        for key, value in [('historicalRows', 33481), ('changedRows', []),
                ('modeledChronologyChecksPassed', False), ('originalJournalPreserved', False),
                ('observedBeforeAfterStatesUnchanged', False), ('accepted', True),
                ('finalDiskReadPerformed', True), ('verifierSHA256', 'a'*64)]:
            changed = copy.deepcopy(chronology); changed[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                preparation.diagnostic_evidence(changed, chains)
        for key, value in [('checkedChains',118), ('failedChains',1), ('failures',['failed']),
                ('originalJournalPreserved',False), ('accepted',True), ('guestMetadataReadbackPerformed',True)]:
            changed = copy.deepcopy(chains); changed[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                preparation.diagnostic_evidence(chronology, changed)


if __name__ == '__main__':
    unittest.main()
