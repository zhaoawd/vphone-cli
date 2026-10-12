"""Final output proof must preserve each required operation's effect."""
import os
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from patchers import component_effects as effects


class ComponentEffectsTests(unittest.TestCase):
    def test_disjoint_binary_effects_survive_final_readback(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); file = root/'binary'; store = root/'proofs'
            file.write_bytes(b'abcdefgh')
            before = effects.capture_input(file, store)
            file.write_bytes(b'aXcdefgh')
            first = effects.capture_change(before, file, store)
            before = effects.capture_input(file, store)
            file.write_bytes(b'aXcdefYh')
            second = effects.capture_change(before, file, store)
            effects.verify([first, second], file, store)
            file.write_bytes(b'abc defYh'.replace(b' ', b''))
            with self.assertRaises(ValueError): effects.verify([first, second], file, store)

    def test_valid_hash_chain_cannot_erase_earlier_required_effect(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); file = root/'binary'; store = root/'proofs'
            file.write_bytes(b'0000')
            before = effects.capture_input(file, store); file.write_bytes(b'0100')
            first = effects.capture_change(before, file, store)
            before = effects.capture_input(file, store); file.write_bytes(b'0200')
            second = effects.capture_change(before, file, store)
            with self.assertRaises(ValueError): effects.verify([first, second], file, store)

    def test_plist_projections_allow_reserialization_and_disjoint_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); file = root/'launchd.plist'; store = root/'proofs'
            file.write_bytes(plistlib.dumps({'Services': {'old': 1}, 'delete': True}))
            before = effects.capture_input(file, store)
            file.write_bytes(plistlib.dumps({'Services': {'old': 1, 'first': {'Enabled': True}}}))
            first = effects.capture_change(before, file, store)
            before = effects.capture_input(file, store)
            file.write_bytes(plistlib.dumps({'Services': {'old': 1, 'first': {'Enabled': True}, 'second': 2}},fmt=plistlib.FMT_BINARY))
            second = effects.capture_change(before, file, store)
            effects.verify([first, second], file, store)
            file.write_bytes(plistlib.dumps({'Services': {'old': 1, 'second': 2}}))
            with self.assertRaises(ValueError): effects.verify([first, second], file, store)

    def test_copy_baseline_permits_declared_patch_but_not_unknown_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); source=root/'source'; file=root/'target'; store=root/'proofs'
            source.write_bytes(b'original'); file.write_bytes(source.read_bytes())
            copied=effects.capture_copy(source,file,store)
            before=effects.capture_input(file,store); file.write_bytes(b'OrigiNal')
            patched=effects.capture_change(before,file,store)
            effects.verify([copied,patched],file,store)
            file.write_bytes(b'OrigiNax')
            with self.assertRaises(ValueError): effects.verify([copied,patched],file,store)

    def test_macho_loader_effect_also_preserves_nonstructural_changes(self):
        import struct
        def macho(libs, code):
            commands=b''
            for name in libs:
                raw=name.encode()+b'\0'; size=(24+len(raw)+7)//8*8
                commands+=struct.pack('<IIIIII',0x80000018,size,24,0,0,0)+raw+b'\0'*(size-24-len(raw))
            header=struct.pack('<IIIIIIII',0xfeedfacf,0x100000c,0,2,len(libs),len(commands),0,0)
            return header+commands+b'\0'*(256-len(header)-len(commands))+code
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); file=root/'launchd'; store=root/'proofs'
            file.write_bytes(macho([],b'original'))
            before=effects.capture_input(file,store);file.write_bytes(macho(['/b'],b'Original'))
            first=effects.capture_change(before,file,store)
            before=effects.capture_input(file,store);file.write_bytes(macho(['/b','/vh'],b'Original'))
            second=effects.capture_change(before,file,store)
            effects.verify([first,second],file,store)
            before=effects.capture_input(file,store);file.write_bytes(macho(['/b','/vh'],b'original'))
            reverted=effects.capture_change(before,file,store)
            with self.assertRaises(ValueError): effects.verify([first,second,reverted],file,store)

    def test_later_copy_cannot_replace_required_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); source=root/'source'; file=root/'target'; store=root/'proofs'
            source.symlink_to('/original');file.symlink_to('/original')
            first=effects.capture_copy(source,file,store)
            before=effects.state(file);source.unlink();source.symlink_to('/other')
            file.unlink();file.symlink_to('/other')
            second=effects.capture_copy(source,file,store,before=before)
            with self.assertRaises(ValueError): effects.verify([first,second],file,store)

    def test_large_file_capture_and_proof_are_streamed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); file=root/'large'; store=root/'proofs'
            with file.open('wb') as out:
                out.seek(12*1024*1024);out.write(b'end')
            before=effects.capture_input(file,store)
            with file.open('r+b') as out: out.seek(8*1024*1024);out.write(b'effect')
            proof=effects.capture_change(before,file,store)
            self.assertLess(len(str(proof)),4096)
            effects.verify([proof],file,store)

import fcntl
import json
from unittest.mock import patch
from tests import test_patch_plan_gate as fixtures
from patchers import plan_gate as gate
from patchers import guest_write
import verify_component_effects


class LessFinalEffectsTests(unittest.TestCase):
    setUp=fixtures.FrozenGateTests.setUp
    publish=fixtures.FrozenGateTests.publish
    load=fixtures.FrozenGateTests.load

    def configure_less(self):
        self.transaction=self.vm/'.firmware-transaction';self.transaction.mkdir()
        self.final_mount=self.transaction/'work/mount';self.final_mount.mkdir(parents=True)
        _,digest=guest_write.target_table()
        self.plan.update(variant='less',gates={'variant':'less','enableFrida':False,'guestEnvironmentV2':False},
            guestUncovered=[],selected=[{'id':'filesystem-less-cryptex_merge','disposition':'selected','recordRules':[
                {'literal':'filesystem.cryptex.merge','hexadecimalOffsetSuffix':False,'guestTargetRulesSHA256':digest}]}])
        self.context.update(variant='less',filesystemTransaction=str(self.transaction))
        self.publish()
        self.evidence=self.transaction/'guest-changes.jsonl'
        self.transaction_fd=os.open(self.transaction,os.O_RDONLY|os.O_DIRECTORY)
        self.addCleanup(os.close,self.transaction_fd)
        fcntl.flock(self.transaction_fd,fcntl.LOCK_EX)
        (self.transaction/'journal.json').write_bytes(gate.canonical({'plan':self.plan,'phase':'building',
            'options':{'desiredSHA256':self.digest,'generationID':self.record['generationID'],'noBinpack':'true','noVphoned':'true'}}))
        os.environ.update(VPHONE_CFW_VARIANT='less',VPHONE_FROZEN_PLAN_SHA256=self.digest,
            VPHONE_FROZEN_CONTEXT=json.dumps(self.context),VPHONE_GUEST_EVIDENCE=str(self.evidence),
            VPHONE_FIRMWARE_WORKER_FD=str(self.transaction_fd))
        self.proof=self.transaction/'filesystem-tree-proof.json'
        self.store=self.transaction/'effect-blobs'
        self.file=self.final_mount/'usr/libexec/mobileactivationd';self.file.parent.mkdir(parents=True)
        self.file.write_bytes(b'original-binary')
        before=gate.snapshot(self.file);preserved=effects.capture_input(self.file,self.store)
        self.file.write_bytes(b'Original-binary')
        proof=effects.capture_change(preserved,self.file,self.store)
        gate.append_evidence(self.load(),'filesystem-less-cryptex_merge','system:/usr/libexec/mobileactivationd',
                             self.file,before,gate.snapshot(self.file),effect=proof)

    def test_final_producer_tree_survives_safe_encode_decode_standin(self):
        self.configure_less()
        # Stand-in for the producer's later signing operation: disjoint bytes.
        self.file.write_bytes(b'Original-Binary')
        verify_component_effects.run('capture',self.final_mount,self.proof)
        final=self.transaction/'work/final-mount'
        import shutil
        shutil.copytree(self.final_mount,final,symlinks=True)
        verify_component_effects.run('verify',final,self.proof)
        (final/'usr/libexec/mobileactivationd').write_bytes(b'original-Binary')
        with self.assertRaises(ValueError): verify_component_effects.run('verify',final,self.proof)

    def test_finalizer_cannot_hide_overwritten_patch(self):
        self.configure_less()
        self.file.write_bytes(b'original-Binary')
        with self.assertRaises(ValueError): verify_component_effects.run('capture',self.final_mount,self.proof)
        self.assertFalse(self.proof.exists())

    def test_final_proof_rejects_changed_context_missing_rows_metadata_and_links(self):
        self.configure_less()
        verify_component_effects.run('capture',self.final_mount,self.proof)
        saved=self.proof.read_bytes();rows=self.evidence.read_bytes();mode=self.file.stat().st_mode & 0o777
        record=json.loads(saved);record['generationID']='other';self.proof.write_bytes(effects.canonical(record))
        with self.assertRaises(ValueError): verify_component_effects.run('verify',self.final_mount,self.proof)
        self.proof.write_bytes(saved)
        self.evidence.write_bytes(b'')
        with self.assertRaises(ValueError): verify_component_effects.run('verify',self.final_mount,self.proof)
        self.evidence.write_bytes(rows+b'\n')
        with self.assertRaises(ValueError): verify_component_effects.run('verify',self.final_mount,self.proof)
        self.evidence.write_bytes(rows)
        self.file.chmod(mode ^ 0o100)
        with self.assertRaises(ValueError): verify_component_effects.run('verify',self.final_mount,self.proof)
        self.file.chmod(mode)
        outside=self.transaction/'work/outside';outside.write_bytes(self.file.read_bytes())
        self.file.unlink();self.file.symlink_to(outside)
        with self.assertRaises((ValueError,OSError)): verify_component_effects.run('verify',self.final_mount,self.proof)


class CaptureCompatibilityTests(unittest.TestCase):
    setUp=fixtures.FrozenGateTests.setUp
    publish=fixtures.FrozenGateTests.publish
    load=fixtures.FrozenGateTests.load

    def test_unsigned_effect_then_signing_then_copy_captures_without_acceptance(self):
        target=self.mount/'mnt1/usr/libexec/seputil';target.parent.mkdir(parents=True)
        target.write_bytes(b'old-target')
        source=self.stage/'seputil';source.write_bytes(b'original-bytes')
        gate.require_write_context(self.load())
        store=self.evidence.parent/'effect-blobs'
        before=gate.snapshot(source);initial=effects.capture_input(source,store)
        source.write_bytes(b'Original-bytes')
        proof=effects.capture_change(initial,source,store)
        gate.append_evidence(self.load(),'system-seputil-boot-gigalocker_uuid','system:/usr/libexec/seputil',
                             source,before,gate.snapshot(source),effect=proof)
        # Safe stand-in for an as-yet unrecorded shell signing mutation.
        source.write_bytes(b'Original-bytes+signature')
        guest_write.run(self.load(),['cp',str(source),str(target)])
        self.assertEqual(target.read_bytes(),source.read_bytes())
        rows=[json.loads(line) for line in self.evidence.read_bytes().splitlines()]
        with self.assertRaises(ValueError): effects.verify_rows(self.load(),rows,{'system':self.mount/'mnt1'},store)

    def test_unintegrated_consumption_cannot_be_accepted_by_partial_validator(self):
        target=self.mount/'mnt1/usr/libexec/seputil';target.parent.mkdir(parents=True)
        source=self.stage/'seputil';source.write_bytes(b'copied')
        guest_write.run(self.load(),['cp',str(source),str(target)])
        guest_write.run(self.load(),['rm','-f',str(target)])
        self.assertFalse(target.exists())
        rows=[json.loads(line) for line in self.evidence.read_bytes().splitlines()]
        with self.assertRaises(ValueError): effects.verify_rows(self.load(),rows,{'system':self.mount/'mnt1'},self.evidence.parent/'effect-blobs')


class EffectsReviewRegressionTests(unittest.TestCase):
    @staticmethod
    def macho(libs, flags=0, uuid=b'\0'*16, signature=b'\0'*8):
        import struct
        commands=b''
        for name in libs:
            raw=name.encode()+b'\0';size=(24+len(raw)+7)//8*8
            commands+=struct.pack('<IIIIII',0x80000018,size,24,0,0,0)+raw+b'\0'*(size-24-len(raw))
        commands+=struct.pack('<II',0x1b,24)+uuid
        commands+=struct.pack('<IIII',0x1d,16,512,len(signature))
        header=struct.pack('<IIIIIIII',0xfeedfacf,0x100000c,0,2,len(libs)+2,len(commands),flags,0)
        return header+commands+b'\0'*(512-len(header)-len(commands))+signature

    def test_plist_scalar_types_survive_disjoint_edits_but_not_reversion(self):
        for old,new in [(1,True),(False,0),(1,1.0),(0.0,False),(-0.0,0.0),([1],[True])]:
            with self.subTest(old=old,new=new),tempfile.TemporaryDirectory() as tmp:
                path=Path(tmp)/'plist';store=Path(tmp)/'proofs'
                path.write_bytes(plistlib.dumps({'Nested':{'Enabled':old}}))
                before=effects.capture_input(path,store)
                path.write_bytes(plistlib.dumps({'Nested':{'Enabled':new}}))
                first=effects.capture_change(before,path,store)
                before=effects.capture_input(path,store)
                path.write_bytes(plistlib.dumps({'Nested':{'Enabled':new},'Other':2},fmt=plistlib.FMT_BINARY))
                second=effects.capture_change(before,path,store)
                effects.verify([first,second],path,store)
                before=effects.capture_input(path,store)
                path.write_bytes(plistlib.dumps({'Nested':{'Enabled':old},'Other':2}))
                reverted=effects.capture_change(before,path,store)
                with self.assertRaises(ValueError): effects.verify([first,second,reverted],path,store)

    def test_macho_header_load_command_and_signature_effects_cannot_be_erased(self):
        for field in ('flags','uuid','signature'):
            with self.subTest(field=field),tempfile.TemporaryDirectory() as tmp:
                path=Path(tmp)/'macho';store=Path(tmp)/'proofs'
                path.write_bytes(self.macho([]))
                before=effects.capture_input(path,store)
                changed={'flags':1} if field=='flags' else {field:b'X'+b'\0'*(15 if field=='uuid' else 7)}
                path.write_bytes(self.macho(['/b'],**changed))
                first=effects.capture_change(before,path,store)
                before=effects.capture_input(path,store)
                path.write_bytes(self.macho(['/b','/vh']))
                reverted=effects.capture_change(before,path,store)
                with self.assertRaises(ValueError): effects.verify([first,reverted],path,store)

    def test_disjoint_shifted_load_command_effects_compose(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'macho';store=Path(tmp)/'proofs'
            path.write_bytes(self.macho([]))
            before=effects.capture_input(path,store)
            path.write_bytes(self.macho(['/b'],flags=1,uuid=b'X'+b'\0'*15))
            first=effects.capture_change(before,path,store)
            before=effects.capture_input(path,store)
            path.write_bytes(self.macho(['/b','/vh'],flags=1,uuid=b'XY'+b'\0'*14))
            second=effects.capture_change(before,path,store)
            effects.verify([first,second],path,store)

    def test_unknown_operation_projection_and_missing_state_refuse(self):
        import copy
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'file';store=Path(tmp)/'proofs';path.write_bytes(b'original')
            before=effects.capture_input(path,store);path.write_bytes(b'Original')
            changed=effects.capture_change(before,path,store)
            copied=effects.capture_copy(path,path,store)
            mutations=[('operation',changed,lambda p:p.update(operation='unsupported-operation')),
                       ('copy-projection',copied,lambda p:p.update(projection={'kind':'unknown'})),
                       ('copy-extra-field',copied,lambda p:p.update(projection={'kind':'copy','unknown':True})),
                       ('copy-as-change',copied,lambda p:p.update(operation='change')),
                       ('change-as-copy',changed,lambda p:p.update(operation='copy',source=p['after'])),
                       ('missing-state',changed,lambda p:p.pop('before')),
                       ('bool-schema',changed,lambda p:p.update(schemaVersion=True))]
            for name,original,mutate in mutations:
                with self.subTest(case=name):
                    proof=copy.deepcopy(original);mutate(proof)
                    with self.assertRaises(ValueError): effects.verify([proof],path,store)

    def test_actual_insert_dylib_chain_preserves_header_and_code_effects(self):
        import struct
        import subprocess
        tool=Path(__file__).resolve().parents[1]/'.tools/bin/insert_dylib'
        if not tool.is_file(): self.skipTest('insert_dylib tool unavailable')
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'macho';store=Path(tmp)/'proofs'
            path.write_bytes(self.macho([],signature=b'signatur'))
            before=effects.capture_input(path,store)
            data=bytearray(path.read_bytes());struct.pack_into('<I',data,24,1);data[400]=42
            path.write_bytes(data)
            proofs=[effects.capture_change(before,path,store)]
            for library in ('/b','/vh'):
                before=effects.capture_input(path,store)
                result=subprocess.run([str(tool),'--weak','--inplace','--all-yes',library,str(path)],capture_output=True,text=True)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                proofs.append(effects.capture_change(before,path,store))
            effects.verify(proofs,path,store)
            self.assertEqual([entry['name'] for entry in effects.libraries(path)],['/b','/vh'])

    def test_unknown_command_bytes_and_dylib_padding_are_required(self):
        import struct
        for field in ('unknown-command','dylib-padding'):
            with self.subTest(field=field),tempfile.TemporaryDirectory() as tmp:
                path=Path(tmp)/'macho';store=Path(tmp)/'proofs'
                original=bytearray(self.macho([]));struct.pack_into('<I',original,32,0x12345678)
                path.write_bytes(original);before=effects.capture_input(path,store)
                modified=bytearray(self.macho(['/b']))
                struct.pack_into('<I',modified,64,0x12345678)
                modified[72 if field=='unknown-command' else 63]=1
                path.write_bytes(modified);first=effects.capture_change(before,path,store)
                before=effects.capture_input(path,store)
                reverted=bytearray(self.macho(['/b','/vh']));struct.pack_into('<I',reverted,96,0x12345678)
                path.write_bytes(reverted);second=effects.capture_change(before,path,store)
                with self.assertRaises(ValueError): effects.verify([first,second],path,store)

    def test_malformed_command_and_growth_into_code_refuse(self):
        import struct
        for case in ('bad-size','bad-count','bad-signature-range','truncated-area','growth-into-code'):
            with self.subTest(case=case),tempfile.TemporaryDirectory() as tmp:
                path=Path(tmp)/'macho';store=Path(tmp)/'proofs'
                beforebytes=bytearray(self.macho([]))
                if case=='growth-into-code': beforebytes[90]=42
                path.write_bytes(beforebytes);before=effects.capture_input(path,store)
                after=bytearray(self.macho(['/b']))
                if case=='bad-size': struct.pack_into('<I',after,36,7)
                if case=='bad-count': struct.pack_into('<I',after,16,4)
                if case=='bad-signature-range': struct.pack_into('<I',after,96,9999)
                if case=='truncated-area':
                    after=after[:104];struct.pack_into('<I',after,20,80);struct.pack_into('<II',after,96,0,0)
                path.write_bytes(after)
                with self.assertRaises(ValueError): effects.capture_change(before,path,store)

    def test_reordered_load_commands_cannot_lose_order_effect(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'macho';store=Path(tmp)/'proofs'
            path.write_bytes(self.macho([]));before=effects.capture_input(path,store)
            reordered=bytearray(self.macho(['/b']))
            reordered[64:104]=reordered[88:104]+reordered[64:88]
            path.write_bytes(reordered);first=effects.capture_change(before,path,store)
            before=effects.capture_input(path,store)
            path.write_bytes(self.macho(['/b','/vh']));second=effects.capture_change(before,path,store)
            with self.assertRaises(ValueError): effects.verify([first,second],path,store)

    def test_later_loader_cannot_reverse_established_dependency_order(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'macho';store=Path(tmp)/'proofs'
            path.write_bytes(self.macho(['/a']));before=effects.capture_input(path,store)
            path.write_bytes(self.macho(['/a','/b']));first=effects.capture_change(before,path,store)
            before=effects.capture_input(path,store)
            path.write_bytes(self.macho(['/b','/a','/vh']));second=effects.capture_change(before,path,store)
            with self.assertRaises(ValueError): effects.verify([first,second],path,store)
