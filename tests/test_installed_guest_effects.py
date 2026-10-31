"""Read installed targets independently of a historical publication image."""
import copy
import contextlib
import json
import os
from pathlib import Path
import plistlib
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from tests import test_guest_undo as fixtures
from patchers import component_effects as effects, installed_effects, plan_gate as gate
import cfw_disk_txn as transaction
import cfw_verify_effects as audit


class InstalledGuestEffectsTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.GuestUndoTests()
        self.fixture.setUp(); self.addCleanup(self.fixture.doCleanups)
        self.fixture.commit(second='dyld-boot-maxslide')
        self.vm = self.fixture.vm
        self.root = self.fixture.fixture.f.mount / 'mnt1'
        self.committed = transaction.committed_guest_evidence(self.vm)
        self.outputs = self.committed[3]['outputs']
        self.roots = dict(system=self.root, dsc=self.root / 'System/Cryptexes/OS/System/Library/Caches/com.apple.dyld')

    def test_actual_targets_match_without_promoting_runtime_or_origin_authority(self):
        before = effects.digest(self.vm / 'Disk.img')
        result = installed_effects.verify_targets(self.outputs, self.roots)
        self.assertTrue(result['passed'])
        self.assertEqual(len(result['targets']), len(self.outputs))
        self.assertFalse(result['runtimeValidated']); self.assertFalse(result['originQualified'])
        self.assertFalse(result['writeAuthorized'])
        self.assertEqual(effects.digest(self.vm / 'Disk.img'), before)

    def test_changed_current_target_fails_while_historical_receipt_remains_valid(self):
        target = self.fixture.fixture.dsc
        data = bytearray(target.read_bytes()); data[512] ^= 1; target.write_bytes(data)
        self.assertEqual(transaction.inspect_guest(self.vm)['state'], 'committed-effects')
        result = installed_effects.verify_targets(self.outputs, self.roots)
        self.assertFalse(result['passed'])
        failed = [row for row in result['targets'] if not row['matches']]
        self.assertTrue(failed)
        self.assertIn('sha256', failed[0]['differentFields'])

    def test_wrong_metadata_missing_member_and_linked_parent_never_pass(self):
        target = self.fixture.fixture.dsc
        target.chmod(0o600)
        result = installed_effects.verify_targets(self.outputs, self.roots)
        self.assertFalse(result['passed'])
        self.assertTrue(any('mode' in r['differentFields'] for r in result['targets']))
        target.rename(target.with_name('retained'))
        self.assertFalse(installed_effects.verify_targets(self.outputs, self.roots)['passed'])
        parent = target.parent; renamed = parent.with_name('retained-directory')
        parent.rename(renamed); parent.symlink_to(renamed, target_is_directory=True)
        self.assertFalse(installed_effects.verify_targets(self.outputs, self.roots)['passed'])

    def test_unknown_volume_traversal_duplicates_and_empty_outputs_refuse(self):
        for outputs in [[], self.outputs + [self.outputs[0]],
                        [dict(self.outputs[0], target='system:/../outside')],
                        [dict(self.outputs[0], target='data:/file')]]:
            with self.subTest(outputs=str(outputs)[:70]), self.assertRaises(ValueError):
                installed_effects.verify_targets(outputs, self.roots)

    def test_undo_eligibility_reports_suffix_dependency_and_keeps_non_dsc_unsupported(self):
        archive = self.committed[0]
        rows = [json.loads(line) for line in (archive/'guest-changes.jsonl').read_bytes().splitlines()]
        index = json.loads((archive/'guest-undo-provenance.json').read_bytes())
        result = installed_effects.undo_eligibility(rows, index)
        by_id = {row['declarationID']: row for row in result}
        self.assertEqual(by_id['dyld-cfw-camera']['state'], 'requires_later_declarations')
        self.assertEqual(by_id['dyld-cfw-camera']['requiredDeclarations'], ['dyld-boot-maxslide', 'dyld-cfw-camera'])
        self.assertEqual(by_id['dyld-boot-maxslide']['state'], 'qualified_dsc_suffix')
        self.assertEqual(by_id['system-cryptex-boot-install']['state'], 'not_revertible')
        self.assertTrue(all(row['writeAuthorized'] is False for row in result))

    def test_one_qualified_effect_does_not_hide_an_unsupported_effect(self):
        archive = self.committed[0]
        rows = [json.loads(line) for line in (archive/'guest-changes.jsonl').read_bytes().splitlines()]
        index = json.loads((archive/'guest-undo-provenance.json').read_bytes())
        row = copy.deepcopy(next(row for row in rows if row['declarationID']=='dyld-boot-maxslide'))
        row['target'] = 'preboot:/launchd'
        rows.append(row)
        result = installed_effects.undo_eligibility(rows, index)
        found = next(row for row in result if row['declarationID']=='dyld-boot-maxslide')
        self.assertEqual(found['state'], 'not_revertible')
        self.assertTrue(found['unsupportedTargets'])

    @contextlib.contextmanager
    def mounted_roots(self, image, wanted, parent):
        self.assertEqual(image, self.vm/'Disk.img')
        self.assertEqual(wanted, {'system'})
        yield self.roots, lambda: None

    def test_locked_audit_reauthenticates_source_and_reports_actual_code_pages(self):
        with patch.object(audit, 'readonly_roots', side_effect=self.mounted_roots):
            result = audit.audit_locked(self.vm, self.vm.parent)
        self.assertTrue(result['passed']); self.assertEqual(result['codePages'][0]['verifiedCodePages'], 1)
        self.assertTrue(result['authenticatedDSCSourceAssociation'])
        self.assertFalse(result['originQualified']); self.assertFalse(result['runtimeValidated'])

    def test_locked_audit_does_not_hide_modified_installed_bytes(self):
        data = bytearray(self.fixture.fixture.dsc.read_bytes()); data[512] ^= 1
        self.fixture.fixture.dsc.write_bytes(data)
        with patch.object(audit, 'readonly_roots', side_effect=self.mounted_roots):
            result = audit.audit_locked(self.vm, self.vm.parent)
        self.assertFalse(result['passed']); self.assertEqual(result['state'], 'installed-effect-mismatch')
        self.assertFalse(result['codePages'][0]['passed'])

    def test_changed_publication_after_mount_and_source_mutation_refuse(self):
        calls = [self.committed, None]
        with patch.object(audit, 'readonly_roots', side_effect=self.mounted_roots), \
                patch.object(transaction, 'committed_guest_evidence', side_effect=calls), \
                self.assertRaisesRegex(ValueError, 'publication changed'):
            audit.audit_locked(self.vm, self.vm.parent)
        source = self.fixture.fixture.original
        source.write_bytes(b'changed original')
        with patch.object(audit, 'readonly_roots', side_effect=self.mounted_roots), self.assertRaises(ValueError):
            audit.audit_locked(self.vm, self.vm.parent)

    def mount_fixture(self, *, readonly=True, existing=False, fail_unmount=False):
        self.commands = []
        image = self.vm/'Disk.img'
        def run(argv):
            self.commands.append(argv)
            if argv[1:3] == ['info', '-plist']:
                return plistlib.dumps(dict(images=[{'image-path':str(image)}] if existing else []))
            if argv[1]=='attach':
                return plistlib.dumps({'system-entities':[{'dev-entry':'/dev/disk41','content-hint':'GUID_partition_scheme'}]})
            if argv[0]=='/sbin/umount' and fail_unmount: raise OSError('mount busy')
            return b''
        patches = contextlib.ExitStack()
        patches.enter_context(patch.object(audit, 'run_tool', side_effect=run))
        patches.enter_context(patch.object(audit.final_guest, 'attachments', return_value=dict(
            ContainerReference='disk42', PhysicalStores=[{'DeviceIdentifier':'disk41s1'}],
            Volumes=[{'DeviceIdentifier':'disk42s1'}])))
        patches.enter_context(patch.object(audit.final_guest, 'volume_info', return_value=dict(DeviceIdentifier='disk42s1',Mounted=False)))
        patches.enter_context(patch.object(audit.final_guest, 'require_mount'))
        patches.enter_context(patch.object(audit.os, 'statvfs', return_value=SimpleNamespace(f_flag=os.ST_RDONLY if readonly else 0)))
        self.addCleanup(patches.close)
        return image

    def test_readonly_mounts_and_cleanup_use_only_the_new_attachment(self):
        image=self.mount_fixture()
        with audit.readonly_roots(image, {'system'}, self.vm.parent) as (roots, recheck):
            self.assertIn('system', roots); recheck()
        self.assertTrue(any('-readonly' in argv for argv in self.commands))
        self.assertTrue(any(argv[:3]==['/sbin/mount_apfs','-o','rdonly,nobrowse'] for argv in self.commands))
        self.assertEqual(self.commands[-1], ['/usr/bin/hdiutil','detach','/dev/disk41'])
        self.assertFalse(list(self.vm.parent.glob('cfw-readonly-*')))

    def test_existing_attachment_is_preserved_without_mounting_or_detaching(self):
        image=self.mount_fixture(existing=True)
        with self.assertRaisesRegex(ValueError, 'already attached'), \
                audit.readonly_roots(image, {'system'}, self.vm.parent): pass
        self.assertEqual(len(self.commands),1)

    def test_writable_filesystem_refuses_and_normal_cleanup_still_runs(self):
        image=self.mount_fixture(readonly=False)
        with self.assertRaisesRegex(ValueError, 'not readonly'), \
                audit.readonly_roots(image, {'system'}, self.vm.parent): pass
        self.assertEqual(self.commands[-1], ['/usr/bin/hdiutil','detach','/dev/disk41'])

    def test_busy_unmount_retains_mount_and_never_force_detaches(self):
        image=self.mount_fixture(fail_unmount=True)
        with self.assertRaisesRegex(OSError,'mount busy'), \
                audit.readonly_roots(image, {'system'}, self.vm.parent): pass
        self.assertFalse(any('detach' in argv for argv in self.commands))
        self.assertTrue(list(self.vm.parent.glob('cfw-readonly-*')))

    def test_mismatch_report_is_saved_without_changing_the_failure_exit(self):
        report = self.vm.parent/'mismatch-report.json'
        expected = dict(schemaVersion=1, state='installed-effect-mismatch', passed=False,
                        targets=[dict(target='hardware:/AA.gl', matches=False)])
        with patch.object(audit, 'locked_vm', return_value=contextlib.nullcontext()), \
                patch.object(audit, 'audit_locked', return_value=expected):
            code = audit.main([str(self.vm), '--work-parent', str(self.vm.parent), '--report', str(report)])
        self.assertEqual(code, 1)
        self.assertEqual(json.loads(report.read_bytes()), expected)
        self.assertEqual(report.stat().st_mode & 0o777, 0o600)

    def test_existing_report_refuses_before_the_vm_is_touched(self):
        report=self.vm.parent/'existing-report.json'; report.write_bytes(b'keep')
        with patch.object(audit, 'audit_locked') as reader:
            code=audit.main([str(self.vm), '--work-parent', str(self.vm.parent), '--report', str(report)])
        self.assertEqual(code,2); reader.assert_not_called()
        self.assertEqual(report.read_bytes(),b'keep')

    def test_refusal_is_preserved_as_a_report_with_no_authority(self):
        report=self.vm.parent/'refusal-report.json'
        with patch.object(audit, 'locked_vm', side_effect=ValueError('pending publication')):
            code=audit.main([str(self.vm), '--work-parent', str(self.vm.parent), '--report', str(report)])
        self.assertEqual(code,2)
        result=json.loads(report.read_bytes())
        self.assertEqual(result['state'],'audit-refused'); self.assertFalse(result['writeAuthorized'])


if __name__ == '__main__': unittest.main()
