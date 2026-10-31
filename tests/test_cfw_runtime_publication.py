"""Publication evidence remains historical after ordinary runtime disk writes."""
import contextlib
import hashlib
import io
import os
import unittest
from unittest.mock import patch

from tests import test_cfw_guest_publication as fixtures
import cfw_disk_txn as txn
import cfw_guest_evidence as evidence


class RuntimePublicationTests(unittest.TestCase):
    setUp = fixtures.GuestPublicationTests.setUp
    publish = fixtures.GuestPublicationTests.publish
    load = fixtures.GuestPublicationTests.load
    transaction = fixtures.GuestPublicationTests.transaction
    seal = fixtures.GuestPublicationTests.seal

    def commit_runtime(self):
        self.transaction()
        self.seal(); txn.publish(self.args)
        with contextlib.redirect_stdout(io.StringIO()): txn.finish(self.args)
        self.archive = next((self.vm / '.cfw-history').iterdir())

    def runtime_write(self):
        with self.disk.open('r+b') as stream:
            stream.seek(0); stream.write(b'R'); stream.flush(); os.fsync(stream.fileno())

    def test_runtime_write_retains_historical_publication_without_current_effect_authority(self):
        self.commit_runtime(); self.runtime_write()
        result = txn.inspect_guest(self.vm)
        self.assertEqual(result['state'], 'committed-publication')
        self.assertTrue(result['runtimeImageChanged'])
        self.assertFalse(result['runtimeValidated'])
        self.assertEqual(result['imageSHA256'], hashlib.sha256(b'new guest disk').hexdigest())
        self.assertEqual(result['currentImageSHA256'], hashlib.sha256(self.disk.read_bytes()).hexdigest())
        self.assertEqual((self.archive / 'guest-postimage.img').read_bytes(), b'new guest disk')
        self.assertEqual((self.archive / 'Disk.img').read_bytes(), b'original disk')

    def test_missing_corrupt_or_linked_postimage_refuses_runtime_reader(self):
        self.commit_runtime(); self.runtime_write()
        post = self.archive / 'guest-postimage.img'
        data = post.read_bytes()
        post.unlink()
        with self.assertRaises(txn.Refused): txn.inspect_guest(self.vm)
        post.symlink_to(self.disk)
        with self.assertRaises(txn.Refused): txn.inspect_guest(self.vm)
        post.unlink(); post.write_bytes(data)
        with self.assertRaises(txn.Refused): txn.inspect_guest(self.vm)

    def test_postimage_bytes_mutation_refuses(self):
        self.commit_runtime(); self.runtime_write()
        post = self.archive / 'guest-postimage.img'
        with post.open('r+b') as stream: stream.write(b'X')
        with self.assertRaises(txn.Refused): txn.inspect_guest(self.vm)

    def test_replaced_or_resized_runtime_image_refuses(self):
        self.commit_runtime(); self.runtime_write()
        old = self.disk.with_suffix('.held'); self.disk.rename(old)
        self.disk.write_bytes(old.read_bytes())
        self.assertIsNone(txn.inspect_guest(self.vm))
        self.disk.unlink(); old.rename(self.disk)
        with self.disk.open('ab') as stream: stream.write(b'x')
        with self.assertRaises(txn.Refused): txn.inspect_guest(self.vm)

    def test_runtime_writes_before_finish_still_refuse(self):
        self.transaction(); self.seal(); txn.publish(self.args); self.runtime_write()
        with self.assertRaises(txn.Refused): txn.finish(self.args)
        self.assertEqual(txn.load_record(self.work)['status'], 'publication-uncertain')

    def test_legacy_v3_keeps_exact_image_requirement(self):
        self.transaction()
        record = txn.load_record(self.work)
        record['version'] = 3; record.pop('runtimeImageEvidenceRequired', None)
        txn.save_record(self.work, record)
        self.seal(); txn.publish(self.args)
        with contextlib.redirect_stdout(io.StringIO()): txn.finish(self.args)
        self.runtime_write()
        with self.assertRaises(txn.Refused): txn.inspect_guest(self.vm)

    def test_new_journal_cannot_downgrade_or_disable_postimage(self):
        self.transaction(); self.seal()
        record = txn.load_record(self.work)
        self.assertEqual(record['version'], 5)
        for version in (4,3):
            changed = dict(record, version=version)
            txn.save_record(self.work, changed)
            with self.assertRaises(txn.Refused): txn.publish(self.args)
        changed = dict(record, runtimeImageEvidenceRequired=False)
        txn.save_record(self.work, changed)
        with self.assertRaises(txn.Refused): txn.publish(self.args)
        self.assertEqual(self.disk.read_bytes(), b'original disk')

    def test_legacy_v4_runtime_reader_does_not_fabricate_new_component_receipts(self):
        self.transaction()
        record=txn.load_record(self.work);record['version']=4;txn.save_record(self.work,record)
        self.seal();txn.publish(self.args)
        with contextlib.redirect_stdout(io.StringIO()):txn.finish(self.args)
        self.runtime_write();result=txn.inspect_guest(self.vm)
        self.assertEqual(result['state'],'committed-publication')
        self.assertNotIn('componentReceipts',result)
        self.assertFalse(result['originQualified'])

    def test_clone_unavailable_preserves_verified_independent_postimage(self):
        self.transaction()
        with patch.object(txn, 'clone_file', side_effect=OSError('unsupported clone')):
            self.seal()
        self.assertEqual((self.work / evidence.POSTIMAGE).read_bytes(), b'new guest disk')
        self.assertNotEqual((self.work / evidence.POSTIMAGE).stat().st_ino, (self.work / 'Disk.img').stat().st_ino)
        txn.publish(self.args)
        with contextlib.redirect_stdout(io.StringIO()): txn.finish(self.args)
        self.runtime_write()
        self.assertEqual(txn.inspect_guest(self.vm)['state'], 'committed-publication')

    def test_runtime_image_changed_during_sealed_evidence_read_refuses(self):
        self.commit_runtime()
        verify = evidence.verify
        def changed(*args, **kwargs):
            result = verify(*args, **kwargs)
            self.runtime_write()
            return result
        with patch.object(evidence, 'verify', side_effect=changed):
            with self.assertRaisesRegex(txn.Refused, 'changed during read'):
                txn.inspect_guest(self.vm)

    def test_failed_postimage_clone_never_publishes(self):
        self.transaction()
        with patch.object(evidence, 'preserve_postimage', side_effect=OSError('clone failed')):
            with self.assertRaises(txn.Refused): self.seal()
        self.assertEqual(self.disk.read_bytes(), b'original disk')
        self.assertFalse((self.work / evidence.CHECKPOINT).exists())


if __name__ == '__main__': unittest.main()
