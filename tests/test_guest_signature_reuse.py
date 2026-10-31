"""Signature reuse follows sealed disk ancestry, never an unbound cache."""
import contextlib
import io
import json
import os
from pathlib import Path
import struct
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from tests import test_cfw_guest_publication as publication
from tests.test_component_signatures import signed_macho
from patchers import guest_write, plan_gate as gate
import cfw_disk_txn as txn


def artifact(number):
    data=bytearray(signed_macho(entitlements={'fixtureNonce':number}))
    # A valid ad-hoc signature needs no CMS publisher assertion.
    struct.pack_into('>I',data,4096+28+12,2)
    return bytes(data)


class GuestSignatureReuseTests(unittest.TestCase):
    def setUp(self):
        self.f=publication.GuestPublicationTests(methodName='runTest');self.f.setUp()
        self.addCleanup(self.f.doCleanups);self.f.transaction()
        self.declaration='system-seputil-boot-gigalocker_uuid'
        self.source=self.f.stage/'seputil'
        self.signer=self.f.root/'ldid';self.signer.write_bytes(b'fixture signer');self.signer.chmod(0o755)
        self.calls=0
        self.transaction_number=0

    def execute(self,argv):
        self.calls+=1;self.source.write_bytes(artifact(self.calls))

    def sign(self,extra=()):
        self.source.write_bytes(signed_macho());self.source.chmod(0o755)
        guest_write.sign(self.f.load(),[str(self.signer),'-S','-M',*extra,str(self.source)],execute=self.execute)
        return self.source.read_bytes()

    def commit_first(self):
        data=self.sign()
        target=self.f.mount/'mnt1/usr/libexec/seputil';target.parent.mkdir(parents=True)
        guest_write.run(self.f.load(),['cp',str(self.source),str(target)])
        self.f.seal();txn.publish(self.f.args)
        with contextlib.redirect_stdout(io.StringIO()):txn.finish(self.f.args)
        self.archive=next((self.f.vm/'.cfw-history').iterdir())
        return data

    def next_transaction(self):
        self.transaction_number+=1
        self.work=self.f.vm/f'.cfw_disk.sig-reapply{self.transaction_number}';self.work.mkdir(mode=0o700)
        self.mount=self.f.vm/f'.cfw_mount.sig-reapply{self.transaction_number}';(self.mount/'mnt1').mkdir(parents=True)
        fd=os.open(self.f.vm/'Disk.img',os.O_RDONLY);self.addCleanup(os.close,fd)
        args=SimpleNamespace(vm=self.f.vm,work=self.work,fd=fd,owner_pid=os.getpid(),guest_evidence=True,
                             exit_code=0,retain_staged=False)
        os.environ.update(VPHONE_GUEST_EVIDENCE=str(self.work/'guest-changes.jsonl'),CFW_HOST_MNT=str(self.mount))
        with contextlib.redirect_stdout(io.StringIO()):txn.stage(args)
        return args

    def test_reapplication_reuses_exact_sealed_signature_instead_of_resigning(self):
        first=self.commit_first();self.next_transaction()
        self.assertEqual(self.sign(),first)
        self.assertEqual(self.calls,1)
        row=json.loads((self.work/'guest-changes.jsonl').read_text().splitlines()[-1])
        self.assertEqual(row['effect']['signatureReuse']['transactionID'],self.archive.name)
        self.assertFalse(txn.inspect_guest(self.f.vm)['originQualified'])

    def test_reuse_traverses_a_sealed_publication_without_a_matching_sign_operation(self):
        first=self.commit_first();args=self.next_transaction()
        self.f.work=self.work;self.f.mount=self.mount;self.f.evidence=self.work/'guest-changes.jsonl';self.f.args=args
        self.f.seal();txn.publish(args)
        with contextlib.redirect_stdout(io.StringIO()):txn.finish(args)
        self.next_transaction()
        self.assertEqual(self.sign(),first);self.assertEqual(self.calls,1)

    def test_signer_bytes_key_bytes_or_options_change_cannot_reuse(self):
        key=self.f.root/'signcert';key.write_bytes(b'fixture key A')
        self.sign(extra=('-K'+str(key),))
        # Publish a complete first signature whose normalized key input is captured.
        target=self.f.mount/'mnt1/usr/libexec/seputil';target.parent.mkdir(parents=True)
        guest_write.run(self.f.load(),['cp',str(self.source),str(target)])
        self.f.seal();txn.publish(self.f.args)
        with contextlib.redirect_stdout(io.StringIO()):txn.finish(self.f.args)
        self.next_transaction();key.write_bytes(b'fixture key B')
        self.sign(extra=('-K'+str(key),));self.assertEqual(self.calls,2)
        key.write_bytes(b'fixture key A');self.signer.write_bytes(b'different signer')
        self.sign(extra=('-K'+str(key),));self.assertEqual(self.calls,3)
        self.signer.write_bytes(b'fixture signer')
        self.sign(extra=('-K'+str(key),'-Idifferent.identifier'));self.assertEqual(self.calls,4)

    def test_corrupt_sealed_source_refuses_before_the_signing_target_is_changed(self):
        self.commit_first();self.next_transaction()
        (self.archive/'guest-changes.jsonl').write_bytes(b'corrupt')
        with self.assertRaises((ValueError,txn.Refused)):self.sign()
        self.assertEqual(self.source.read_bytes(),signed_macho());self.assertEqual(self.calls,1)

    def test_legacy_signing_observation_without_inputs_is_not_upgraded(self):
        from patchers import signature_reuse
        with patch.object(signature_reuse,'inputs',return_value=None):first=self.commit_first()
        self.next_transaction()
        self.assertNotEqual(self.sign(),first);self.assertEqual(self.calls,2)

    def test_unrelated_history_cannot_qualify_a_new_disk(self):
        first=self.commit_first()
        unrelated=self.f.vm/'new-disk';unrelated.write_bytes(b'unrelated disk')
        os.replace(unrelated,self.f.vm/'Disk.img')
        self.next_transaction()
        self.assertNotEqual(self.sign(),first);self.assertEqual(self.calls,2)

    def test_changed_signing_input_does_not_reuse(self):
        self.commit_first();self.next_transaction()
        self.source.write_bytes(signed_macho(b'different'));self.source.chmod(0o755)
        def execute(argv):
            self.calls+=1
            data=bytearray(signed_macho(b'different',entitlements={'fixtureNonce':self.calls}))
            struct.pack_into('>I',data,4096+28+12,2);self.source.write_bytes(data)
        guest_write.sign(self.f.load(),[str(self.signer),'-S','-M',str(self.source)],execute=execute)
        self.assertEqual(self.calls,2)


if __name__=='__main__':unittest.main()
