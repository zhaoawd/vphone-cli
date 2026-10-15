"""Exercise DSC provenance through source mount, CFW capture and final publication."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import sys
import unittest
from unittest.mock import patch

from tests import test_patch_plan_gate as plan_tests
from tests.test_component_signatures import signed_macho
from patchers import cfw, plan_gate as gate, guest_write, cryptex_source, final_guest
from patchers import component_effects as effects, undo_provenance as undo
import cfw_disk_txn


def cache(code):
    data = bytearray(signed_macho(code)); data[:16] = b'dyld_v1 arm64e'.ljust(16,b' ')
    struct.pack_into('<QQ',data,0x28,4096,len(data)-4096)
    data[4168:4200] = hashlib.sha256(data[:4096]).digest()
    return bytes(data)


class UndoProvenanceTests(unittest.TestCase):
    def setUp(self):
        fixture = plan_tests.FrozenGateTests()
        with patch('tempfile.tempdir','/private/tmp'): fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        self.f = fixture
        _, digest = guest_write.target_table()
        for identifier in ('system-cryptex-boot-install','dyld-cfw-camera'):
            fixture.entries.append(dict(id=identifier,disposition='guestUncovered',recordRules=[
                {'literal':'guest-target-map-v1:'+digest+':'+identifier,'hexadecimalOffsetSuffix':False}]))
        self.source = fixture.vm/'iPhone_Restore/SystemOS.dmg'; self.source.parent.mkdir()
        self.source.write_bytes(b'original source image')
        content = {'identity':fixture.record['identity'], 'source':{}, 'originals':[
            {'name':'iPhone_Restore','sha256':undo.tree_digest(self.source.parent)}]}
        generation = gate.sha(gate.canonical(content))
        fixture.record['generationID'] = generation; fixture.context['generationID'] = generation
        self.generation = fixture.vm/'.firmware-generations'/generation
        self.original = self.generation/'originals/iPhone_Restore/SystemOS.dmg'
        self.original.parent.mkdir(parents=True); self.original.write_bytes(self.source.read_bytes())
        (self.generation/'manifest.json').write_bytes(gate.canonical(dict(schemaVersion=1,id=generation,content=content)))
        fixture.publish()
        os.environ.update(VPHONE_FROZEN_PLAN_SHA256=fixture.digest,VPHONE_FROZEN_CONTEXT=json.dumps(fixture.context))
        self.plan = fixture.load()
        self.work = fixture.evidence.parent
        fixture.staged_signing_transaction()
        self.image = fixture.stage/'CryptexSystemOS.dmg'
        self.mount = fixture.mount/'mnt_sysos'; self.mount.mkdir()
        self.source_dsc = self.mount/undo.DSC_MEMBER/'dyld_shared_cache_arm64e'
        self.source_dsc.parent.mkdir(parents=True); self.source_dsc.write_bytes(cache(b'initial'))
        self.target = fixture.mount/'mnt1/System/Cryptexes/OS'; self.target.mkdir(parents=True)
        self.dsc = self.target/undo.DSC_MEMBER/'dyld_shared_cache_arm64e'
        output = io.StringIO(); redir = contextlib.redirect_stdout(output)
        redir.__enter__(); self.addCleanup(redir.__exit__,None,None,None)

    def source_query(self,args):
        if args[0] == '/usr/sbin/diskutil':
            return plistlib.dumps({'ReadOnlyVolume':True,'MountPoint':str(self.mount)})
        return plistlib.dumps({'images':[{'image-path':str(self.image),
            'system-entities':[{'mount-point':str(self.mount)}]}]})

    def produce(self):
        import cache_systemos
        with patch.object(cache_systemos,'cache_systemos',side_effect=shutil.copyfile):
            cryptex_source.prepare(self.plan,'systemos',self.source,self.image)
        with patch.object(cryptex_source.subprocess,'run'), \
             patch.object(cryptex_source.subprocess,'check_output',side_effect=self.source_query):
            cryptex_source.attach(self.plan,self.image,self.mount)
        with patch.object(cryptex_source.subprocess,'check_output',side_effect=self.source_query):
            guest_write.run(self.plan,['cp','-R',str(self.mount)+'/.',str(self.target)])
        with patch.object(sys,'argv',['cfw.py','patch-camera-dsc',str(self.dsc.parent),str(self.dsc)]), \
             patch.object(cfw,'_dispatch',side_effect=lambda:self.dsc.write_bytes(cache(b'changed'))):
            cfw.main()

    def final_query(self,args):
        root = self.f.mount/'mnt1'
        if args[0] == '/usr/bin/hdiutil':
            return plistlib.dumps({'images':[{'image-path':str(self.work/'Disk.img'),
                'system-entities':[{'dev-entry':'/dev/disk41'}]}]})
        if args[1:3] == ['apfs','list']:
            return plistlib.dumps({'Containers':[{'ContainerReference':'disk42',
                'PhysicalStores':[{'DeviceIdentifier':'disk41s1'}],
                'Volumes':[{'DeviceIdentifier':'disk42s1','MountPoint':str(root)}]}]})
        return plistlib.dumps({'ReadOnlyVolume':True,'DeviceIdentifier':'disk42s1','MountPoint':str(root)})

    def finalize(self):
        # Invoke the production CLI dispatcher: final readback, index persistence,
        # proof serialization and staged-journal sealing all run normally.
        with patch.object(final_guest.subprocess,'check_output',side_effect=self.final_query), \
             patch.object(sys,'argv',['plan_gate.py','verify-final']):
            gate.main()
        return json.loads((self.work/undo.FILENAME).read_bytes())

    def test_real_producer_final_reader_and_publication_consumer(self):
        self.produce(); index = self.finalize()
        self.assertEqual(len(index['entries']),1)
        entry = index['entries'][0]
        self.assertEqual(entry['originalSHA256'],hashlib.sha256(cache(b'initial')).hexdigest())
        self.assertEqual(entry['finalSHA256'],effects.digest(self.dsc))
        self.assertEqual(entry['operations'][0]['declarationID'],'dyld-cfw-camera')
        self.assertEqual(entry['operations'][0]['beforeSHA256'],entry['originalSHA256'])
        self.assertTrue(entry['operations'][0]['ranges'])
        record = cfw_disk_txn.load_record(self.work)
        undo.verify_publication(self.work,record)
        self.assertEqual(record['undoProvenance']['indexSHA256'],effects.digest(self.work/undo.FILENAME))
        # Repeated qualification has identical content, not another first original.
        self.assertEqual(self.finalize(),index)

    def test_generation_source_mutation_refuses_final_qualification(self):
        self.produce(); self.original.write_bytes(b'mutated generation original')
        with self.assertRaisesRegex(ValueError,'manifest original tree'): self.finalize()
        self.assertFalse((self.work/undo.FILENAME).exists())

    def test_hardlinked_original_is_rejected(self):
        os.link(self.original,self.original.with_name('linked'))
        with self.assertRaises(ValueError): self.produce()
        self.assertFalse(self.dsc.exists())

    def test_writable_baseline_volume_is_rejected(self):
        import cache_systemos
        with patch.object(cache_systemos,'cache_systemos',side_effect=shutil.copyfile):
            cryptex_source.prepare(self.plan,'systemos',self.source,self.image)
        with patch.object(cryptex_source.subprocess,'run'), \
             patch.object(cryptex_source.subprocess,'check_output',return_value=plistlib.dumps(
                 {'ReadOnlyVolume':False,'MountPoint':str(self.mount)})):
            with self.assertRaisesRegex(ValueError,'readonly Cryptex'): cryptex_source.attach(self.plan,self.image,self.mount)

    def test_missing_source_observation_does_not_claim_first_original(self):
        self.produce()
        rows = self.rows()
        proof = rows[0]['sourceImageProof']
        binding = json.loads(effects.blob(self.work/'effect-blobs',proof['bindingSHA256']).read_bytes())
        binding.pop('originalDSC')
        raw = gate.canonical(binding); key = gate.sha(raw)
        (self.work/'effect-blobs'/key).write_bytes(raw); proof['bindingSHA256'] = key
        self.write_rows(rows)
        index = self.finalize()
        self.assertEqual(index['entries'],[])
        self.assertEqual(index['unqualifiedTargets'],['dsc:/dyld_shared_cache_arm64e'])

    def rows(self):
        return [json.loads(line) for line in self.f.evidence.read_bytes().splitlines()]

    def write_rows(self,rows):
        self.f.evidence.write_bytes(b''.join(gate.canonical(row)+b'\n' for row in rows))

    def test_mixed_generation_and_missing_implementation_are_rejected(self):
        self.produce(); rows = self.rows()
        for case in ('generation','implementation'):
            changed = json.loads(json.dumps(rows))
            if case == 'generation': changed[-1]['generationID'] = 'b'*64
            else: changed[-1]['effect'].pop('implementation')
            self.write_rows(changed)
            with self.assertRaises(ValueError): self.finalize()
        self.write_rows(rows)

    def test_missing_original_blob_and_replaced_final_member_are_rejected(self):
        self.produce(); rows = self.rows()
        original = effects.blob(self.work/'effect-blobs',rows[-1]['effect']['before']['sha256'])
        saved = original.read_bytes(); original.unlink()
        with self.assertRaises((ValueError,FileNotFoundError)): self.finalize()
        original.write_bytes(saved)
        self.dsc.write_bytes(cache(b'unknown'))
        with self.assertRaises(ValueError): self.finalize()

    def test_index_tamper_and_effect_truncation_refuse_before_swap(self):
        self.produce(); self.finalize()
        path = self.work/undo.FILENAME; saved = path.read_bytes()
        record = cfw_disk_txn.load_record(self.work)
        path.write_bytes(saved+b' ')
        with self.assertRaisesRegex(ValueError,'publication differs'): undo.verify_publication(self.work,record)
        path.write_bytes(saved)
        rows = self.rows(); self.write_rows(rows[:-1])
        with self.assertRaisesRegex(ValueError,'publication differs'): undo.verify_publication(self.work,record)
        self.write_rows(rows)
        record['undoProvenance']['indexSHA256'] = '0'*64
        with self.assertRaises(ValueError): undo.verify_publication(self.work,record)

    def test_environment_apply_records_effect_and_uses_required_final_proof(self):
        import cfw_env_update as environment
        from types import SimpleNamespace
        identifier = 'system-launchdaemons-boot-environment'
        _, digest = guest_write.target_table()
        self.f.plan['gates']['guestEnvironmentV2'] = True
        self.f.context['guestEnvironment'] = 'v2'; self.f.publish()
        os.environ.update(VPHONE_FROZEN_PLAN_SHA256=self.f.digest,VPHONE_FROZEN_CONTEXT=json.dumps(self.f.context))
        os.environ['VPHONE_GUEST_ENVIRONMENT'] = 'v2'
        self.plan = self.f.load()
        target = self.f.mount/'mnt1/usr/lib/libcamfix.dylib'
        target.parent.mkdir(parents=True); target.write_bytes(signed_macho(b'old'))
        source = self.f.stage/'libcamfix.dylib'; source.write_bytes(signed_macho(b'new'))
        row = dict(name='libcamfix.dylib',guest_path='/usr/lib/libcamfix.dylib',
                   actual_sha256=effects.digest(target),expected_sha256=effects.digest(source),expected_source=str(source))
        before = dict(classification='offline_update',reasons=[],replace=[row['name']],libraries=[row],activation={})
        after = dict(classification='already_current',reasons=[],libraries=[dict(row,actual_sha256=row['expected_sha256'])])
        args = SimpleNamespace(vm=str(self.f.vm),mount=str(self.f.mount/'mnt1'),components=str(self.f.stage),
                               report=str(self.work/'environment-update.json'),device='/dev/disk42s1')
        with patch.object(environment,'assess',side_effect=[before,after]), patch.object(environment,'mount_volume'):
            self.assertEqual(environment.apply(args),0)
        rows = self.rows(); self.assertEqual(rows[0]['effect']['operation'],'copy')
        self.assertEqual(rows[0]['effect']['sourcePath'],str(source))
        index = self.finalize(); self.assertEqual(index['entries'],[])
        undo.verify_publication(self.work,cfw_disk_txn.load_record(self.work))

    def test_index_validation_is_not_post_snapshot_payload_attestation(self):
        self.produce(); self.finalize()
        image = self.work/'Disk.img'; record = cfw_disk_txn.load_record(self.work)
        before = cfw_disk_txn.identity(image.stat())
        image.write_bytes(b'post-readback snapshot modification')
        self.assertNotEqual(cfw_disk_txn.identity(image.stat()),before)
        self.assertEqual(image.stat().st_ino,before['ino'])
        # Scope evidence: index validation still validates the prior observed
        # preimage/effect chain. No post-snapshot final payload claim is made.
        undo.verify_publication(self.work,record)
        self.assertEqual(json.loads((self.work/undo.FILENAME).read_bytes())['state'],
                         'qualified-preimages-not-migration-authority')

    def test_another_vm_cannot_use_a_self_consistent_proof_and_index(self):
        self.produce(); self.finalize()
        other_vm = self.f.vm.parent/'other-vm'; other_vm.mkdir()
        other_work = other_vm/self.work.name; shutil.copytree(self.work,other_work)
        record = cfw_disk_txn.load_record(other_work)
        record['vm'] = str(other_vm); record['staged'] = cfw_disk_txn.identity((other_work/'Disk.img').stat())
        proof_path = other_work/'guest-effects-final.json'; proof = json.loads(proof_path.read_bytes())
        proof['stagedImage'] = str(other_work/'Disk.img'); proof['stagedIdentity'] = record['staged']
        proof_path.write_bytes(gate.canonical(proof)); record['undoProvenance']['finalProofSHA256'] = effects.digest(proof_path)
        with self.assertRaisesRegex(ValueError,'another VM'):
            undo.verify_publication(other_work,record)

    def test_deleting_index_and_anchor_cannot_downgrade_publication(self):
        self.produce(); self.finalize()
        record = cfw_disk_txn.load_record(self.work)
        record.pop('undoProvenance'); (self.work/undo.FILENAME).unlink()
        with self.assertRaisesRegex(ValueError,'no staged journal binding'):
            undo.verify_publication(self.work,record)
        # Even deleting all three does not turn a required transaction into legacy.
        (self.work/'guest-effects-final.json').unlink()
        with self.assertRaises(ValueError): undo.verify_publication(self.work,record)
        for version, mode in ((1,None),(2,None),(2,'environment-only')):
            record['version'] = version; record['provenanceMode'] = mode
            with self.assertRaisesRegex(ValueError,'recovery only'):
                undo.verify_publication(self.work,record)

    def test_final_reader_rechecks_state_after_index_persistence(self):
        self.produce()
        actual = undo.persist
        for subject in ('image','rows','manifest'):
            path = {'image':self.work/'Disk.img','rows':self.f.evidence,
                    'manifest':self.generation/'manifest.json'}[subject]
            saved = path.read_bytes()
            def mutate(*args):
                result = actual(*args); path.write_bytes(saved+b' '); return result
            with patch.object(undo,'persist',side_effect=mutate):
                with self.assertRaises(ValueError): self.finalize()
            self.assertFalse((self.work/'guest-effects-final.json').exists())
            path.write_bytes(saved)

    def test_wrong_source_mount_does_not_leave_baseline_marker(self):
        import cache_systemos
        with patch.object(cache_systemos,'cache_systemos',side_effect=shutil.copyfile):
            cryptex_source.prepare(self.plan,'systemos',self.source,self.image)
        def query(args):
            if args[0] == '/usr/bin/hdiutil': return plistlib.dumps({'images':[]})
            return self.source_query(args)
        with patch.object(cryptex_source.subprocess,'run'), \
             patch.object(cryptex_source.subprocess,'check_output',side_effect=query):
            with self.assertRaisesRegex(ValueError,'not the bound image'):
                cryptex_source.attach(self.plan,self.image,self.mount)
        self.assertNotIn('originalDSC',json.loads(cryptex_source.marker(self.image).read_bytes()))

    def test_publish_calls_consumer_before_swapping_disk(self):
        self.produce(); self.finalize()
        path = self.work/undo.FILENAME; path.write_bytes(path.read_bytes()+b' ')
        from types import SimpleNamespace
        args = SimpleNamespace(vm=self.f.vm,work=self.work,fd=-1,owner_pid=os.getpid())
        with patch.object(cfw_disk_txn,'run_checks'), patch.object(cfw_disk_txn,'swap_files') as swap:
            with self.assertRaisesRegex(cfw_disk_txn.Refused,'Undo provenance publication refused'):
                cfw_disk_txn.publish(args)
            swap.assert_not_called()


if __name__ == '__main__': unittest.main()
