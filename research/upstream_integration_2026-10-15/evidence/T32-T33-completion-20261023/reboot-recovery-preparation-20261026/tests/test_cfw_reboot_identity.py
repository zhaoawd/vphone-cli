"""Explicit identity requalification must not become a general device alias."""
import copy
import hashlib
from pathlib import Path
import tempfile
import unittest
from cfw_reboot_identity import RequalifiedIdentity


class RebootIdentityTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name).resolve();self.disk=self.root/'Disk.img';self.disk.write_bytes(b'authenticated publication')
        s=self.disk.stat();self.actual=dict(dev=s.st_dev,ino=s.st_ino,size=s.st_size,mtime_ns=s.st_mtime_ns)
        self.old=dict(self.actual,dev=s.st_dev+1)
        self.member=dict(paths=['Disk.img','history/old/Disk.img'],recorded=self.old,
            current=self.actual,sha256=hashlib.sha256(self.disk.read_bytes()).hexdigest())

    def binding(self, member=None):
        return RequalifiedIdentity(self.root,'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',[self.member if member is None else member])

    def test_device_change_requires_explicit_full_content_requalification(self):
        binding=self.binding();binding.verify_files('AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA')
        self.assertTrue(binding.matches(self.disk,self.old,self.actual))
        self.assertEqual(self.old['dev'],self.actual['dev']+1)

    def test_changed_bytes_or_metadata_never_receive_alias(self):
        binding=self.binding();self.disk.write_bytes(b'other publication')
        with self.assertRaises(ValueError):binding.verify_files('AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA')
        for key in ('ino','size','mtime_ns'):
            current=dict(self.actual);current[key]+=1
            self.assertFalse(binding.matches(self.disk,self.old,current))

    def test_unverified_or_other_volume_is_refused(self):
        binding=self.binding()
        self.assertFalse(binding.matches(self.disk,self.old,self.actual))
        with self.assertRaises(ValueError):binding.verify_files('BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB')
        self.assertFalse(binding.matches(self.disk,self.old,self.actual))

    def test_unlisted_path_or_record_cannot_reuse_verified_identity(self):
        binding=self.binding();binding.verify_files('AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA')
        self.assertFalse(binding.matches(self.root/'unlisted',self.old,self.actual))
        wrong=dict(self.old,dev=self.old['dev']+1)
        self.assertFalse(binding.matches(self.disk,wrong,self.actual))
        self.assertFalse(binding.matches(self.root.parent/'Disk.img',self.old,self.actual))

    def test_only_explicit_recorded_rename_is_accepted(self):
        binding=self.binding();binding.verify_files('AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA')
        target=self.root/'history/old/Disk.img';target.parent.mkdir(parents=True);self.disk.rename(target)
        self.assertTrue(binding.matches(target,self.old,self.actual))
        target.rename(self.root/'unexpected.img')
        self.assertFalse(binding.matches(self.root/'unexpected.img',self.old,self.actual))

    def test_duplicate_identity_or_escaping_member_is_refused(self):
        with self.assertRaises(ValueError):RequalifiedIdentity(self.root,'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',[self.member,self.member])
        for name in ('../Disk.img','/tmp/Disk.img','history/../Disk.img'):
            member=copy.deepcopy(self.member);member['paths']=[name]
            with self.assertRaises(ValueError):self.binding(member)

    def test_symlink_or_linked_carrier_is_refused(self):
        binding=self.binding();binding.verify_files('AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA')
        self.disk.rename(self.root/'original');self.disk.symlink_to('original')
        self.assertFalse(binding.matches(self.disk,self.old,self.actual))
        with self.assertRaises(ValueError):binding.verify_files('AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA')


class RegisteredRecoveryTests(unittest.TestCase):
    setUp=RebootIdentityTests.setUp

    def record(self):
        return dict(schemaVersion=1,kind='explicit-reboot-requalification',
            vmDirectory=str(self.root),generationID='a'*64,approvedPlanSHA256='b'*64,
            volumeUUID='AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA',members=[self.member])

    def test_registered_record_is_bound_to_exact_vm_generation_and_plan(self):
        from cfw_reboot_identity import decode_registered
        r=self.record()
        binding=decode_registered(r,self.root,'a'*64)
        self.assertFalse(binding.verified)
        for key,value in [('schemaVersion',2),('kind','implicit'),('vmDirectory','/other'),
                ('generationID','c'*64),('approvedPlanSHA256','bad')]:
            bad=copy.deepcopy(r);bad[key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):
                decode_registered(bad,self.root,'a'*64)
        r['unexpected']=True
        with self.assertRaises(ValueError):decode_registered(r,self.root,'a'*64)

    def test_root_record_read_refuses_user_owned_or_writable_carrier(self):
        from cfw_reboot_identity import load_registered
        import json
        path=self.root/'.cfw-reboot-identity.json';path.write_text(json.dumps(self.record()))
        path.chmod(0o444)
        with self.assertRaises(ValueError):load_registered(self.root,'a'*64,'AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA')

class ExistingIdentityGateTests(unittest.TestCase):
    setUp=RebootIdentityTests.setUp
    binding=RebootIdentityTests.binding
    def test_existing_gate_needs_a_verified_binding_for_device_change(self):
        import cfw_disk_txn as txn
        from unittest.mock import patch
        self.assertFalse(txn.is_same(self.disk,self.old))
        binding=self.binding();binding.verify_files('AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA')
        with patch('cfw_reboot_identity.binding_for',return_value=binding,create=True):
            self.assertTrue(txn.is_same(self.disk,self.old))
            self.assertFalse(txn.is_same(self.disk,dict(self.old,ino=self.old['ino']+1)))


class RegistrationWriteGateTests(unittest.TestCase):
    def test_nonroot_registration_refuses_before_lock_or_file_write(self):
        from cfw_reboot_identity import register_requalification
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as temporary, patch('os.geteuid',return_value=501):
            with self.assertRaises(ValueError):register_requalification(Path(temporary),'a'*64,'b'*64,[])
            self.assertEqual(list(Path(temporary).iterdir()),[])


if __name__=='__main__':unittest.main()
