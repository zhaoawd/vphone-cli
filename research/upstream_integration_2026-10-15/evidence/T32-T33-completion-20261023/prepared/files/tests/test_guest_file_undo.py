"""Use actual guarded copies, patch capture and final transport for file Undo."""
import hashlib
import json
import os
import shutil
import sys
import unittest
from unittest.mock import patch

from tests import test_guest_file_originals as fixtures
from tests.test_component_signatures import signed_macho
from patchers import file_undo,file_originals,guest_write,cfw,component_effects as effects,plan_gate as gate


class GuestFileUndoTests(unittest.TestCase):
    def setUp(self):
        self.o=fixtures.GuestFileOriginalTests();self.o.setUp();self.addCleanup(self.o.doCleanups)
        self.f=self.o.f;self.plan_fixture=self.f.f
        _,digest=guest_write.target_table()
        self.declaration='system-seputil-boot-gigalocker_uuid'
        if not any(entry['id']==self.declaration for entry in self.plan_fixture.entries):
            self.plan_fixture.entries.append(dict(id=self.declaration,disposition='guestUncovered',recordRules=[
                dict(literal='guest-target-map-v1:'+digest+':'+self.declaration,hexadecimalOffsetSuffix=False)]))
        self.plan_fixture.publish()
        os.environ.update(VPHONE_FROZEN_PLAN_SHA256=self.plan_fixture.digest,
                          VPHONE_FROZEN_CONTEXT=json.dumps(self.plan_fixture.context))
        self.f.plan=self.plan_fixture.load();self.o.catalog()
        self.target=self.plan_fixture.mount/'mnt1/usr/libexec/seputil'
        self.target.parent.mkdir(parents=True);shutil.copy2(self.o.binary,self.target)
        self.staged=self.plan_fixture.stage/'seputil'

    def produce(self,old_backup=False):
        backup=self.target.with_name('seputil.bak')
        if old_backup:backup.write_bytes(signed_macho(b'previously patched'))
        else:guest_write.run(self.f.plan,['cp',str(self.target),str(backup)])
        guest_write.run(self.f.plan,['cp',str(backup),str(self.staged)])
        def produce(*,guest_environment):
            self.assertEqual(guest_environment,self.f.plan.context['guestEnvironment'])
            self.staged.write_bytes(signed_macho(b'changed'))
        with patch.object(sys,'argv',['cfw.py','patch-seputil',str(self.staged)]),patch.object(cfw,'_dispatch',side_effect=produce):
            cfw.main()
        guest_write.run(self.f.plan,['cp',str(self.staged),str(self.target)])
        guest_write.run(self.f.plan,['chmod','0755',str(self.target)])
        rows=[json.loads(s) for s in self.plan_fixture.evidence.read_text().splitlines()]
        outputs=effects.verify_rows(self.f.plan,rows,{'system':self.plan_fixture.mount/'mnt1'},self.o.store)
        catalog=file_originals.load(self.f.plan,self.o.store)
        return rows,outputs,catalog

    def test_pristine_backup_copy_patch_final_copy_forms_a_file_undo_chain(self):
        rows,outputs,catalog=self.produce()
        entries=file_undo.build(self.f.plan,rows,outputs,self.o.store,catalog)
        self.assertEqual(len(entries),1);entry=entries[0]
        self.assertEqual(entry['target'],'system:/usr/libexec/seputil')
        self.assertEqual(entry['originalSHA256'],effects.digest(self.o.binary))
        self.assertEqual(entry['finalSHA256'],effects.digest(self.target))
        self.assertEqual(entry['operations'][0]['declarationID'],self.declaration)
        self.assertEqual(entry['operations'][0]['beforeSHA256'],entry['originalSHA256'])
        self.assertEqual(entry['auxiliaryOutputs'][0]['target'],entry['target']+'.bak')
        self.assertTrue(entry['coveredEffects'])

    def test_previously_patched_backup_cannot_create_a_first_original(self):
        rows,outputs,catalog=self.produce(old_backup=True)
        self.assertEqual(file_undo.build(self.f.plan,rows,outputs,self.o.store,catalog),[])

    def test_missing_catalog_stays_unqualified(self):
        rows,outputs,_=self.produce()
        self.assertEqual(file_undo.build(self.f.plan,rows,outputs,self.o.store,None),[])

    def test_eligibility_requires_every_declaration_on_a_file(self):
        from patchers.installed_effects import undo_eligibility
        rows,outputs,catalog=self.produce();entries=file_undo.build(self.f.plan,rows,outputs,self.o.store,catalog)
        single=undo_eligibility(rows,{'entries':entries})
        self.assertEqual(single[0]['state'],'qualified_file_restore')
        # A complete file restore also removes earlier operations, so both
        # declarations must be selected regardless of their order on the file.
        entry=entries[0];operation=dict(entry['operations'][0],declarationID='earlier')
        entry['operations'].insert(0,operation)
        rows=[dict(rows[0],declarationID='earlier')]+rows
        result=undo_eligibility(rows,{'entries':entries})
        selected=next(item for item in result if item['declarationID']==self.declaration)
        self.assertIn('earlier',selected['requiredDeclarations'])
        self.assertNotEqual(selected['state'],'qualified_file_restore')

    def test_broken_staging_chain_and_missing_implementation_refuse(self):
        rows,outputs,catalog=self.produce()
        for change in ('chain','implementation'):
            changed=json.loads(json.dumps(rows))
            row=next(r for r in changed if r['effect']['operation']=='change' and r['effect'].get('command') is None)
            if change=='chain':row['effect']['before']['sha256']='f'*64
            else:row['effect'].pop('implementation')
            with self.assertRaises(ValueError):file_undo.build(self.f.plan,changed,outputs,self.o.store,catalog)


if __name__=='__main__':unittest.main()
