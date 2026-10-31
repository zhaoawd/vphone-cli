"""Recovery scope, publication evidence, and source-preservation regressions."""
import copy
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import execute_t33_reboot_acceptance as current
import finalize_t33_reboot_acceptance as finalizer
import run_t33_recovered_undo as worker


class RecoveryScopeTests(unittest.TestCase):
    def setUp(self):
        self.candidate = dict(version='2.6.2-local.fixture', archiveSHA256='a'*64, cliSHA256='b'*64,
                              targetRulesSHA256=current.retained.previous.RULES)
        self.rows = [dict(paths=[str(i)], recorded=dict(dev=1, ino=i+1, size=2, mtime_ns=3),
            current=dict(dev=4, ino=i+1, size=2, mtime_ns=3), sha256='a'*64) for i in range(4)]
        self.plan = dict(candidate=self.candidate, priorInterruptedPlanSHA256=current.OLD_PLAN_SHA,
            sourceBootFiles={'Disk.img': {}, 'config.plist': {}}, recovery=current.expected_recovery(),
            minimumInitialFreeBytes=75 << 30, minimumEachCFWFreeBytes=50 << 30,
            VMStarts=0, normalGUIBoots=0, securityWindows=0, repeatedFirstOn=0, repeatedUndoWrites=0,
            automaticRetry=False, automaticRollback=False, additionalDeletionAllowed=False, regularCFWRepeated=False,
            reuseLockedPythonRuntime=True, readonlyReplayDirectory='/fixture/replay',
            firstOnReportSHA256='c'*64, protectedHostInputs={'.ssh_forward': {}},
            boundBeforeRecovery=dict(bundle=self.candidate['version'], guestEnvironment='2.6.2-local.f43043c4c559'))
        boot = {'Disk.img': {'sha256': current.CURRENT_SHA}, 'config.plist': {},
            'launchpad.json': {'sha256': 'd'*64}, '.firmware-desired-plan.json': {'sha256': current.DESIRED_SHA}}
        self.plan['targets'] = [dict(vm=str(current.VM), mode='recover-observed-undo-and-reapply', variant='exp',
            generationID=current.GENERATION, targets=current.retained.previous.TARGETS,
            declarations=['system-systemversion-cfw-build_version'], currentBootFiles=boot,
            expectedBinding=dict(bundle='2.6.2-local.f43043c4c559', guestEnvironment='2.6.2-local.f43043c4c559'),
            failedHistoryRecords={name: {} for name in current.FAILED})]
        marker = dict(sha256=hashlib.sha256(b'').hexdigest(), bytes=0, dev=4, ino=1,
                      mtime_ns=3, mode=0o644, uid=0, gid=20)
        self.plan['protectedHostInputs']['.ssh_forward'] = dict(current=marker,
            backupState=dict(marker, ino=2, uid=501), backup=str(current.WORK / 'host-input-backup/.ssh_forward'),
            ownershipPolicy='original uid/gid are recorded separately from the user-owned archive carrier')
        self.plan.update(current.commands(self.candidate, 'd'*64))
        aliases = [['Disk.img', str(current.NEW_WORK.relative_to(current.VM) / 'Disk.img'),
            str(current.NEW_WORK.relative_to(current.VM) / 'Disk.img.previous'),
            '.cfw-history/' + current.RECOVERY_ID + '/Disk.img', '.cfw-history/' + current.RECOVERY_ID + '/Disk.img.previous'],
            ['.cfw-history/' + current.FIRST + '/Disk.img'],
            ['.cfw-history/' + current.FIRST + '/guest-postimage.img'],
            [str(current.PENDING.relative_to(current.VM) / 'Disk.img'), str(current.PRESERVED.relative_to(current.VM) / 'Disk.img')]]
        self.plan['requalificationMembers'] = [dict(row, paths=names) for row, names in zip(self.rows, aliases)]
        self.stack = ExitStack(); self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(current, 'read', side_effect=lambda p:
            self.candidate if p == current.CANDIDATE else {'members': self.rows}))
        self.stack.enter_context(patch.object(current.base.evidence, 'digest', return_value='c'*64))

    def test_exact_recovery_scope_is_accepted(self):
        self.assertIs(current.validate(self.plan), self.plan)

    def test_runtime_retry_repeated_work_or_capacity_expansion_is_refused(self):
        for key, value in [('VMStarts', 1), ('securityWindows', 1), ('repeatedFirstOn', 1),
            ('repeatedUndoWrites', 1), ('automaticRetry', True), ('automaticRollback', True),
            ('additionalDeletionAllowed', True), ('regularCFWRepeated', True),
            ('minimumInitialFreeBytes', 74 << 30), ('minimumEachCFWFreeBytes', 49 << 30)]:
            plan = copy.deepcopy(self.plan); plan[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): current.validate(plan)

    def test_unlisted_file_alias_or_modified_recovery_record_is_refused(self):
        for mutate in (lambda p: p['requalificationMembers'][0]['paths'].append('elsewhere.img'),
            lambda p: p['requalificationMembers'][0]['recorded'].update(ino=999),
            lambda p: p['recovery'].update(recordSHA256='e'*64),
            lambda p: p['recovery'].update(transactionID='different'),
            lambda p: p['recovery'].update(repeatedUndoWrites=1)):
            plan = copy.deepcopy(self.plan); mutate(plan)
            with self.assertRaises(ValueError): current.validate(plan)

    def test_first_on_guest_origin_and_reapply_command_cannot_be_reassigned(self):
        for mutate in (lambda p: p['boundBeforeRecovery'].update(guestEnvironment=p['candidate']['version']),
            lambda p: p['targets'][0]['expectedBinding'].pop('guestEnvironment'),
            lambda p: p['installCommand'].append('--root-popup'),
            lambda p: p.update(firstOnReportSHA256='e'*64)):
            plan = copy.deepcopy(self.plan); mutate(plan)
            with self.assertRaises(ValueError): current.validate(plan)

    def test_marker_archive_keeps_bytes_and_original_ownership_record(self):
        for mutate in (lambda p: p['protectedHostInputs']['.ssh_forward']['backupState'].update(sha256='e'*64),
            lambda p: p['protectedHostInputs']['.ssh_forward'].update(backup='/other/marker'),
            lambda p: p['protectedHostInputs']['.ssh_forward'].update(ownershipPolicy='same owner assumed'),
            lambda p: p['protectedHostInputs']['.ssh_forward']['current'].pop('uid')):
            plan = copy.deepcopy(self.plan); mutate(plan)
            with self.assertRaises(ValueError): current.validate(plan)


class PreservationTests(unittest.TestCase):
    def test_named_pending_lock_refuses_a_second_unfinished_transaction(self):
        with tempfile.TemporaryDirectory() as temporary:
            vm = Path(temporary).resolve(); pending = vm / '.cfw_disk.old'; pending.mkdir()
            with patch.object(current, 'VM', vm), patch.object(current, 'PENDING', pending):
                with current.locked_pending(): pass
                (vm / '.cfw_disk.other').mkdir()
                with self.assertRaises(ValueError):
                    with current.locked_pending(): self.fail('must refuse before yield')

    def test_moving_source_preserves_all_bytes_and_inodes(self):
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
            vm = Path(temporary).resolve(); pending = vm / '.cfw_disk.old'; pending.mkdir()
            source = vm / '.cfw-recovery-sources/source'; out = vm / 'output'; (out / 'execution').mkdir(parents=True)
            for name, data in [('Disk.img', b'complete restored disk'), ('guest-postimage.img', b'partial seal postimage'),
                ('transaction.json', b'{"status":"staged"}'), ('guest-effects-final.json', b'preserved final effects')]:
                (pending / name).write_bytes(data)
            digest = current.base.evidence.digest(pending / 'transaction.json')
            before = current.source_inventory(pending)
            plan = dict(targets=[dict(currentBootFiles={})], protectedHostInputs={}, requalificationMembers=[], volumeUUID='unused')
            for key, value in dict(VM=vm, PENDING=pending, PRESERVED=source, WORK=out, RECORD_SHA=digest).items():
                stack.enter_context(patch.object(current, key, value))
            registration = stack.enter_context(patch('cfw_reboot_identity.register_requalification', return_value='f'*64))
            current.register_and_preserve_source(plan, 'a'*64)
            self.assertFalse(pending.exists())
            self.assertEqual(current.source_inventory(source), before)
            registration.assert_called_once_with(vm, current.GENERATION, 'a'*64, [])
            self.assertEqual(json.loads((source / 'transaction.json').read_bytes())['status'], 'staged')

    def test_worker_rejects_wrong_plan_before_module_load_or_transaction_write(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); path = root / 'offline-plan.json'; path.write_text('{}')
            with patch('sys.argv', ['worker', '--plan', str(path), '--sha256', 'a'*64]):
                with self.assertRaisesRegex(ValueError, 'plan changed'): worker.main()
            self.assertEqual(list(root.iterdir()), [path])


class EvidenceTests(unittest.TestCase):
    def native(self):
        return dict(state='offline-qualified-on-off-on-passed', VMStarts=0, securityWindows=0,
            repeatedFirstOn=0, repeatedUndoWrites=0, deletionPerformed=False, automaticRetry=False,
            automaticRollback=False, targetAttachments=[], baseline=dict(files=10, fullReadbackPassed=True),
            preservation=dict(fullReadbackPassed=True), phaseTransactions=dict(on=current.FIRST,
                off=current.RECOVERY_ID, reapplied='new-reapplication'))

    def test_success_requires_three_distinct_phases_and_preservation(self):
        finalizer.validate_native(self.native())
        for key, value in [('error', 'failed'), ('targetAttachments', ['disk']), ('preservationError', 'changed'),
            ('repeatedUndoWrites', 1), ('preservation', {}), ('baseline', {})]:
            native = self.native(); native[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): finalizer.validate_native(native)
        native = self.native(); native['phaseTransactions']['reapplied'] = current.FIRST
        with self.assertRaises(ValueError): finalizer.validate_native(native)

    def test_historical_first_on_producer_cannot_be_relabelled(self):
        report = current.read(current.OLD_WORK / 'execution/exp/on.json')
        current.verify_first_on({}, report)
        for key in ('binding', 'sourceReceipt'):
            changed = copy.deepcopy(report)
            if key == 'binding': changed['binding']['guestEnvironment'] = 'new-candidate'
            else: changed['sourceReceipt']['componentReceipts']['qualifiedProducer']['version'] = 'new-candidate'
            with self.subTest(key=key), self.assertRaises(ValueError): current.verify_first_on({}, changed)


if __name__ == '__main__':
    unittest.main()
