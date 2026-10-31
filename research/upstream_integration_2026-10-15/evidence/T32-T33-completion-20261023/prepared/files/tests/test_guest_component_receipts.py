"""Ordinary CFW component receipts use real producer, seal, swap and recovery."""
import contextlib
import io
import json
import unittest

from tests import test_cfw_guest_publication as fixtures
import cfw_disk_txn as transaction
import cfw_guest_evidence as evidence
from patchers import guest_receipts


class GuestComponentReceiptTests(unittest.TestCase):
    def setUp(self):
        self.f=fixtures.GuestPublicationTests(methodName='runTest');self.f.setUp()
        self.addCleanup(self.f.doCleanups);self.f.transaction()

    def finish(self):
        transaction.publish(self.f.args)
        with contextlib.redirect_stdout(io.StringIO()):transaction.finish(self.f.args)
        return transaction.inspect_guest(self.f.vm)

    def test_regular_install_publishes_guest_only_actual_effect_receipt(self):
        self.f.seal();result=self.finish()
        receipt=result['componentReceipts']
        self.assertEqual(receipt['component'],'Guest')
        self.assertEqual(receipt['state'],'committed')
        self.assertEqual(receipt['transactionID'],result['transactionID'])
        self.assertEqual(receipt['generationID'],result['generationID'])
        self.assertEqual(receipt['imageSHA256'],result['imageSHA256'])
        self.assertEqual(len(receipt['declarations']),1)
        declaration=receipt['declarations'][0]
        self.assertEqual(declaration['declarationID'],'system-launchdaemons-boot-install')
        self.assertEqual(declaration['state'],'verified-effect')
        self.assertEqual(declaration['targets'],['system:/System/Library/LaunchDaemons/dropbear.plist'])
        self.assertFalse(receipt['originQualified']);self.assertFalse(receipt['runtimeValidated'])

    def test_removed_or_corrupted_receipt_refuses_before_disk_swap(self):
        self.f.seal();receipt=self.f.work/'guest-install-receipts.json'
        self.assertTrue(receipt.is_file())
        raw=receipt.read_bytes()
        for data in [b'{}',b'corrupt']:
            receipt.write_bytes(data)
            with self.assertRaises(transaction.Refused):transaction.publish(self.f.args)
            self.assertEqual(self.f.disk.read_bytes(),b'original disk')
        receipt.write_bytes(raw);receipt.rename(receipt.with_suffix('.retained'))
        with self.assertRaises(transaction.Refused):transaction.publish(self.f.args)
        self.assertEqual(self.f.disk.read_bytes(),b'original disk')

    def test_interrupted_swap_recovers_same_component_receipt(self):
        self.f.seal()
        transaction.swap_files(self.f.work/'Disk.img',self.f.disk)
        with contextlib.redirect_stdout(io.StringIO()):transaction.finish(self.f.args)
        result=transaction.inspect_guest(self.f.vm)
        self.assertEqual(result['componentReceipts']['transactionID'],result['transactionID'])

    def test_noop_requires_actual_output_readback_and_is_not_relabelled_as_change(self):
        self.f.seal(preexisting=True);result=self.finish()
        declaration=result['componentReceipts']['declarations'][0]
        self.assertEqual(declaration['state'],'verified-noop')
        self.assertEqual(declaration['targets'],['system:/System/Library/LaunchDaemons/dropbear.plist'])
        self.assertEqual(result['componentReceipts']['activation'],'unknown')
        self.assertEqual(result['componentReceipts']['acceptance'],'unknown')

    def test_old_v4_history_without_receipt_remains_unknown(self):
        record=transaction.load_record(self.f.work)
        record['version']=4;transaction.save_record(self.f.work,record)
        self.f.seal();result=self.finish()
        self.assertNotIn('componentReceipts',result)
        self.assertFalse(result['originQualified'])

    def test_removed_consumed_archive_requires_matching_removal_evidence(self):
        self.f.seal()
        final=json.loads((self.f.work/evidence.FINAL).read_text())
        row=json.loads(self.f.evidence.read_text().splitlines()[0])
        row=dict(row,target='system:/used.tar',path='/used.tar',effect=dict(row['effect'],
                 operation='change',command='rm',after={'kind':'missing'}))
        final['outputs'].append(dict(target='system:/used.tar',state={'kind':'missing'},effects=[]))
        record=transaction.load_record(self.f.work)
        rows=[json.loads(s) for s in self.f.evidence.read_text().splitlines()]
        with self.assertRaisesRegex(ValueError,'producer association'):
            guest_receipts.build(record,final,rows,'a'*64)
        receipt=guest_receipts.build(record,final,rows+[row],'a'*64)
        self.assertIn('system:/used.tar',receipt['declarations'][0]['targets'])


if __name__=='__main__':unittest.main()
