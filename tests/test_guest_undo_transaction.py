"""Actual Undo writer, receipts and journal; APFS attachments use temp trees."""
import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from tests import test_guest_undo as fixtures
from patchers import component_effects as effects, final_guest, guest_undo, plan_gate as gate
import cfw_disk_txn as txn


class GuestUndoTransactionTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.GuestUndoTests()
        self.fixture.setUp(); self.addCleanup(self.fixture.doCleanups)
        record = txn.load_record(self.fixture.work)
        record.update(version=4, runtimeImageEvidenceRequired=True)
        txn.save_record(self.fixture.work, record)
        self.fixture.commit(second='dyld-boot-maxslide')
        self.vm = self.fixture.vm
        self.current_root = self.fixture.fixture.f.mount / 'mnt1'
        self.binding = {'bundle':'1.0.0', 'guestEnvironment':'1.0.0', 'kernel':'1.0.0', 'bootChain':'1.0.0'}
        (self.vm/'launchpad.json').write_bytes(gate.canonical(self.binding))
        os.chmod(self.vm/'launchpad.json', 0o640)
        self.sequence = 0

    def prepare(self, declarations=('dyld-boot-maxslide',)):
        self.sequence += 1
        work = self.vm/f'.cfw_disk.undo{self.sequence}'; work.mkdir(mode=0o700)
        mount = self.vm/f'.cfw_mount.undo{self.sequence}'; mount.mkdir()
        shutil.copytree(self.current_root, mount/'mnt1')
        fd = os.open(self.vm/'Disk.img', os.O_RDONLY); self.addCleanup(os.close, fd)
        self.args = SimpleNamespace(vm=self.vm, work=work, fd=fd, owner_pid=os.getpid(), guest_evidence=True,
            generation=self.fixture.generation, declaration=list(declarations), exit_code=0, retain_staged=False)
        self.mount = mount
        os.environ.update(VPHONE_GUEST_EVIDENCE=str(work/'guest-changes.jsonl'), CFW_HOST_MNT=str(mount))
        with contextlib.redirect_stdout(io.StringIO()): txn.stage(self.args)
        guest_undo.prepare(self.args)
        self.target = mount/'mnt1/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e'
        return self.args

    def query(self, readonly):
        def query(args):
            if args[0] == '/usr/bin/hdiutil':
                return plistlib.dumps({'images':[{'image-path':str(self.args.work/'Disk.img'),
                    'system-entities':[{'dev-entry':'/dev/disk41','content-hint':'GUID_partition_scheme'}]}]})
            root = str(self.mount/'mnt1')
            if args[1:3] == ['apfs','list']:
                return plistlib.dumps({'Containers':[{'ContainerReference':'disk42',
                    'PhysicalStores':[{'DeviceIdentifier':'disk41s1'}],
                    'Volumes':[{'DeviceIdentifier':'disk42s1','MountPoint':root}]}]})
            return plistlib.dumps({'ReadOnlyVolume':readonly,'DeviceIdentifier':'disk42s1','MountPoint':root})
        return query

    def apply(self):
        with patch.object(final_guest.subprocess,'check_output',side_effect=self.query(False)):
            guest_undo.apply(self.args)
        # Model the filesystem flush into the disposable raw image at unmount.
        (self.args.work/'Disk.img').write_bytes(self.target.read_bytes())

    def seal(self):
        with patch.object(final_guest.subprocess,'check_output',side_effect=self.query(True)), \
             patch.object(sys,'argv',['plan_gate.py','verify-final']):
            gate.main()
        txn.seal(self.args)

    def finish(self):
        with contextlib.redirect_stdout(io.StringIO()): txn.finish(self.args)
        self.current_root = self.mount/'mnt1'

    def test_write_publish_and_second_undo_preserve_retained_effects(self):
        original = effects.digest(self.vm/'Disk.img')
        self.prepare(); self.apply()
        self.assertEqual(self.target.read_bytes(), fixtures.fixtures.cache(b'changed'))
        self.assertEqual(effects.digest(self.vm/'Disk.img'), original)
        self.seal(); txn.publish(self.args)
        binding = json.loads((self.vm/'launchpad.json').read_bytes())
        self.assertNotIn('guestEnvironment',binding)
        self.assertEqual({k:v for k,v in binding.items()}, {k:v for k,v in self.binding.items() if k!='guestEnvironment'})
        self.assertEqual((self.vm/'launchpad.json').stat().st_mode & 0o777, 0o640)
        transaction_id = txn.load_record(self.args.work)['id']
        self.finish()
        archive = self.vm/'.cfw-history'/transaction_id
        receipt = json.loads((archive/guest_undo.RECEIPTS).read_bytes())
        self.assertEqual(receipt['guestOrigin']['state'],'unknown')
        self.assertEqual(receipt['removedDeclarations'],['dyld-boot-maxslide'])
        self.assertIn('dyld-cfw-camera',receipt['appliedDeclarations'])
        self.assertNotIn('dyld-boot-maxslide',receipt['appliedDeclarations'])
        self.assertEqual(receipt['imageSHA256'], effects.digest(self.vm/'Disk.img'))
        self.assertEqual(txn.inspect_guest(self.vm)['componentReceipts'],receipt)
        self.assertEqual(txn.preview_guest_undo(self.vm,self.fixture.generation,['dyld-cfw-camera'])['state'],'undo-preview')
        self.prepare(['dyld-cfw-camera']); self.apply()
        self.assertEqual(self.target.read_bytes(),fixtures.fixtures.cache(b'initial'))
        self.seal(); txn.publish(self.args); self.finish()
        with self.assertRaises(txn.Refused): txn.preview_guest_undo(self.vm,self.fixture.generation,['dyld-cfw-camera'])

    def test_runtime_disk_writes_preserve_historical_parent_and_actual_target_checks(self):
        # Raw-image runtime writes stand for unrelated filesystem bookkeeping;
        # the mounted DSC target remains independently checked by the writer.
        with (self.vm/'Disk.img').open('r+b') as stream:
            stream.seek(0); stream.write(b'R'); stream.flush(); os.fsync(stream.fileno())
        historical = txn.inspect_guest(self.vm)
        self.assertEqual(historical['state'], 'committed-publication')
        self.assertFalse(historical['runtimeValidated'])
        self.prepare(); self.apply(); self.seal(); txn.publish(self.args); self.finish()
        self.assertEqual(self.target.read_bytes(), fixtures.fixtures.cache(b'changed'))
        with (self.vm/'Disk.img').open('r+b') as stream:
            stream.seek(0); stream.write(b'S'); stream.flush(); os.fsync(stream.fileno())
        self.assertEqual(txn.inspect_guest(self.vm)['state'], 'committed-publication')
        self.assertEqual(txn.preview_guest_undo(self.vm, self.fixture.generation, ['dyld-cfw-camera'])['state'], 'undo-preview')

    def test_writable_volume_schema_covers_undo_write_and_readonly_seal(self):
        self.prepare()
        original_query = self.query
        def modern_query(readonly):
            query = original_query(readonly)
            def observe(args):
                info = plistlib.loads(query(args))
                if 'ReadOnlyVolume' in info:
                    info['WritableVolume'] = not info.pop('ReadOnlyVolume')
                return plistlib.dumps(info)
            return observe
        with patch.object(self, 'query', side_effect=modern_query):
            self.apply(); self.seal(); txn.publish(self.args); self.finish()
        self.assertEqual(self.target.read_bytes(), fixtures.fixtures.cache(b'changed'))
        receipt = txn.inspect_guest(self.vm)['componentReceipts']
        self.assertEqual(receipt['removedDeclarations'], ['dyld-boot-maxslide'])
        self.assertEqual(receipt['guestOrigin']['state'], 'unknown')

    def test_writable_allocation_change_preserves_mount_binding_and_publication(self):
        self.prepare()
        original_query = self.query
        def changing_capacity(readonly):
            query = original_query(readonly)
            def observe(args):
                value = plistlib.loads(query(args))
                if args[1:3] == ['apfs', 'list']:
                    value['Containers'][0]['CapacityFree'] = (
                        1024 if (self.args.work/guest_undo.APPLIED).exists() else 2048)
                return plistlib.dumps(value)
            return observe
        with patch.object(self, 'query', side_effect=changing_capacity):
            self.apply(); self.seal(); txn.publish(self.args); self.finish()
        self.assertEqual(self.target.read_bytes(), fixtures.fixtures.cache(b'changed'))
        self.assertEqual(txn.inspect_guest(self.vm)['componentReceipts']['removedDeclarations'],
                         ['dyld-boot-maxslide'])

    def test_writable_volume_uuid_change_after_write_refuses_publication(self):
        self.prepare()
        original = effects.digest(self.vm/'Disk.img')
        original_query = self.query
        def changing_uuid(readonly):
            query = original_query(readonly)
            def observe(args):
                value = plistlib.loads(query(args))
                if args[1:3] == ['apfs', 'list']:
                    value['Containers'][0]['Volumes'][0]['APFSVolumeUUID'] = (
                        'replacement' if (self.args.work/guest_undo.APPLIED).exists() else 'original')
                return plistlib.dumps(value)
            return observe
        with patch.object(self, 'query', side_effect=changing_uuid):
            with self.assertRaisesRegex(ValueError, 'writable mount changed'): self.apply()
        self.assertTrue((self.args.work/guest_undo.APPLIED).exists())
        self.assertFalse((self.args.work/'guest-publication.json').exists())
        self.assertEqual(effects.digest(self.vm/'Disk.img'), original)

    def test_readonly_allocation_change_still_refuses_final_readback(self):
        self.prepare(); self.apply()
        query = self.query(True)
        count = 0
        def observe(args):
            nonlocal count
            value = plistlib.loads(query(args))
            if args[1:3] == ['apfs', 'list']:
                count += 1
                value['Containers'][0]['CapacityFree'] = count
            return plistlib.dumps(value)
        with patch.object(self, 'query', return_value=observe):
            with self.assertRaisesRegex(ValueError, 'attachment or operation evidence changed'):
                self.seal()
        self.assertFalse((self.args.work/'guest-publication.json').exists())

    def test_changed_target_refuses_before_any_write(self):
        self.prepare(); self.target.write_bytes(b'unknown DSC member')
        before = self.target.read_bytes()
        with patch.object(final_guest.subprocess,'check_output',side_effect=self.query(False)):
            with self.assertRaises(ValueError): guest_undo.apply(self.args)
        self.assertEqual(self.target.read_bytes(),before)
        self.assertFalse((self.args.work/guest_undo.APPLIED).exists())
        self.assertEqual(json.loads((self.vm/'launchpad.json').read_bytes()),self.binding)

    def test_target_metadata_change_and_linked_parent_refuse(self):
        self.prepare()
        before = self.target.read_bytes()
        os.chmod(self.target,0o600)
        with patch.object(final_guest.subprocess,'check_output',side_effect=self.query(False)):
            with self.assertRaisesRegex(ValueError,'metadata differs'): guest_undo.apply(self.args)
        os.chmod(self.target,0o644)
        caches = self.target.parent.parent
        saved = self.mount/'held-caches'; caches.rename(saved); caches.symlink_to(saved)
        with patch.object(final_guest.subprocess,'check_output',side_effect=self.query(False)):
            with self.assertRaisesRegex(ValueError,'linked'): guest_undo.apply(self.args)
        self.assertEqual(self.target.read_bytes(),before)

    def test_parent_tampering_after_prepare_refuses_before_write(self):
        self.prepare(); before = self.target.read_bytes()
        (self.fixture.archive/'guest-undo-provenance.json').write_bytes(b'changed parent')
        with patch.object(final_guest.subprocess,'check_output',side_effect=self.query(False)):
            with self.assertRaises(txn.Refused): guest_undo.apply(self.args)
        self.assertEqual(self.target.read_bytes(),before)

    def test_changed_applied_report_or_receipt_cannot_publish(self):
        self.prepare(); self.apply()
        applied = self.args.work/guest_undo.APPLIED; original = applied.read_bytes()
        applied.write_bytes(gate.canonical(dict(schemaVersion=1,transactionID=txn.load_record(self.args.work)['id'],entries=[])))
        with self.assertRaises((txn.Refused,ValueError)): self.seal()
        # seal failed before a checkpoint; a fresh staging run is required.
        self.assertFalse((self.args.work/'guest-publication.json').exists())
        self.assertEqual(json.loads((self.vm/'launchpad.json').read_bytes()),self.binding)

    def test_missing_binding_stays_unknown_and_host_rebind_does_not_erase_undo(self):
        self.prepare(); self.apply(); self.seal(); txn.publish(self.args); self.finish()
        binding = json.loads((self.vm/'launchpad.json').read_bytes()); binding['bundle']='2.0.0'
        (self.vm/'launchpad.json').write_bytes(gate.canonical(binding))
        self.assertEqual(txn.preview_guest_undo(self.vm,self.fixture.generation,['dyld-cfw-camera'])['state'],'undo-preview')

    def test_missing_binding_is_not_created_by_undo(self):
        (self.vm/'launchpad.json').unlink()
        self.prepare(); self.apply(); self.seal(); txn.publish(self.args); self.finish()
        self.assertFalse((self.vm/'launchpad.json').exists())

    def test_receipt_corruption_after_seal_refuses_before_disk_exchange(self):
        self.prepare(); self.apply(); self.seal()
        before = effects.digest(self.vm/'Disk.img')
        (self.args.work/guest_undo.RECEIPTS).write_bytes(b'changed receipt')
        with self.assertRaises(txn.Refused): txn.publish(self.args)
        self.assertEqual(effects.digest(self.vm/'Disk.img'),before)
        self.assertEqual(json.loads((self.vm/'launchpad.json').read_bytes()),self.binding)

    def test_final_readback_failure_keeps_original_and_origins(self):
        original = effects.digest(self.vm/'Disk.img')
        self.prepare(); self.apply()
        self.target.write_bytes(fixtures.fixtures.cache(b'unknown'))
        with self.assertRaises(ValueError): self.seal()
        self.assertEqual(effects.digest(self.vm/'Disk.img'),original)
        self.assertEqual(json.loads((self.vm/'launchpad.json').read_bytes()),self.binding)

    def test_swap_interruption_recovers_origin_and_receipts_from_same_journal(self):
        self.prepare(); self.apply(); self.seal()
        txn.swap_files(self.args.work/'Disk.img', self.vm/'Disk.img')
        self.assertEqual(json.loads((self.vm/'launchpad.json').read_bytes()),self.binding)
        self.args.exit_code = 130
        with contextlib.redirect_stdout(io.StringIO()): txn.recover(self.args)
        self.assertNotIn('guestEnvironment',json.loads((self.vm/'launchpad.json').read_bytes()))
        self.assertEqual(txn.inspect_guest(self.vm)['state'],'committed-effects')

    def test_archive_rename_interruption_leaves_a_readable_committed_receipt(self):
        self.prepare(); self.apply(); self.seal(); txn.publish(self.args)
        actual = os.rename
        work = self.args.work
        def interrupted(source, destination):
            actual(source, destination)
            if Path(source) == work: raise InterruptedError('after archive rename')
        with patch.object(txn.os,'rename',side_effect=interrupted), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(InterruptedError): txn.finish(self.args)
        self.assertEqual(txn.inspect_guest(self.vm)['state'],'committed-effects')

    def test_origin_published_before_status_write_recovers_without_rewriting_other_layers(self):
        self.prepare(); self.apply(); self.seal()
        actual = guest_undo.publish_origin
        def interrupted(work, record):
            actual(work, record)
            raise InterruptedError('after origin publication')
        with patch.object(guest_undo,'publish_origin',side_effect=interrupted):
            with self.assertRaises(InterruptedError): txn.publish(self.args)
        with contextlib.redirect_stdout(io.StringIO()): txn.recover(self.args)
        value = json.loads((self.vm/'launchpad.json').read_bytes())
        self.assertNotIn('guestEnvironment',value)
        self.assertEqual(value['kernel'],self.binding['kernel'])
        self.assertEqual(txn.inspect_guest(self.vm)['state'],'committed-effects')

    def test_exclusive_rename_first_step_recovers_old_disk_and_preserves_origin(self):
        self.prepare(); self.apply(); self.seal()
        old = effects.digest(self.vm/'Disk.img')
        txn.move_exclusive(self.vm/'Disk.img',self.args.work/txn.PREVIOUS)
        with contextlib.redirect_stdout(io.StringIO()): txn.recover(self.args)
        self.assertEqual(effects.digest(self.vm/'Disk.img'),old)
        self.assertEqual(json.loads((self.vm/'launchpad.json').read_bytes()),self.binding)

    def test_exclusive_rename_second_step_recovers_new_disk_and_unknown_origin(self):
        self.prepare(); self.apply(); self.seal()
        txn.move_exclusive(self.vm/'Disk.img',self.args.work/txn.PREVIOUS)
        txn.move_exclusive(self.args.work/'Disk.img',self.vm/'Disk.img')
        with contextlib.redirect_stdout(io.StringIO()): txn.recover(self.args)
        self.assertNotIn('guestEnvironment',json.loads((self.vm/'launchpad.json').read_bytes()))
        self.assertEqual(txn.inspect_guest(self.vm)['state'],'committed-effects')

    def test_recovery_refuses_attached_images_without_removing_the_staged_copy(self):
        self.prepare(); self.apply(); self.seal()
        report = plistlib.dumps({'images':[{'image-path':str(self.args.work/'Disk.img')}]})
        with patch.object(txn.subprocess,'check_output',return_value=report):
            with self.assertRaisesRegex(txn.Refused,'released image attachments'): txn.recover(self.args)
        self.assertTrue((self.args.work/'Disk.img').is_file())
        self.assertEqual(json.loads((self.vm/'launchpad.json').read_bytes()),self.binding)

    def test_origin_competition_refuses_before_swap_and_after_swap_preserves_both_disks(self):
        self.prepare(); self.apply(); self.seal()
        original = effects.digest(self.vm/'Disk.img')
        changed = dict(self.binding,bundle='2.0.0')
        (self.vm/'launchpad.json').write_bytes(gate.canonical(changed))
        with self.assertRaises((txn.Refused,ValueError)): txn.publish(self.args)
        self.assertEqual(effects.digest(self.vm/'Disk.img'),original)
        txn.swap_files(self.args.work/'Disk.img',self.vm/'Disk.img')
        with contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(txn.Refused): txn.recover(self.args)
        self.assertTrue((self.args.work/'Disk.img').is_file())
        self.assertEqual(txn.load_record(self.args.work)['status'],'publication-uncertain')
        self.assertEqual(json.loads((self.vm/'launchpad.json').read_bytes()),changed)


if __name__ == '__main__': unittest.main()
