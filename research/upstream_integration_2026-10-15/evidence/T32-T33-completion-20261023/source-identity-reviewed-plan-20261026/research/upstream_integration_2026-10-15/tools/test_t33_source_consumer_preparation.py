"""Keep future consumer preparation behind complete offline evidence and limits."""
import ast
from contextlib import ExitStack
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import prepare_t33_source_consumer_runtime as preparation


class ReceiptConsumerPreparationTests(unittest.TestCase):
    def evidence(self):
        generation = preparation.runner.GENERATION
        transactions = dict(on=preparation.current.FIRST, off=preparation.current.RECOVERY_ID, reapplied='three')
        final = dict(state='finalized', offlineAcceptancePassed=True,
            nativeState='offline-qualified-on-off-on-passed', planSHA256='a'*64,
            VMStarts=0, securityWindows=0, runtimeValidated=False, phaseTransactions=transactions,
            originalFirstOnProducer='2.6.2-local.f43043c4c559', reapplicationProducer=preparation.VERSION,
            repeatedFirstOn=0, repeatedUndoWrites=0)
        phase = dict(transactionID='three', generationID=generation,
            binding=dict(bundle=preparation.VERSION, guestEnvironment=preparation.VERSION),
            independentAudit=dict(passed=True, originQualified=False, runtimeValidated=False,
                generationID=generation, transactionID='three', currentImageSHA256='b'*64))
        candidate=dict(version=preparation.VERSION, archiveSHA256='c'*64, cliSHA256='d'*64)
        phase['sourceReceipt']=dict(state='committed-effects', originQualified=True, runtimeValidated=False,
            generationID=generation, transactionID='three', currentImageSHA256='b'*64,
            componentReceipts=dict(state='committed',originQualified=True,runtimeValidated=False,
                qualifiedProducer=dict(version=candidate['version'],archiveSHA256=candidate['archiveSHA256'],
                    executableSHA256=candidate['cliSHA256'])))
        offline = dict(targets=[dict(vm=str(preparation.runner.VM))],candidate=candidate)
        return final, phase, offline

    def test_incomplete_or_failed_offline_evidence_cannot_authorize_preparation(self):
        with patch.object(preparation.base.evidence, 'digest', return_value='a'*64):
            self.assertEqual(preparation.completed(*self.evidence()), 'b'*64)
            for key, value in [('state', 'failed'), ('offlineAcceptancePassed', False),
                ('nativeState', 'failed'), ('planSHA256', 'c'*64), ('VMStarts', 1),
                ('securityWindows', 1), ('runtimeValidated', True), ('error', 'failed')]:
                final, phase, offline = self.evidence(); final[key] = value
                with self.subTest(key=key), self.assertRaises(ValueError):
                    preparation.completed(final, phase, offline)
            final, phase, offline = self.evidence(); final['phaseTransactions']['off'] = 'one'
            with self.assertRaises(ValueError): preparation.completed(final, phase, offline)

    def test_generation_origin_and_complete_disk_digest_are_required(self):
        with patch.object(preparation.base.evidence, 'digest', return_value='a'*64):
            for key, value in [('passed', False), ('originQualified', True), ('runtimeValidated', True),
                ('generationID', 'c'*64), ('transactionID', 'different'), ('currentImageSHA256', 'sample')]:
                final, phase, offline = self.evidence(); phase['independentAudit'][key] = value
                with self.subTest(key=key), self.assertRaises(ValueError):
                    preparation.completed(final, phase, offline)

    def template(self):
        prior = json.loads((preparation.TEMPLATE/'runtime-plan.json').read_bytes())
        source = (preparation.TEMPLATE/'boot-window/scoped-amfidont.py').read_text()
        return source, prior

    def test_helper_changes_only_four_identity_constants(self):
        source, prior = self.template()
        result = preparation.scoped_helper(source, prior, Path('/new/window'), Path('/new/vm'), 'c'*64, 'd'*40)
        before = ast.parse(source); after = ast.parse(result)
        changed = []
        for old, new in zip(before.body, after.body):
            if ast.dump(old) != ast.dump(new): changed.append(old.targets[0].id)
        self.assertEqual(set(changed), {'WORK','VM','VM_SHA256','CDHASH'})
        self.assertEqual(len(before.body),len(after.body))
        self.assertIn('MAX_ATTACHMENTS = 1',result);self.assertIn('MAX_SECONDS = 900',result)
        self.assertNotIn(prior['vmExecutable'],result)
        self.assertNotIn(prior['CDHash'],result)

    def test_helper_rejects_changed_identity_or_expanded_window(self):
        source, prior = self.template()
        for changed in (source.replace('MAX_ATTACHMENTS = 1','MAX_ATTACHMENTS = 2'),
                        source.replace('MAX_SECONDS = 900','MAX_SECONDS = 901'),
                        source.replace(prior['CDHash'],'e'*40), source+'\nCDHASH = "duplicate"\n'):
            with self.assertRaises(ValueError):
                preparation.scoped_helper(changed,prior,Path('/new/window'),Path('/new/vm'),'c'*64,'d'*40)
        for key, value in [('maxSeconds',901),('maxAttachments',2),('persistentAllowlist',True),('independentSupervisor',False)]:
            source, prior = self.template(); prior['window'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                preparation.scoped_helper(source,prior,Path('/new/window'),Path('/new/vm'),'c'*64,'d'*40)

    def test_backup_has_full_content_independent_inode_and_change_rejection(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary); source=root/'source';target=root/'backup'
            source.write_bytes(b'full isolated disk fixture')
            digest=preparation.base.evidence.digest(source)
            result=preparation.backup_member(source,target,digest)
            self.assertEqual(result['sha256'],digest)
            self.assertEqual(source.read_bytes(),target.read_bytes())
            self.assertNotEqual(source.stat().st_ino,target.stat().st_ino)
            with self.assertRaises(ValueError): preparation.backup_member(source,root/'bad','a'*64)
            self.assertFalse((root/'bad').exists())

    def test_pending_native_run_creates_no_runtime_directory(self):
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
            output=Path(temporary)/'new-output'
            final,phase,offline=self.evidence();final['offlineAcceptancePassed']=False
            stack.enter_context(patch.object(preparation,'WORK',output))
            stack.enter_context(patch.object(preparation.current,'validate',return_value=offline))
            stack.enter_context(patch.object(preparation.base.evidence,'digest',return_value='a'*64))
            stack.enter_context(patch.object(preparation.base.evidence,'read',side_effect=[
                json.dumps(offline).encode(),json.dumps(final).encode(),json.dumps(phase).encode()]))
            with self.assertRaises(ValueError): preparation.prepare()
            self.assertFalse(output.exists())

    def test_origin_must_match_the_sealed_receipt_and_exact_candidate(self):
        with patch.object(preparation.base.evidence, 'digest', return_value='a'*64):
            for key,value in [('originQualified',False),('runtimeValidated',True),
                    ('generationID','wrong'),('transactionID','wrong'),('currentImageSHA256','c'*64),
                    ('state','unknown')]:
                final,phase,offline=self.evidence();phase['sourceReceipt'][key]=value
                with self.subTest(key=key),self.assertRaises(ValueError):
                    preparation.completed(final,phase,offline)
            for key,value in [('version','old'),('archiveSHA256','e'*64),('executableSHA256','f'*64)]:
                final,phase,offline=self.evidence()
                phase['sourceReceipt']['componentReceipts']['qualifiedProducer'][key]=value
                with self.subTest(key=key),self.assertRaises(ValueError):
                    preparation.completed(final,phase,offline)
            for key,value in [('state','unknown'),('originQualified',False),('runtimeValidated',True)]:
                final,phase,offline=self.evidence();phase['sourceReceipt']['componentReceipts'][key]=value
                with self.subTest(key=key),self.assertRaises(ValueError):
                    preparation.completed(final,phase,offline)

    def test_recovery_associations_cannot_be_replaced_or_repeated(self):
        with patch.object(preparation.base.evidence, 'digest', return_value='a'*64):
            for key, value in [('originalFirstOnProducer','new'), ('reapplicationProducer','old'),
                    ('repeatedFirstOn',1), ('repeatedUndoWrites',1)]:
                final,phase,offline=self.evidence();final[key]=value
                with self.subTest(key=key),self.assertRaises(ValueError):
                    preparation.completed(final,phase,offline)
            for phase_name in ('on','off'):
                final,phase,offline=self.evidence();final['phaseTransactions'][phase_name]='other'
                with self.subTest(phase=phase_name),self.assertRaises(ValueError):
                    preparation.completed(final,phase,offline)


if __name__ == '__main__':
    unittest.main()
