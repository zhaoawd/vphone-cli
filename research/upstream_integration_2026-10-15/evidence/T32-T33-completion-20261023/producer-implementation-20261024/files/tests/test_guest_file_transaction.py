"""Real file Undo writer, final reader and journal; only APFS queries are modeled."""
import contextlib
import io
import json
import os
import plistlib
import shutil
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from tests import test_guest_file_undo as fixtures
from patchers import component_effects as effects, final_guest, guest_undo, plan_gate as gate
import cfw_disk_txn as txn


class GuestFileTransactionTests(unittest.TestCase):
    def setUp(self):
        self.fixture=fixtures.GuestFileUndoTests();self.fixture.setUp();self.addCleanup(self.fixture.doCleanups)
        self.f=self.fixture.f;self.vm=self.fixture.plan_fixture.vm;self.work=self.f.work
        self.generation=self.f.plan.context['generationID'];self.current_root=self.fixture.plan_fixture.mount/'mnt1'
        self.mount=self.fixture.plan_fixture.mount;self.directory='mnt1';self.slice='s1';self.relative='usr/libexec/seputil'
        self.fd=os.open(self.vm/'Disk.img',os.O_RDONLY);self.addCleanup(os.close,self.fd)
        self.args=SimpleNamespace(vm=self.vm,work=self.work,fd=self.fd,owner_pid=os.getpid(),exit_code=0,retain_staged=False)
        record=txn.load_record(self.work);record.update(checks=[],failure=None)
        record['original']['sample']=txn.sample_digest(self.fd,record['original']['size']);txn.save_record(self.work,record)
        mock=patch.object(txn,'holders',return_value=[]);mock.start();self.addCleanup(mock.stop)

    def commit(self):
        self.fixture.produce()
        with patch.object(final_guest.subprocess,'check_output',side_effect=self.query(True)), \
             patch.object(sys,'argv',['plan_gate.py','verify-final']):gate.main()
        txn.seal(self.args);txn.publish(self.args)
        with contextlib.redirect_stdout(io.StringIO()):txn.finish(self.args)
        self.initial=effects.digest(self.vm/'Disk.img')

    def prepare(self):
        work=self.vm/'.cfw_disk.fileundo';work.mkdir(mode=0o700)
        self.mount=self.vm/'.cfw_mount.fileundo';self.mount.mkdir()
        shutil.copytree(self.current_root,self.mount/self.directory)
        fd=os.open(self.vm/'Disk.img',os.O_RDONLY);self.addCleanup(os.close,fd)
        self.args=SimpleNamespace(vm=self.vm,work=work,fd=fd,owner_pid=os.getpid(),guest_evidence=True,
            generation=self.generation,declaration=[self.fixture.declaration],exit_code=0,retain_staged=False)
        os.environ.update(VPHONE_GUEST_EVIDENCE=str(work/'guest-changes.jsonl'),CFW_HOST_MNT=str(self.mount))
        with contextlib.redirect_stdout(io.StringIO()):txn.stage(self.args)
        guest_undo.prepare(self.args)
        self.target=self.mount/self.directory/self.relative;self.backup=self.target.with_name(self.target.name+'.bak')

    def query(self,readonly):
        def query(args):
            if args[0]=='/usr/bin/hdiutil':
                return plistlib.dumps({'images':[{'image-path':str(self.args.work/'Disk.img'),
                    'system-entities':[{'dev-entry':'/dev/disk41'}]}]})
            root=str(self.mount/self.directory);device='disk42'+self.slice
            if args[1:3]==['apfs','list']:
                return plistlib.dumps({'Containers':[{'ContainerReference':'disk42',
                    'PhysicalStores':[{'DeviceIdentifier':'disk41s1'}],
                    'Volumes':[{'DeviceIdentifier':device,'MountPoint':root}]}]})
            return plistlib.dumps({'ReadOnlyVolume':readonly,'DeviceIdentifier':device,'MountPoint':root})
        return query

    def apply(self):
        with patch.object(final_guest.subprocess,'check_output',side_effect=self.query(False)):
            guest_undo.apply(self.args)
        # Model the unmount flush into this transaction's disposable image.
        (self.args.work/'Disk.img').write_bytes(self.target.read_bytes())

    def seal(self):
        with patch.object(final_guest.subprocess,'check_output',side_effect=self.query(True)), \
             patch.object(sys,'argv',['plan_gate.py','verify-final']):gate.main()
        txn.seal(self.args)

    def test_full_file_undo_with_no_retained_rows_publishes_original_and_preserves_backup(self):
        self.commit();self.prepare();backup=effects.state(self.backup)
        self.assertEqual((self.args.work/'guest-changes.jsonl').read_bytes(),b'')
        self.apply();self.assertEqual(self.target.read_bytes(),self.fixture.o.binary.read_bytes())
        self.assertEqual(effects.state(self.target),effects.state(self.fixture.o.binary))
        self.assertEqual(effects.state(self.backup),backup)
        self.seal();txn.publish(self.args)
        with contextlib.redirect_stdout(io.StringIO()):txn.finish(self.args)
        receipt=txn.inspect_guest(self.vm)['componentReceipts']
        self.assertEqual(receipt['removedDeclarations'],[self.fixture.declaration])
        self.assertEqual(receipt['appliedDeclarations'],[])
        self.assertEqual(receipt['guestOrigin']['state'],'unknown')
        self.assertEqual({row['target'] for row in receipt['components']},
                         {'system:/usr/libexec/seputil','system:/usr/libexec/seputil.bak'})
        with self.assertRaises(txn.Refused):txn.preview_guest_undo(self.vm,self.generation,[self.fixture.declaration])

    def test_current_bytes_metadata_or_original_backup_damage_refuse_before_any_write(self):
        self.commit();self.prepare();original=self.target.read_bytes();backup=self.backup.read_bytes()
        for fault in ('bytes','mode','backup'):
            with self.subTest(fault=fault):
                if fault=='bytes':self.target.write_bytes(b'changed')
                elif fault=='mode':os.chmod(self.target,0o600)
                else:self.backup.write_bytes(b'changed')
                before=self.target.read_bytes()
                with self.assertRaises(ValueError),patch.object(final_guest.subprocess,'check_output',side_effect=self.query(False)):
                    guest_undo.apply(self.args)
                self.assertEqual(self.target.read_bytes(),before)
                self.assertEqual(effects.digest(self.vm/'Disk.img'),self.initial)
                self.assertFalse((self.args.work/guest_undo.APPLIED).exists())
                self.target.write_bytes(original);os.chmod(self.target,0o755);self.backup.write_bytes(backup)

    def test_apply_actual_file_undo_and_reapply_preserve_exact_signed_bytes(self):
        import struct
        from tests.test_component_signatures import signed_macho
        from patchers import guest_write
        signer=self.vm/'ldid';signer.write_bytes(b'fixture signer');signer.chmod(0o755)
        calls=[]
        def sign():
            def execute(argv):
                calls.append(argv)
                data=bytearray(signed_macho(b'changed',entitlements={'fixtureNonce':len(calls)}))
                struct.pack_into('>I',data,4096+28+12,2)
                self.fixture.staged.write_bytes(data)
            guest_write.sign(self.f.plan,[str(signer),'-S','-M',str(self.fixture.staged)],execute=execute)
        original_produce=self.fixture.produce
        def produce():
            result=original_produce(sign=sign)
            (self.args.work/'Disk.img').write_bytes(self.fixture.target.read_bytes())
            return result
        self.fixture.produce=produce
        self.commit();signed=self.fixture.target.read_bytes()
        self.prepare();self.apply()
        self.assertEqual(self.target.read_bytes(),self.fixture.o.binary.read_bytes())
        self.seal();txn.publish(self.args)
        with contextlib.redirect_stdout(io.StringIO()):txn.finish(self.args)
        self.assertEqual(txn.inspect_guest(self.vm)['componentReceipts']['removedDeclarations'],[self.fixture.declaration])

        previous_root=self.mount/'mnt1'
        work=self.vm/'.cfw_disk.reapply';work.mkdir(mode=0o700)
        self.mount=self.vm/'.cfw_mount.reapply';shutil.copytree(previous_root,self.mount/'mnt1')
        fd=os.open(self.vm/'Disk.img',os.O_RDONLY);self.addCleanup(os.close,fd)
        self.args=SimpleNamespace(vm=self.vm,work=work,fd=fd,owner_pid=os.getpid(),guest_evidence=True,
                                 exit_code=0,retain_staged=False)
        os.environ.update(VPHONE_GUEST_EVIDENCE=str(work/'guest-changes.jsonl'),CFW_HOST_MNT=str(self.mount))
        with contextlib.redirect_stdout(io.StringIO()):txn.stage(self.args)
        p=self.fixture.plan_fixture;p.mount=self.mount;p.evidence=work/'guest-changes.jsonl'
        self.f.work=work;self.f.plan=p.load()
        self.fixture.o.work=work;self.fixture.o.store=work/'effect-blobs';self.fixture.o.catalog()
        self.fixture.target=self.mount/'mnt1/usr/libexec/seputil'
        produce()
        self.assertEqual(self.fixture.target.read_bytes(),signed)
        self.assertEqual(len(calls),1)
        self.seal();txn.publish(self.args)
        with contextlib.redirect_stdout(io.StringIO()):txn.finish(self.args)
        report=txn.inspect_guest(self.vm)
        self.assertIn(self.fixture.declaration,{row['declarationID'] for row in report['componentReceipts']['declarations']})
        self.assertFalse(report['originQualified'])

    def test_failure_during_write_cannot_publish_or_change_original_disk(self):
        self.commit();self.prepare()
        with patch.object(final_guest.subprocess,'check_output',side_effect=self.query(False)), \
             patch.object(guest_undo.os,'write',side_effect=OSError('injected file write failure')):
            with self.assertRaisesRegex(OSError,'injected'):guest_undo.apply(self.args)
        self.assertEqual(effects.digest(self.vm/'Disk.img'),self.initial)
        self.assertFalse((self.args.work/guest_undo.APPLIED).exists())
        with self.assertRaises((ValueError,txn.Refused)):txn.publish(self.args)

    def test_backup_change_after_apply_refuses_final_readback(self):
        self.commit();self.prepare();self.apply();self.backup.write_bytes(b'tampered backup')
        with self.assertRaisesRegex(ValueError,'backup'):self.seal()
        self.assertEqual(effects.digest(self.vm/'Disk.img'),self.initial)
        self.assertFalse((self.args.work/'guest-publication.json').exists())

    def test_installed_audit_keeps_file_and_dsc_source_counts_distinct(self):
        import cfw_verify_effects as audit
        self.commit()
        @contextlib.contextmanager
        def native(image,wanted,parent):
            self.assertEqual(wanted,{'system'})
            yield {'system':self.current_root},lambda:None
        with patch.object(audit,'readonly_roots',side_effect=native):
            result=audit.audit_locked(self.vm,self.vm)
        self.assertTrue(result['passed'])
        self.assertFalse(result['authenticatedDSCSourceAssociation'])
        self.assertEqual(result['authenticatedDSCEntries'],0)
        self.assertEqual(result['authenticatedFileEntries'],1)

    def test_swap_interruption_recovers_file_receipt_and_unknown_origin(self):
        self.commit();binding={'bundle':'1.0.0','guestEnvironment':'1.0.0','kernel':'1.0.0'}
        (self.vm/'launchpad.json').write_bytes(gate.canonical(binding))
        self.prepare();self.apply();self.seal()
        txn.swap_files(self.args.work/'Disk.img',self.vm/'Disk.img');self.args.exit_code=130
        with contextlib.redirect_stdout(io.StringIO()):txn.recover(self.args)
        self.assertEqual(json.loads((self.vm/'launchpad.json').read_bytes()),{'bundle':'1.0.0','kernel':'1.0.0'})
        receipt=txn.inspect_guest(self.vm)['componentReceipts']
        self.assertEqual(receipt['removedDeclarations'],[self.fixture.declaration])
        self.assertEqual(receipt['imageSHA256'],effects.digest(self.vm/'Disk.img'))

    def test_preboot_data_size_change_restores_full_original_and_metadata(self):
        from patchers import file_originals,guest_write,cfw
        p=self.fixture.plan_fixture;self.fixture.declaration='system-systemversion-cfw-build_version'
        _,digest=guest_write.target_table()
        p.entries.append(dict(id=self.fixture.declaration,disposition='guestUncovered',recordRules=[
            dict(literal='guest-target-map-v1:'+digest+':'+self.fixture.declaration,hexadecimalOffsetSuffix=False)]))
        p.context['spoofBuild']='23Z999999';p.publish()
        os.environ.update(VPHONE_FROZEN_PLAN_SHA256=p.digest,VPHONE_FROZEN_CONTEXT=json.dumps(p.context))
        self.f.plan=p.load();catalog=self.fixture.o.catalog()
        self.directory='mnt5';self.slice='s5';self.relative='Cryptexes/OS/'+file_originals.VERSION
        self.current_root=p.mount/self.directory;target=self.current_root/self.relative;target.parent.mkdir(parents=True)
        original=plistlib.dumps({'ProductBuildVersion':'23A1','ProductVersion':'26.0'})
        target.write_bytes(original);os.chmod(target,0o640)
        logical='preboot:/'+self.relative
        self.fixture.o.root.joinpath(file_originals.VERSION).parent.mkdir(parents=True,exist_ok=True)
        source=self.fixture.o.root/file_originals.VERSION;source.write_bytes(original);os.chmod(source,0o640)
        source_entry=dict(catalog['sources'][0],profile='cryptex');catalog['sources'].append(source_entry)
        members=file_originals.capture_members(self.fixture.o.root,{logical:file_originals.VERSION},self.fixture.o.store)
        catalog['members']={logical:dict(members[logical],sourceIndex=1)};self.fixture.o.save(catalog)
        def produce():
            with patch.object(sys,'argv',['cfw.py','patch-build-version',str(target),'23Z999999']):
                with self.assertRaises(SystemExit) as result:cfw.main()
                self.assertEqual(result.exception.code,0)
            guest_write.run(self.f.plan,['chmod','0644',str(target)])
        self.fixture.produce=produce;self.commit()
        changed_size=target.stat().st_size;self.assertNotEqual(changed_size,len(original))
        preview=txn.preview_guest_undo(self.vm,self.generation,[self.fixture.declaration])
        self.assertEqual(preview['entries'][0]['verifiedCodePages'],0)
        self.prepare();self.apply();self.assertEqual(self.target.read_bytes(),original)
        self.assertEqual(effects.metadata(self.target)['mode'],0o640)
        self.seal();txn.publish(self.args)
        with contextlib.redirect_stdout(io.StringIO()):txn.finish(self.args)
        self.assertEqual(txn.inspect_guest(self.vm)['componentReceipts']['removedDeclarations'],[self.fixture.declaration])


if __name__=='__main__':unittest.main()
