"""Guard unpublished reuse, complete backups, capacity and failure-stop behavior."""
from contextlib import ExitStack, nullcontext
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

import execute_t33_dev_overlay_acceptance as runner
import prepare_t33_dev_overlay_acceptance as preparation


class DevOverlayContinuationTests(unittest.TestCase):
    def plan(self):
        names = {'Disk.img', 'config.plist'}
        files = {name: {'sha256': 'c'*64} for name in names | {'launchpad.json', '.firmware-desired-plan.json'}}
        target = dict(vm=str(runner.VM), mode='reuse-unpublished-exp-generation', variant='exp',
            generationID=runner.GENERATION, targets=list(runner.previous.TARGETS),
            declarations=['system-systemversion-cfw-build_version'], beforeWriteBackup=str(runner.BACKUP),
            currentBootFiles=files, expectedBinding={'bundle': 'old'}, scratchTrees={},
            historyRecords={}, priorFailedTransactions=['failed'])
        target.update(runner.commands('c'*64))
        return dict(targets=[target], sourceBootFiles=dict.fromkeys(names),
            candidate=dict(version=runner.VERSION, archiveSHA256=runner.ARCHIVE_SHA,
                           targetRulesSHA256=runner.previous.RULES, bundle='bundle', archive='archive', cliSHA256='b'*64),
            minimumInitialFreeBytes=75*1024**3, minimumEachCFWFreeBytes=50*1024**3,
            reuseLockedPythonRuntime=True, VMStarts=0, normalGUIBoots=0, securityWindows=0,
            automaticRetry=False, automaticRollback=False, additionalDeletionAllowed=False,
            runtimeProbeCommand=['probe'], pythonRuntime={})

    def test_scope_accepts_only_exact_unpublished_target_and_commands(self):
        runner.validate(self.plan())
        changes = [dict(vm='other'), dict(variant='regular'), dict(generationID='0'*64),
                   dict(mode='reuse-existing-generation'), dict(targets=[]),
                   dict(scratchTrees={'other': {}}), dict(priorFailedTransactions=[]),
                   dict(installCommand=['boot']), dict(undoCommand=['retry']), dict(bindingCommand=['rebind'])]
        for change in changes:
            with self.subTest(change=change):
                plan = self.plan(); plan['targets'][0].update(change)
                with self.assertRaises(ValueError): runner.validate(plan)

    def test_gates_cannot_be_lowered_or_extended(self):
        for key, value in [('minimumInitialFreeBytes', 74*1024**3), ('minimumEachCFWFreeBytes', 49*1024**3),
                           ('VMStarts', 1), ('securityWindows', 1), ('normalGUIBoots', 1),
                           ('automaticRetry', True), ('automaticRollback', True), ('additionalDeletionAllowed', True)]:
            with self.subTest(key=key):
                plan = self.plan(); plan[key] = value
                with self.assertRaises(ValueError): runner.validate(plan)

    def test_capacity_and_approval_precede_all_writes(self):
        for gate in ('approved', 'require_capacity'):
            with self.subTest(gate=gate), ExitStack() as stack:
                stack.enter_context(patch.object(runner.base, 'approved'))
                stack.enter_context(patch.object(runner.base, 'require_capacity'))
                stack.enter_context(patch.object(runner.base, gate, side_effect=ValueError(gate)))
                backup = stack.enter_context(patch.object(runner, 'preserve_before_write'))
                run = stack.enter_context(patch.object(runner.base, 'run'))
                with self.assertRaisesRegex(ValueError, gate): runner.preflight(self.plan(), 'a'*64)
                backup.assert_not_called(); run.assert_not_called()

    def test_readonly_missing_failed_or_inconsistent_evidence_is_refused(self):
        valid = dict(passed=True, diskIdentityPreserved=True, fullDiskMatchesOriginalSource=True,
            readonlyPlanVerificationPassed=True, generationID=runner.GENERATION,
            deletionPerformed=False, VMStarts=0, securityWindows=0, CFWWrites=0)
        preparation.inspection_record(valid)
        for key in valid:
            with self.subTest(key=key):
                value = dict(valid); value.pop(key)
                with self.assertRaises(ValueError): preparation.inspection_record(value)
        with self.assertRaises(ValueError): preparation.inspection_record(dict(valid, error='inconsistent'))

    def test_actual_backup_retains_complete_bytes_metadata_and_cache(self):
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
            root = Path(temporary); vm = root/'vm'; vm.mkdir(); backup = root/'backup'
            for name in ('Disk.img', 'launchpad.json'):
                (vm/name).write_bytes(b'complete-original-'+name.encode()); (vm/name).chmod(0o640)
            scratch = vm/'cfw_input'; scratch.mkdir(); (scratch/'payload').write_bytes(b'polluted-cache-retained')
            expected = {name: runner.snapshot(vm/name) for name in ('Disk.img', 'launchpad.json')}
            target = dict(scratchTrees={'cfw_input': runner.base.effects.state(scratch)}, historyRecords={})
            stack.enter_context(patch.object(runner, 'VM', vm)); stack.enter_context(patch.object(runner, 'BACKUP', backup))
            stack.enter_context(patch.object(runner.base.audit, 'locked_vm', side_effect=lambda _:nullcontext()))
            stack.enter_context(patch.object(runner, 'existing_locked', return_value=expected))
            stack.enter_context(patch.object(runner.base, 'clone_file', side_effect=shutil.copy2))
            record = runner.preserve_before_write(target)
            self.assertFalse(scratch.exists())
            self.assertEqual((backup/'scratch/cfw_input/payload').read_bytes(), b'polluted-cache-retained')
            for name in expected:
                self.assertEqual(runner.snapshot(vm/name), expected[name])
                self.assertNotEqual((backup/'boot'/name).stat().st_ino, (vm/name).stat().st_ino)
            runner.verify_preservation(target, record)
            (backup/'boot/Disk.img').write_bytes(b'corrupt')
            with self.assertRaisesRegex(ValueError, 'Preserved boot'): runner.verify_preservation(target, record)

    def test_backup_refuses_existing_destination_and_linked_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); file = root/'file'; file.write_bytes(b'x')
            link = root/'link'; link.symlink_to(file)
            with self.assertRaises(OSError): runner.snapshot(link)
            os.link(file, root/'hardlink')
            with self.assertRaises(ValueError): runner.snapshot(file)

    def test_reuse_checks_actual_files_history_and_unpublished_state(self):
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
            vm = Path(temporary)
            (vm/'Disk.img').write_bytes(b'complete-disk')
            (vm/'launchpad.json').write_text('{"bundle":"old"}')
            (vm/'.firmware-desired-plan.json').write_text(json.dumps(dict(generationID=runner.GENERATION, plan={'variant':'exp'})))
            archive = vm/'.cfw-history/failed'; archive.mkdir(parents=True)
            (archive/'transaction.json').write_text('{"id":"failed","status":"failed"}')
            target = dict(currentBootFiles={name:runner.snapshot(vm/name) for name in
                ('Disk.img','launchpad.json','.firmware-desired-plan.json')}, expectedBinding={'bundle':'old'},
                priorFailedTransactions=['failed'], scratchTrees={})
            stack.enter_context(patch.object(runner,'VM',vm))
            stack.enter_context(patch.object(runner.base.txn,'require_unheld'))
            committed = stack.enter_context(patch.object(runner.base.txn,'committed_guest_evidence',return_value=None))
            target['historyRecords']=runner.history(target)
            self.assertEqual(runner.existing_locked(target),target['currentBootFiles'])
            committed.return_value=('published',)
            with self.assertRaisesRegex(ValueError,'committed guest'): runner.existing_locked(target)
            committed.return_value=None
            (vm/'cfw_input').mkdir()
            with self.assertRaisesRegex(ValueError,'Rebuildable input'): runner.existing_locked(target)
            target['scratchTrees']['cfw_input']=runner.base.effects.state(vm/'cfw_input')
            (archive/'transaction.json').write_text('{"id":"failed","status":"published"}')
            with self.assertRaisesRegex(ValueError,'pending or published'): runner.existing_locked(target)
            (archive/'transaction.json').write_text('{"id":"failed","status":"failed"}')
            # Restoring equal bytes changes identity/mtime and must still be refused.
            with self.assertRaisesRegex(ValueError,'records changed'): runner.existing_locked(target)
            (vm/'Disk.img').write_bytes(b'changed-disk')
            with self.assertRaisesRegex(ValueError,'input changed'): runner.existing_locked(target)

    def test_phase_failure_stops_without_following_phases(self):
        for failure in ('on', 'off', 'reapplied'):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
                target = self.plan()['targets'][0]; calls=[]
                stack.enter_context(patch.object(runner.base.evidence, 'read', return_value=b'{"bundle":"2.6.2-local.e12747163c76"}'))
                for name in ('approved','verify_inputs','verify_execution_inputs','require_capacity','verify_restored'):
                    stack.enter_context(patch.object(runner.base, name))
                stack.enter_context(patch.object(runner.base, 'inspect_phase', return_value=({'targets':{}}, {})))
                def run(argv, log, *_, **__):
                    calls.append(log.stem)
                    if log.stem == failure: raise ValueError('phase failure')
                stack.enter_context(patch.object(runner.base, 'run', side_effect=run))
                with self.assertRaisesRegex(ValueError, 'phase failure'):
                    runner.run_target(dict(sourceBootFiles={'config.plist':{}}), target, Path(temporary)/'exp', {}, 'a'*64)
                self.assertEqual(calls, ['bind', 'verify-plan'] + ['on','off','reapplied'][:['on','off','reapplied'].index(failure)+1])

    def test_failure_result_is_saved_with_no_retry_or_rollback(self):
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
            work = Path(temporary); plan = self.plan()
            stack.enter_context(patch.object(runner, 'WORK', work))
            stack.enter_context(patch.object(runner.os, 'geteuid', return_value=0))
            for owner, name in ((runner,'preflight'), (runner,'verify_preservation'), (runner.previous,'unrelated'),
                                (runner.base,'verify_inputs'), (runner.base,'verify_execution_inputs')):
                stack.enter_context(patch.object(owner,name))
            stack.enter_context(patch.object(runner, 'preserve_before_write', return_value={'verified':True}))
            stack.enter_context(patch.object(runner.base, 'runtime_environment', return_value={}))
            stack.enter_context(patch.object(runner.base, 'baseline', return_value={'fullReadbackPassed':True}))
            stack.enter_context(patch.object(runner.base, 'require_capacity'))
            stack.enter_context(patch.object(runner.base, 'target_attachments', return_value=[]))
            stack.enter_context(patch.object(runner.base.evidence, 'digest', return_value='b'*64))
            calls=[]
            def run(argv, log, *_):
                calls.append(log.name)
                if log.name=='runtime-probe.log': log.write_text('{"ok":true}')
            stack.enter_context(patch.object(runner.base, 'run', side_effect=run))
            producer=stack.enter_context(patch.object(runner,'run_target',side_effect=ValueError('phase failure')))
            self.assertEqual(runner.execute(plan,'a'*64),1)
            result=json.loads((work/'execution/result.json').read_bytes())
            self.assertEqual(result['state'],'failed'); self.assertEqual(result['error'],'phase failure')
            self.assertEqual(producer.call_count,1); self.assertEqual(len(calls),3)
            self.assertFalse(result['deletionPerformed']); self.assertEqual(result['VMStarts'],0)


if __name__ == '__main__':
    unittest.main()
