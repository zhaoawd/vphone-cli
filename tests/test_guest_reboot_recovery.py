"""Recover a real partially sealed v5 Undo without invoking its writer again."""
import json
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from tests import test_guest_file_transaction as fixtures
from patchers import component_effects as effects, guest_undo
import cfw_disk_txn as txn
import cfw_guest_evidence as evidence


class GuestRebootRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.f=fixtures.GuestFileTransactionTests();self.f.setUp();self.addCleanup(self.f.doCleanups)
        self.f.commit();self.f.prepare();self.f.apply()
        write=evidence.write_new
        def interrupted(path,data):
            if Path(path).name==evidence.CHECKPOINT:raise OSError('host restart before checkpoint')
            return write(path,data)
        with patch.object(evidence,'write_new',side_effect=interrupted),self.assertRaises(txn.Refused):self.f.seal()
        old=self.f.args.work;record=txn.load_record(old)
        self.source=old.parent/'.cfw-recovery-sources'/record['id'];self.source.parent.mkdir();old.rename(self.source)
        self.before={str(p.relative_to(self.source)):effects.digest(p) for p in self.source.rglob('*') if p.is_file()}
        self.work=self.f.vm/'.cfw_disk.resumed';self.work.mkdir(mode=0o700)
        fd=os.open(self.f.vm/'Disk.img',os.O_RDONLY);self.addCleanup(os.close,fd)
        self.args=SimpleNamespace(vm=self.f.vm,work=self.work,fd=fd,owner_pid=os.getpid(),exit_code=0,retain_staged=False)
        self.expected=dict(recordSHA256=effects.digest(self.source/'transaction.json'),
            imageSHA256=effects.digest(self.source/'Disk.img'),parentImageSHA256=effects.digest(self.f.vm/'Disk.img'),
            approvedPlanSHA256='a'*64)
        os.environ['VPHONE_GUEST_EVIDENCE']=str(self.work/evidence.OPERATIONS)

    def recover(self):
        from patchers import guest_recovery
        with patch.object(guest_undo,'apply',side_effect=AssertionError('writer must not run')):
            guest_recovery.prepare_recovered(self.args,self.source,self.expected)

    def test_partial_seal_is_preserved_and_new_transaction_can_publish(self):
        self.recover()
        self.assertEqual(effects.digest(self.work/'Disk.img'),self.expected['imageSHA256'])
        applied=json.loads((self.work/guest_undo.APPLIED).read_bytes())
        self.assertEqual(applied['schemaVersion'],2)
        self.assertEqual(applied['kind'],'observed-recovered-undo')
        self.f.args=self.args;self.f.seal();txn.publish(self.args)
        txn.finish(self.args)
        report=txn.inspect_guest(self.f.vm)
        self.assertEqual(report['componentReceipts']['removedDeclarations'],[self.f.fixture.declaration])
        self.assertFalse(report['originQualified'])
        self.assertEqual(self.before,{str(p.relative_to(self.source)):effects.digest(p)
                         for p in self.source.rglob('*') if p.is_file()})

    def test_bad_source_is_refused_before_new_staging(self):
        (self.source/'Disk.img').write_bytes(b'changed source')
        with self.assertRaises(ValueError):self.recover()
        self.assertFalse((self.work/'transaction.json').exists())
        self.assertFalse((self.work/'Disk.img').exists())

    def test_changed_retained_source_cannot_remain_qualified(self):
        self.recover();self.f.args=self.args;self.f.seal()
        (self.source/guest_undo.APPLIED).write_bytes(b'{}')
        with self.assertRaises((ValueError,txn.Refused)):txn.publish(self.args)
        self.assertEqual(effects.digest(self.f.vm/'Disk.img'),self.expected['parentImageSHA256'])

    def test_copy_tampering_before_seal_does_not_publish(self):
        self.recover();self.f.args=self.args
        with (self.work/'Disk.img').open('ab') as stream:stream.write(b'changed raw image')
        with self.assertRaises((ValueError,txn.Refused)):self.f.seal()
        self.assertEqual(effects.digest(self.f.vm/'Disk.img'),self.expected['parentImageSHA256'])

    def test_wrong_parent_is_refused_before_new_transaction(self):
        self.expected['parentImageSHA256']='b'*64
        with self.assertRaises(ValueError):self.recover()
        self.assertFalse((self.work/'transaction.json').exists())

    def test_a_different_namespace_with_the_same_name_is_refused(self):
        other=self.f.vm/'other'/self.source.name;other.parent.mkdir();other.mkdir()
        from patchers import guest_recovery
        with self.assertRaises(ValueError):guest_recovery.prepare_recovered(self.args,other,self.expected)
        self.assertFalse((self.work/'transaction.json').exists())

    def test_source_hash_reuse_rechecks_ctime_when_mtime_is_restored(self):
        import hashlib
        from patchers import guest_recovery
        path=self.source/'Disk.img';before=path.stat()
        with patch.object(hashlib,'file_digest',wraps=hashlib.file_digest) as full_read:
            first=guest_recovery.preserved_image_digest(path)
            self.assertEqual(guest_recovery.preserved_image_digest(path),first)
            self.assertEqual(full_read.call_count,1)
            path.write_bytes(b'X'*before.st_size)
            os.utime(path,ns=(before.st_atime_ns,before.st_mtime_ns))
            self.assertNotEqual(guest_recovery.preserved_image_digest(path),first)
            self.assertEqual(full_read.call_count,2)

    def test_identical_bytes_at_a_replaced_source_inode_are_refused(self):
        self.recover();self.f.args=self.args;self.f.seal()
        source=self.source/'Disk.img';replacement=self.source/'replacement.img'
        replacement.write_bytes(source.read_bytes());os.replace(replacement,source)
        with self.assertRaises((ValueError,txn.Refused)):txn.publish(self.args)
        self.assertEqual(effects.digest(self.f.vm/'Disk.img'),self.expected['parentImageSHA256'])

    def test_preallocated_id_names_the_exact_future_archive(self):
        self.args.transaction_id='20261026T000000Z-resumed'
        self.recover()
        self.assertEqual(txn.load_record(self.work)['id'],self.args.transaction_id)
        self.f.args=self.args;self.f.seal();txn.publish(self.args);txn.finish(self.args)
        self.assertTrue((self.f.vm/'.cfw-history'/self.args.transaction_id/'transaction.json').is_file())

    def test_invalid_or_occupied_preallocated_id_refuses_before_staging(self):
        for name in ('../outside','20261026T000000Z-other'):
            self.args.transaction_id=name
            with self.subTest(name=name),self.assertRaises(ValueError):self.recover()
            self.assertFalse((self.work/'transaction.json').exists())
        self.args.transaction_id='20261026T000000Z-resumed'
        (self.f.vm/'.cfw-history'/self.args.transaction_id).mkdir()
        with self.assertRaises(ValueError):self.recover()
        self.assertFalse((self.work/'transaction.json').exists())
