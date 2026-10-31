"""Generation-backed original files and signature proofs; no real mounts or VM."""
import json
import os
import plistlib
from pathlib import Path
import unittest

from tests import test_undo_provenance as fixtures
from tests.test_component_signatures import signed_macho
from patchers import file_originals as originals,component_effects as effects,undo_provenance
import cfw_disk_txn as transaction
import cfw_guest_evidence as evidence


class GuestFileOriginalTests(unittest.TestCase):
    def setUp(self):
        self.f=fixtures.UndoProvenanceTests();self.f.setUp();self.addCleanup(self.f.doCleanups)
        # The source identity is selected from the real generation-bound manifest.
        old=self.f.generation
        (self.f.original.parent/'BuildManifest.plist').write_bytes(plistlib.dumps({'BuildIdentities':[
            {'Info':{'Variant':'Customer Erase Install (IPSW)'},'Manifest':{
                'OS':{'Info':{'Path':self.f.original.name}},
                'Cryptex1,SystemOS':{'Info':{'Path':self.f.original.name}}}}]}))
        manifest=json.loads((old/'manifest.json').read_bytes())
        manifest['content']['originals'][0]['sha256']=undo_provenance.tree_digest(self.f.original.parent)
        generation=effects.canonical(manifest['content'])
        import hashlib
        generation=hashlib.sha256(generation).hexdigest();new=old.with_name(generation)
        old.rename(new);self.f.generation=new;self.f.original=new/'originals/iPhone_Restore/SystemOS.dmg'
        manifest['id']=generation;(new/'manifest.json').write_bytes(effects.canonical(manifest))
        self.f.f.record['generationID']=generation;self.f.f.context['generationID']=generation;self.f.f.publish()
        os.environ.update(VPHONE_FROZEN_PLAN_SHA256=self.f.f.digest,VPHONE_FROZEN_CONTEXT=json.dumps(self.f.f.context))
        self.f.plan=self.f.f.load()
        self.work=self.f.work;self.store=self.work/evidence.STORE;self.store.mkdir(exist_ok=True)
        self.root=self.f.mount
        self.binary=self.root/'usr/libexec/seputil';self.binary.parent.mkdir(parents=True)
        self.binary.write_bytes(signed_macho(b'original'));os.chmod(self.binary,0o755)
        self.mapping={'system:/usr/libexec/seputil':'usr/libexec/seputil'}

    def catalog(self):
        members=originals.capture_members(self.root,self.mapping,self.store)
        source=dict(profile='rootfs',source=str(self.f.original),
            generationSource=undo_provenance.qualify_source(self.f.plan,self.f.original),imageSHA256='a'*64)
        record=transaction.load_record(self.work)
        record.update(version=5,guestEvidenceRequired=True,runtimeImageEvidenceRequired=True)
        catalog=dict(schemaVersion=1,transactionID=record['id'],vmDirectory=record['vm'],
            generationID=self.f.plan.context['generationID'],planSHA256=self.f.plan.record['planSHA256'],
            desiredSHA256=self.f.plan.raw_sha256,sources=[source],
            members={target:dict(value,sourceIndex=0) for target,value in members.items()})
        self.save(catalog,record)
        return catalog

    def save(self,catalog,record=None):
        path=self.work/originals.FILENAME
        path.write_bytes(evidence.canonical(catalog))
        record=transaction.load_record(self.work) if record is None else record
        record['fileOriginalsSHA256']=evidence.digest(path);transaction.save_record(self.work,record)

    def test_original_capture_preserves_signed_bytes_and_independent_metadata(self):
        catalog=self.catalog();loaded=originals.load(self.f.plan,self.store)
        self.assertEqual(catalog,loaded)
        entry=loaded['members']['system:/usr/libexec/seputil']
        self.assertEqual(entry['verifiedCodePages'],1)
        self.assertEqual(entry['state'],effects.state(self.binary))
        self.assertEqual(effects.blob(self.store,entry['state']['sha256']).read_bytes(),self.binary.read_bytes())

    def test_original_page_damage_or_missing_signature_refuses(self):
        data=bytearray(self.binary.read_bytes());data[500]^=1;self.binary.write_bytes(data)
        with self.assertRaisesRegex(ValueError,'page hash'):self.catalog()
        self.binary.write_bytes(b'not a signed executable')
        with self.assertRaises(ValueError):self.catalog()

    def test_changed_catalog_or_original_generation_refuses(self):
        catalog=self.catalog()
        changed=json.loads(json.dumps(catalog));changed['generationID']='f'*64;self.save(changed)
        with self.assertRaisesRegex(ValueError,'qualification'):originals.load(self.f.plan,self.store)
        self.save(catalog);self.f.original.write_bytes(b'changed original')
        with self.assertRaises(ValueError):originals.load(self.f.plan,self.store)

    def test_wrong_target_kind_and_code_page_claim_refuse_even_if_file_is_rehashed(self):
        catalog=self.catalog()
        for field,value in [('kind','data'),('verifiedCodePages',999),('sourceIndex',True)]:
            changed=json.loads(json.dumps(catalog));changed['members']['system:/usr/libexec/seputil'][field]=value
            self.save(changed)
            with self.assertRaises(ValueError):originals.load(self.f.plan,self.store)

    def test_missing_catalog_stays_unqualified_and_unbound_catalog_is_rejected(self):
        self.assertIsNone(originals.load(self.f.plan,self.store))
        (self.work/originals.FILENAME).write_bytes(b'{}')
        with self.assertRaisesRegex(ValueError,'Unbound'):originals.load(self.f.plan,self.store)

    def test_metadata_is_not_inferred_from_matching_backup_content(self):
        data=self.root/'System/Library/xpc/launchd.plist';data.parent.mkdir(parents=True);data.write_bytes(b'plist')
        result=originals.capture_members(self.root,{'system:/System/Library/xpc/launchd.plist':'System/Library/xpc/launchd.plist'},self.store)
        entry=result['system:/System/Library/xpc/launchd.plist']
        self.assertEqual(entry['state']['gid'],data.stat().st_gid)
        self.assertEqual(entry['kind'],'data');self.assertEqual(entry['verifiedCodePages'],0)


if __name__=='__main__':unittest.main()
