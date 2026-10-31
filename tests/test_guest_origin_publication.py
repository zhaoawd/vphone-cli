"""Real producer effects, journal, swap and origin recovery; native Store seam only."""
import contextlib
import io
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch

from tests import test_cfw_guest_publication as publication
import cfw_disk_txn as txn
import cfw_guest_evidence as evidence
from patchers import guest_origin, plan_gate as gate


class GuestOriginPublicationTests(unittest.TestCase):
    def setUp(self):
        self.f=publication.GuestPublicationTests(methodName='runTest');self.f.setUp()
        self.addCleanup(self.f.doCleanups)
        self.version='2.6.2-local.f00dbabe'
        store=self.f.root/'store';contents=store/self.version/'VPhone.bundle/Contents'
        executable=contents/'MacOS/vphone-cli';executable.parent.mkdir(parents=True)
        executable.write_bytes(self.f.verifier.read_bytes());executable.chmod(0o755)
        resources=contents/'Resources';resources.mkdir()
        self.f.verifier=executable
        self.f.context.update(verifierPath=str(executable),verifierSHA256=evidence.digest(executable))
        self.f.publish()
        os.environ.update(VPHONE_FROZEN_PLAN_SHA256=self.f.digest,VPHONE_FROZEN_CONTEXT=json.dumps(self.f.context))
        self.source=dict(schemaVersion=1,producer='current-verified-core-bundle-cli',version=self.version,
            executable=str(executable),executableSHA256=evidence.digest(executable),resourceBase=str(resources),
            archiveSHA256='a'*64,cliCDHash='b'*40)
        self.binding=dict(bundle=self.version,guestEnvironment='2.6.1',kernel='2.6.0',bootChain='2.6.1')
        (self.f.vm/'launchpad.json').write_bytes(gate.canonical(self.binding))
        for item in (patch.object(guest_origin,'STORE',store),patch.object(guest_origin,'RESOURCES',resources),
                     patch.object(guest_origin,'OWNER',os.geteuid()),
                     patch.dict(os.environ,{guest_origin.ENV:json.dumps(self.source)})):
            item.start();self.addCleanup(item.stop)
        self.native=patch.object(guest_origin,'native_verification')
        self.verifier=self.native.start();self.addCleanup(self.native.stop)

    def finish(self):
        with contextlib.redirect_stdout(io.StringIO()):txn.finish(self.f.args)
        return txn.inspect_guest(self.f.vm)

    def test_producer_and_receipt_publish_guest_origin_with_the_same_disk_only(self):
        self.f.transaction();self.f.seal()
        self.assertEqual(json.loads((self.f.vm/'launchpad.json').read_bytes()),self.binding)
        txn.publish(self.f.args);report=self.finish()
        self.assertTrue(report['originQualified'])
        self.assertTrue(report['componentReceipts']['originQualified'])
        self.assertEqual(report['componentReceipts']['qualifiedProducer'],self.source)
        self.assertFalse(report['runtimeValidated'])
        self.assertEqual(json.loads((self.f.vm/'launchpad.json').read_bytes()),dict(self.binding,guestEnvironment=self.version))
        self.assertTrue(any(call.kwargs['require_lease'] for call in self.verifier.call_args_list))

    def test_source_or_transition_tampering_refuses_before_disk_swap(self):
        self.f.transaction();self.f.seal()
        for name in (guest_origin.SOURCE,guest_origin.TRANSITION):
            path=self.f.work/name;raw=path.read_bytes();path.write_bytes(b'{}')
            with self.assertRaises((ValueError,txn.Refused)):txn.publish(self.f.args)
            self.assertEqual(self.f.disk.read_bytes(),b'original disk')
            path.write_bytes(raw)

    def test_changed_unrelated_origin_refuses_publication(self):
        self.f.transaction();self.f.seal()
        (self.f.vm/'launchpad.json').write_bytes(gate.canonical(dict(self.binding,kernel='2.6.2')))
        with self.assertRaises((ValueError,txn.Refused)):txn.publish(self.f.args)
        self.assertEqual(self.f.disk.read_bytes(),b'original disk')

    def test_live_store_rejection_precedes_cloning(self):
        self.verifier.side_effect=ValueError('Store lease expired')
        with self.assertRaisesRegex(ValueError,'expired'):self.f.transaction()
        self.assertEqual(self.f.disk.read_bytes(),b'original disk')
        self.assertFalse((self.f.work/'Disk.img').exists())

    def test_resource_override_or_non_store_source_cannot_qualify(self):
        for field,value in [('resourceBase','/tmp/foreign'),('executable','/tmp/foreign')]:
            with self.subTest(field=field),patch.dict(os.environ,{guest_origin.ENV:json.dumps(dict(self.source,**{field:value}))}):
                with self.assertRaises(ValueError):guest_origin.live_source(self.f.load())

    def test_unqualified_install_clears_guest_origin_with_its_disk_publication(self):
        with patch.dict(os.environ):
            os.environ.pop(guest_origin.ENV,None)
            self.f.transaction(invalidate_guest_origin=True);self.f.seal()
            self.assertEqual(json.loads((self.f.vm/'launchpad.json').read_bytes()),self.binding)
            txn.publish(self.f.args);report=self.finish()
        self.assertFalse(report['originQualified'])
        self.assertNotIn('qualifiedProducer',report['componentReceipts'])
        expected={key:value for key,value in self.binding.items() if key!='guestEnvironment'}
        self.assertEqual(json.loads((self.f.vm/'launchpad.json').read_bytes()),expected)

    def test_unqualified_invalidation_cannot_change_an_unrelated_origin(self):
        with patch.dict(os.environ):
            os.environ.pop(guest_origin.ENV,None)
            self.f.transaction(invalidate_guest_origin=True);self.f.seal()
            (self.f.vm/'launchpad.json').write_bytes(gate.canonical(dict(self.binding,kernel='changed')))
            with self.assertRaises((ValueError,txn.Refused)):txn.publish(self.f.args)
        self.assertEqual(self.f.disk.read_bytes(),b'original disk')

    def test_interrupted_disk_swap_recovers_the_exact_sealed_source_and_guest_origin(self):
        self.f.transaction();self.f.seal()
        txn.swap_files(self.f.work/'Disk.img',self.f.disk)
        self.f.args.exit_code=130
        report=self.finish()
        self.assertTrue(report['originQualified'])
        self.assertEqual(report['componentReceipts']['qualifiedProducer'],self.source)
        self.assertEqual(json.loads((self.f.vm/'launchpad.json').read_bytes()),dict(self.binding,guestEnvironment=self.version))

    def test_origin_write_failure_retains_both_disks_for_qualified_recovery(self):
        self.f.transaction();self.f.seal()
        from patchers import guest_undo
        with patch.object(guest_undo,'publish_snapshot',side_effect=OSError('injected origin publication failure')):
            with self.assertRaisesRegex(txn.Refused,'injected'):txn.publish(self.f.args)
        self.assertEqual(txn.load_record(self.f.work)['status'],'publication-uncertain')
        self.assertEqual(self.f.disk.read_bytes(),b'new guest disk')
        self.assertEqual((self.f.work/'Disk.img').read_bytes(),b'original disk')
        self.assertEqual(json.loads((self.f.vm/'launchpad.json').read_bytes()),self.binding)
        self.assertTrue(self.finish()['originQualified'])

    def test_source_label_alone_cannot_lift_a_legacy_install(self):
        self.f.transaction()
        record=txn.load_record(self.f.work)
        record['version']=4;txn.save_record(self.f.work,record)
        with self.assertRaisesRegex((ValueError,txn.Refused),'incomplete'):self.f.seal()
        self.assertEqual(json.loads((self.f.vm/'launchpad.json').read_bytes()),self.binding)

    def test_attestation_mode_or_digest_change_cannot_qualify(self):
        self.f.transaction();self.f.seal()
        path=self.f.work/guest_origin.ATTESTATION
        path.chmod(0o644)
        with self.assertRaises((ValueError,txn.Refused)):txn.publish(self.f.args)
        path.write_bytes(b'forged proof');path.chmod(0o444)
        record=txn.load_record(self.f.work)
        record['guestOriginAttestationSHA256']=evidence.digest(path);txn.save_record(self.f.work,record)
        with self.assertRaises((ValueError,txn.Refused)):txn.publish(self.f.args)
        self.assertEqual(self.f.disk.read_bytes(),b'original disk')

    def test_standalone_source_description_cannot_qualify_an_unprivileged_producer(self):
        with patch.object(guest_origin,'OWNER',os.geteuid()+1):
            with self.assertRaisesRegex(ValueError,'requires root'):guest_origin.live_source(self.f.load())


if __name__=='__main__':unittest.main()
