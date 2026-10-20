"""CFW guest evidence must describe the exact image that is published."""
import contextlib
import hashlib
import io
import json
from pathlib import Path
from types import SimpleNamespace
import os
import unittest
from unittest.mock import patch

from tests import test_patch_plan_gate as fixtures
import cfw_disk_txn as txn
import cfw_guest_evidence as evidence
from patchers import component_effects, guest_write, undo_provenance
import plistlib


class GuestPublicationTests(unittest.TestCase):
    setUp = fixtures.FrozenGateTests.setUp
    publish = fixtures.FrozenGateTests.publish
    load = fixtures.FrozenGateTests.load

    def transaction(self):
        self.work = self.evidence.parent
        self.work.mkdir()
        self.disk = self.vm / 'Disk.img'
        self.disk.write_bytes(b'original disk')
        self.fd = os.open(self.disk, os.O_RDONLY)
        self.addCleanup(lambda: os.close(self.fd) if self.fd is not None else None)
        self.args = SimpleNamespace(vm=self.vm, work=self.work, fd=self.fd,
            owner_pid=os.getpid(), guest_evidence=True, phase=None, exit_code=0, retain_staged=False)
        self.holders = patch.object(txn, 'holders', return_value=[])
        self.holders.start(); self.addCleanup(self.holders.stop)
        with contextlib.redirect_stdout(io.StringIO()): txn.stage(self.args)
        (self.work / 'Disk.img').write_bytes(b'new guest disk')

    def test_guest_publication_without_final_evidence_refuses_before_swap(self):
        self.transaction()
        with self.assertRaises(txn.Refused): txn.publish(self.args)
        self.assertEqual(self.disk.read_bytes(), b'original disk')
        self.assertEqual((self.work / 'Disk.img').read_bytes(), b'new guest disk')

    def seal(self, release_mount=False):
        plan = self.load()
        source = self.stage / 'dropbear.plist'; source.write_bytes(b'required guest effect')
        target = self.mount / 'mnt1/System/Library/LaunchDaemons/dropbear.plist'
        target.parent.mkdir(parents=True)
        guest_write.run(plan, ['cp', str(source), str(target)])
        raw = self.evidence.read_bytes()
        rows = [json.loads(line) for line in raw.splitlines()]
        outputs = component_effects.verify_rows(plan, rows, {'system': self.mount / 'mnt1'}, self.work / 'effect-blobs')
        record = txn.load_record(self.work)
        image = self.work / 'Disk.img'
        final = dict(schemaVersion=1, transactionID=record['id'], generationID=plan.context['generationID'],
            planDigest=plan.record['planSHA256'], desiredSHA256=plan.raw_sha256,
            operationsSHA256=hashlib.sha256(raw).hexdigest(), stagedImage=str(image),
            stagedIdentity=txn.identity(image.stat()), outputs=outputs)
        final['undoProvenanceSHA256'] = undo_provenance.persist(plan, rows, outputs, self.work)
        evidence.write_final(self.work / evidence.FINAL, evidence.canonical(final))
        undo_provenance.seal(self.work, final)
        if release_mount: self.mount.rename(self.vm / '.released-reader')
        txn.seal(self.args)

    def test_seal_revalidates_plan_after_readonly_mount_directory_is_released(self):
        self.transaction(); self.seal(release_mount=True)
        self.assertFalse(self.mount.exists())
        txn.publish(self.args)
        with contextlib.redirect_stdout(io.StringIO()): txn.finish(self.args)
        self.assertEqual(txn.inspect_guest(self.vm)['state'], 'committed-effects')

    def test_checkpoint_is_required_and_archived_with_actual_published_disk(self):
        self.transaction(); self.seal()
        self.assertIsNone(txn.inspect_guest(self.vm))
        txn.publish(self.args)
        with self.assertRaises(txn.Refused): txn.inspect_guest(self.vm)
        with contextlib.redirect_stdout(io.StringIO()): txn.finish(self.args)
        result = txn.inspect_guest(self.vm)
        self.assertEqual(result['state'], 'committed-effects')
        self.assertEqual(result['imageSHA256'], hashlib.sha256(b'new guest disk').hexdigest())
        self.assertFalse(result['originQualified']); self.assertFalse(result['runtimeValidated'])
        archive = next((self.vm / '.cfw-history').iterdir())
        self.assertEqual((archive / 'Disk.img').read_bytes(), b'original disk')
        self.assertEqual((archive / evidence.PLAN).read_bytes(), self.path.read_bytes())
        self.assertTrue((archive / evidence.STORE).is_dir())

    def test_valid_undo_provenance_cannot_bypass_missing_checkpoint(self):
        self.transaction(); self.seal()
        undo_provenance.verify_publication(self.work, txn.load_record(self.work))
        (self.work / evidence.CHECKPOINT).unlink()
        with self.assertRaisesRegex(txn.Refused, 'guest publication evidence'):
            txn.publish(self.args)
        self.assertEqual(self.disk.read_bytes(), b'original disk')

    def test_checkpoint_requirement_cannot_be_removed_from_new_journal(self):
        self.transaction(); self.seal()
        original = txn.load_record(self.work)
        self.assertEqual(original['version'], 4)
        for version, required in ((4, None), (4, False), (3, True), (2, True), (1, True)):
            record = dict(original, version=version)
            if required is None: record.pop('guestEvidenceRequired')
            else: record['guestEvidenceRequired'] = required
            txn.save_record(self.work, record)
            with self.assertRaises(txn.Refused): txn.publish(self.args)
            self.assertEqual(self.disk.read_bytes(), b'original disk')

    def test_published_undo_index_change_refuses_recovery(self):
        self.transaction(); self.seal(); txn.publish(self.args)
        (self.work / evidence.UNDO).write_bytes(b'changed index')
        with self.assertRaisesRegex(txn.Refused, 'sealed guest evidence changed'):
            txn.finish(self.args)
        self.assertEqual(txn.load_record(self.work)['status'], 'publication-uncertain')
        self.assertEqual((self.work / 'Disk.img').read_bytes(), b'original disk')

    def test_any_sealed_input_change_refuses_before_swap(self):
        for name in ('disk', evidence.FINAL, evidence.UNDO, evidence.OPERATIONS, evidence.PLAN, evidence.CONTEXT, 'blob', 'extra-blob'):
            with self.subTest(name=name):
                # Each subtest uses an independent inherited lock and generation.
                case = GuestPublicationTests(methodName='runTest')
                case.setUp()
                try:
                    case.transaction(); case.seal()
                    if name == 'disk': path = case.work / 'Disk.img'
                    elif name == 'blob': path = next((case.work / evidence.STORE).iterdir())
                    elif name == 'extra-blob': path = case.work / evidence.STORE / ('f' * 64)
                    else: path = case.work / name
                    path.write_bytes(b'changed')
                    with case.assertRaises(txn.Refused): txn.publish(case.args)
                    case.assertEqual(case.disk.read_bytes(), b'original disk')
                finally: case.doCleanups()

    def test_swap_interruption_can_finish_using_exact_sealed_image(self):
        self.transaction(); self.seal()
        txn.swap_files(self.work / 'Disk.img', self.disk)
        with self.assertRaises(txn.Refused): txn.inspect_guest(self.vm)
        self.args.exit_code = 130
        with contextlib.redirect_stdout(io.StringIO()): txn.finish(self.args)
        self.assertEqual(txn.inspect_guest(self.vm)['state'], 'committed-effects')

    def test_recovery_reopens_original_after_owner_descriptor_is_gone(self):
        self.transaction(); self.seal()
        txn.swap_files(self.work / 'Disk.img', self.disk)
        os.close(self.fd); self.fd = None; self.args.fd = None
        with contextlib.redirect_stdout(io.StringIO()): txn.recover(self.args)
        self.assertEqual(txn.inspect_guest(self.vm)['state'], 'committed-effects')
        archive = next((self.vm / '.cfw-history').iterdir())
        self.assertEqual((archive / 'Disk.img').read_bytes(), b'original disk')

    def test_recovery_of_unpublished_copy_keeps_live_original_and_unknown_state(self):
        self.transaction(); self.seal()
        os.close(self.fd); self.fd = None; self.args.fd = None
        with contextlib.redirect_stdout(io.StringIO()): txn.recover(self.args)
        self.assertEqual(self.disk.read_bytes(), b'original disk')
        self.assertIsNone(txn.inspect_guest(self.vm))

    def test_changed_original_refuses_recovery_without_removing_either_image(self):
        self.transaction(); self.seal()
        txn.swap_files(self.work / 'Disk.img', self.disk)
        (self.work / 'Disk.img').write_bytes(b'externally changed prior disk')
        with self.assertRaises(txn.Refused): txn.recover(self.args)
        self.assertEqual(self.disk.read_bytes(), b'new guest disk')
        self.assertEqual((self.work / 'Disk.img').read_bytes(), b'externally changed prior disk')

    def test_unknown_published_bytes_keep_original_and_unfinished_journal(self):
        self.transaction(); self.seal(); txn.publish(self.args)
        self.disk.write_bytes(b'unknown modification')
        with self.assertRaises(txn.Refused): txn.finish(self.args)
        self.assertEqual(txn.load_record(self.work)['status'], 'publication-uncertain')
        self.assertEqual((self.work / 'Disk.img').read_bytes(), b'original disk')
        self.assertEqual(self.disk.read_bytes(), b'unknown modification')
        self.assertFalse((self.vm / '.cfw-history').exists())
        with self.assertRaises(txn.Refused): txn.inspect_guest(self.vm)

    def test_changed_live_desired_plan_after_seal_cannot_publish(self):
        self.transaction(); self.seal()
        self.path.write_bytes(b'changed live desired record')
        with self.assertRaises(txn.Refused): txn.publish(self.args)
        self.assertEqual(self.disk.read_bytes(), b'original disk')

    def test_missing_legacy_checkpoint_stays_unknown_and_linked_blob_refuses(self):
        self.transaction(); self.seal()
        blob = next((self.work / evidence.STORE).iterdir())
        blob.unlink(); blob.symlink_to(self.disk)
        with self.assertRaises(txn.Refused): txn.publish(self.args)
        self.assertEqual(self.disk.read_bytes(), b'original disk')

    def test_final_report_from_another_image_or_transaction_cannot_be_sealed(self):
        self.transaction()
        image = self.work / 'Disk.img'
        plan = self.load()
        self.evidence.write_bytes(b'{}\n')
        for change in ({'transactionID': 'another'}, {'stagedIdentity': {}}):
            final = dict(schemaVersion=1, transactionID=txn.load_record(self.work)['id'],
                generationID=plan.context['generationID'], planDigest=plan.record['planSHA256'], desiredSHA256=plan.raw_sha256,
                operationsSHA256=hashlib.sha256(self.evidence.read_bytes()).hexdigest(), stagedImage=str(image),
                stagedIdentity=txn.identity(image.stat()), outputs=[{'target': 'system:/fixture'}])
            final.update(change)
            evidence.write_final(self.work / evidence.FINAL, evidence.canonical(final))
            with self.assertRaises(txn.Refused): txn.seal(self.args)
        self.assertEqual(self.disk.read_bytes(), b'original disk')

    def test_final_reader_uses_physical_disk_when_attachment_also_lists_synthesized_container(self):
        from patchers import final_guest
        image = self.vm / 'Disk.img'
        container = {'ContainerReference': 'disk42', 'PhysicalStores': [{'DeviceIdentifier': 'disk41s1'}]}
        attached = {'images': [{'image-path': str(image), 'system-entities': [
            {'dev-entry': '/dev/disk41', 'content-hint': 'GUID_partition_scheme'},
            {'dev-entry': '/dev/disk42', 'content-hint': 'Apple_APFS'}]}]}
        with patch.object(final_guest.subprocess, 'check_output', side_effect=[
                plistlib.dumps(attached), plistlib.dumps({'Containers': [container]})]):
            self.assertEqual(final_guest.attachments(image), container)

    def test_final_mount_uses_volume_info_when_apfs_inventory_has_no_mountpoint(self):
        from patchers import final_guest
        plan = self.load()
        image = self.vm/'.cfw_disk.test/Disk.img'
        root = self.mount/'mnt1'
        mounted = False
        commands = []
        container = {'ContainerReference':'disk42', 'PhysicalStores':[{'DeviceIdentifier':'disk41s1'}],
                     'Volumes':[{'DeviceIdentifier':'disk42s1','Roles':['System']} ]}
        def query(argv):
            if argv[0] == '/usr/bin/hdiutil':
                return plistlib.dumps({'images':[{'image-path':str(image),'system-entities':[
                    {'dev-entry':'/dev/disk41','content-hint':'GUID_partition_scheme'}]}]})
            if argv[1:3] == ['apfs','list']:
                return plistlib.dumps({'Containers':[container]})
            self.assertIn(argv[-1], ['/dev/disk42s1', str(root)])
            info = {'DeviceIdentifier':'disk42s1','Mounted':mounted}
            if mounted: info.update(MountPoint=str(root),WritableVolume=False)
            return plistlib.dumps(info)
        def execute(argv, **kwargs):
            nonlocal mounted
            self.assertEqual(argv, ['/sbin/mount_apfs','-o','rdonly','/dev/disk42s1',str(root)])
            commands.append(argv)
            mounted = True
        with patch.object(final_guest.subprocess,'check_output',side_effect=query), \
             patch.object(final_guest.subprocess,'run',side_effect=execute):
            roots, observed, identities = final_guest.mount_roots(plan,image,{'system'})
        self.assertEqual(roots['system'],root)
        self.assertEqual(observed,container)
        self.assertEqual(identities['system'],(root.stat().st_dev,root.stat().st_ino))
        self.assertEqual(len(commands),1)


if __name__ == '__main__': unittest.main()
