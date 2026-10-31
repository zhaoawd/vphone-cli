"""Regression coverage for exact backup reuse and the complete registered preview gate."""
import copy
from contextlib import ExitStack, nullcontext
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import cfw_source_identity as identity
import execute_t33_source_acceptance as current
import finalize_t33_source_acceptance as finalizer


class ScopeTests(unittest.TestCase):
    def setUp(self):
        candidate = dict(version='fixture', targetRulesSHA256=current.retained.previous.RULES)
        marker = dict(sha256='a'*64, bytes=0, dev=1, ino=2, mtime_ns=3, mode=0o644, uid=0, gid=20)
        boot = {'Disk.img': dict(sha256=current.previous.CURRENT_SHA),
            'config.plist': {}, 'launchpad.json': dict(sha256='b'*64),
            '.firmware-desired-plan.json': dict(sha256=current.previous.DESIRED_SHA)}
        host = {name: {} for name in ('launchpad.json', '.vphone-runtime.json', '.cfw-reboot-identity.json')}
        host['.ssh_forward'] = marker
        self.preflight = dict(passed=True, completeFourImageReadbacksPassed=True,
            completeParentPublicationPassed=True, productionCompleteUndoPreviewPassed=True,
            rebuiltIndexByteIdentical=True, preservedUndoSourceVerified=True, sourceMembers=[{}, {}],
            emptyFailedWork={}, currentBootFiles=boot, currentHostFiles=host, volumeUUID='volume', candidateModulesSHA256={})
        self.plan = dict(candidate=candidate, priorFailedPlanSHA256=current.PRIOR_SHA,
            primaryRegistrationSHA256=current.PRIMARY_SHA, retainedBackup=str(current.previous.BACKUP),
            emptyWorkDestination=str(current.EMPTY_DESTINATION), recovery=current.previous.expected_recovery(),
            minimumInitialFreeBytes=75 << 30, minimumEachCFWFreeBytes=50 << 30,
            sourceBootFiles={'Disk.img': {}, 'config.plist': {}}, reuseLockedPythonRuntime=True,
            VMStarts=0, normalGUIBoots=0, securityWindows=0, repeatedFirstOn=0, repeatedUndoWrites=0,
            repeatedPrimaryRegistration=0, repeatedW7Move=0, automaticRetry=False, automaticRollback=False,
            additionalDeletionAllowed=False, regularCFWRepeated=False,
            packagedPreflightDirectory='/fixture', sourceMembers=[{}, {}], emptyWork={}, smallBackupFiles=host,
            volumeUUID='volume', installedModuleSHA256={}, firstOnReportSHA256='c'*64,
            boundBeforeRecovery=dict(bundle='fixture', guestEnvironment='2.6.2-local.f43043c4c559'),
            protectedHostInputs={'.ssh_forward': dict(current=marker, backupState=dict(marker, uid=501, ino=4),
                backup=str(current.WORK / 'host-input-backup/.ssh_forward'),
                ownershipPolicy='original uid/gid are recorded separately from the user-owned archive carrier')},
            targets=[dict(vm=str(current.VM), generationID=current.GENERATION, variant='exp',
                mode='resume-after-source-observation-refusal', targets=current.retained.previous.TARGETS,
                declarations=['system-systemversion-cfw-build_version'], currentBootFiles=boot,
                failedHistoryRecords={name: {} for name in current.previous.FAILED},
                expectedBinding=dict(bundle='2.6.2-local.73b536cbb70c', guestEnvironment='2.6.2-local.f43043c4c559'))])
        self.plan.update(current.previous.commands(candidate, 'b'*64))
        self.stack = ExitStack(); self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(current, 'read', side_effect=lambda p: candidate if p == current.CANDIDATE else self.preflight))
        self.stack.enter_context(patch.object(current.base.evidence, 'digest', return_value='c'*64))

    def test_exact_scope_reuses_old_backups_and_registered_disk_aliases(self):
        self.assertIs(current.validate(self.plan), self.plan)

    def test_repeated_work_expanded_scope_and_changed_backups_are_refused(self):
        for key, value in [('repeatedPrimaryRegistration', 1), ('repeatedW7Move', 1), ('repeatedFirstOn', 1),
                ('repeatedUndoWrites', 1), ('VMStarts', 1), ('securityWindows', 1), ('automaticRetry', True),
                ('additionalDeletionAllowed', True), ('minimumInitialFreeBytes', 74 << 30),
                ('minimumEachCFWFreeBytes', 49 << 30), ('retainedBackup', '/other'),
                ('primaryRegistrationSHA256', 'a'*64), ('reuseLockedPythonRuntime', False)]:
            row = copy.deepcopy(self.plan); row[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): current.validate(row)

    def test_packaged_complete_preview_and_exact_members_are_required(self):
        for name in ('productionCompleteUndoPreviewPassed', 'preservedUndoSourceVerified', 'rebuiltIndexByteIdentical'):
            self.preflight[name] = False
            with self.subTest(name=name), self.assertRaises(ValueError): current.validate(self.plan)
            self.preflight[name] = True
        for name in ('sourceMembers', 'smallBackupFiles', 'installedModuleSHA256', 'emptyWork', 'volumeUUID'):
            row = copy.deepcopy(self.plan); row[name] = 'changed'
            with self.subTest(name=name), self.assertRaises(ValueError): current.validate(row)

    def test_first_on_binding_and_original_ssh_ownership_cannot_be_reassigned(self):
        for mutate in (lambda p: p['boundBeforeRecovery'].update(guestEnvironment='fixture'),
                lambda p: p['protectedHostInputs']['.ssh_forward']['backupState'].update(sha256='d'*64),
                lambda p: p['protectedHostInputs']['.ssh_forward']['current'].pop('uid'),
                lambda p: p.update(firstOnReportSHA256='d'*64)):
            row = copy.deepcopy(self.plan); mutate(row)
            with self.assertRaises(ValueError): current.validate(row)


class PreservationTests(unittest.TestCase):
    def test_only_exact_empty_work_can_be_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            vm = Path(temporary).resolve(); empty = vm / '.cfw_disk.failed'; empty.mkdir()
            row = dict(emptyWork=dict(metadata=identity.metadata(empty.lstat())))
            with patch.object(current, 'VM', vm), patch.object(current.previous, 'NEW_WORK', empty):
                with current.locked_empty(row): pass
                (empty / 'unexpected').write_bytes(b'preserve')
                with self.assertRaises(ValueError):
                    with current.locked_empty(row): self.fail('nonempty prior work must not be reused')
                self.assertEqual((empty / 'unexpected').read_bytes(), b'preserve')

    def registered_preview_case(self, fail):
        from patchers import guest_recovery, guest_undo
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
            root = Path(temporary); vm = root / 'vm'; vm.mkdir(); backup = root / 'backup'
            empty = vm / '.cfw_disk.failed'; empty.mkdir(); destination = vm / 'retained'; events = []
            target = dict(currentBootFiles={}, expectedBinding={})
            plan = dict(targets=[target], smallBackupFiles={}, volumeUUID='volume', sourceMembers=[])
            target['declarations'] = ['system-systemversion-cfw-build_version']; plan['recovery'] = {}
            for module, name, value in [(current,'VM',vm),(current,'BACKUP',backup),
                    (current,'EMPTY_DESTINATION',destination),(current.previous,'NEW_WORK',empty)]:
                stack.enter_context(patch.object(module,name,value))
            stack.enter_context(patch.object(current,'locked_empty',return_value=nullcontext()))
            stack.enter_context(patch.object(current,'read',return_value={}))
            stack.enter_context(patch.object(current.previous,'verify_host_inputs'))
            stack.enter_context(patch.object(current.base.txn,'require_unheld'))
            stack.enter_context(patch.object(current.base.evidence,'digest',return_value=current.PRIMARY_SHA))
            stack.enter_context(patch('cfw_reboot_identity.load_registered'))
            stack.enter_context(patch('cfw_reboot_identity._volume_uuid',return_value='volume'))
            primary = stack.enter_context(patch('cfw_reboot_identity.register_requalification'))
            verify_old = stack.enter_context(patch.object(current,'verify_old_backup'))
            stack.enter_context(patch.object(current.base.txn,'committed_guest_evidence',return_value=(root,dict(id=current.FIRST))))
            stack.enter_context(patch.object(guest_undo,'saved_plan'))
            stack.enter_context(patch.object(identity,'register_sources',side_effect=lambda *a: events.append('source-registration') or 'a'*64))
            def preview_action(*args, **kwargs):
                events.append('real-preview')
                if fail: raise ValueError('complete production preview refused')
                return {}
            preview = stack.enter_context(patch.object(guest_undo,'preview',side_effect=preview_action))
            verify_source = stack.enter_context(patch.object(guest_recovery,'verify_source',side_effect=lambda *a: events.append('source-verify')))
            stack.enter_context(patch.object(current.base,'save'))
            if fail:
                with self.assertRaisesRegex(ValueError, 'complete production preview refused'):
                    current.preserve_and_register(plan,'a'*64)
                self.assertTrue(empty.is_dir()); self.assertFalse(destination.exists())
                self.assertEqual(events,['source-registration','real-preview'])
                verify_source.assert_not_called()
            else:
                current.preserve_and_register(plan,'a'*64)
                self.assertEqual(events,['source-registration','real-preview','source-verify'])
                self.assertFalse(empty.exists()); self.assertEqual(list(destination.iterdir()),[])
                verify_source.assert_called_once()
            primary.assert_not_called(); verify_old.assert_called_once(); preview.assert_called_once()

    def test_real_registered_preview_precedes_empty_move_and_no_primary_reregistration(self):
        self.registered_preview_case(False)

    def test_failed_complete_preview_preserves_empty_work_and_stops_before_clone(self):
        self.registered_preview_case(True)

    def test_small_backups_are_fully_verified_and_content_change_is_refused(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary)/'source'; source.write_bytes(b'full backup')
            expected = current.retained.snapshot(source)
            with patch.object(current,'BACKUP',source.parent):
                current.verify_small(dict(smallBackupFiles={'source':expected}))
                source.write_bytes(b'changed')
                with self.assertRaises(ValueError): current.verify_small(dict(smallBackupFiles={'source':expected}))


class ResultTests(unittest.TestCase):
    def test_success_requires_actual_registered_source_and_reused_backups(self):
        native = dict(state='offline-qualified-on-off-on-passed', VMStarts=0,securityWindows=0,
            repeatedFirstOn=0,repeatedUndoWrites=0,repeatedPrimaryRegistration=0,repeatedW7Move=0,
            deletionPerformed=False,automaticRetry=False,automaticRollback=False,targetAttachments=[],
            baseline=dict(files=10,fullReadbackPassed=True),smallBackupFiles=4,
            preservation=dict(fullReadbackPassed=True,bootFiles=12,protectedHostInputs=1,cacheTrees=2,failedHistories=4),
            preservedEmptyWork=str(current.EMPTY_DESTINATION),sourceRegistrationSHA256='a'*64,
            phaseTransactions=dict(on=current.FIRST,off=current.RECOVERY_ID,reapplied='new'))
        finalizer.validate_native(native)
        for key,value in [('sourceRegistrationSHA256',''),('smallBackupFiles',0),('preservation',{}),
                ('repeatedPrimaryRegistration',1),('repeatedW7Move',1),('error','failure')]:
            row=copy.deepcopy(native);row[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):finalizer.validate_native(row)


if __name__ == '__main__':
    unittest.main()
