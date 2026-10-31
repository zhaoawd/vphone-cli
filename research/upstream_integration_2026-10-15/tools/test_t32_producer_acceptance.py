"""Approval, capacity, provenance and stop-on-failure for the offline runner."""
import copy
import hashlib
import json
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import execute_t32_producer_acceptance as runner


class ProducerAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve();self.work=self.root/'work';self.work.mkdir()
        self.plan=dict(VMStarts=0,securityWindows=0,normalGUIBoots=0,automaticRetry=False,automaticRollback=False,
            minimumInitialFreeBytes=75<<30,minimumEachCFWFreeBytes=50<<30,
            candidate=dict(version='2.6.2-local.test',archiveSHA256='a'*64,cliSHA256='b'*64))
        self.target=dict(declarations=['declaration'],targets=['system:/file'])

    def test_digest_approval_and_frozen_bytes_are_all_required(self):
        tool=self.root/'tool';tool.write_bytes(b'original')
        self.plan['frozenInputs']={str(tool):hashlib.sha256(b'original').hexdigest()}
        path=self.work/'offline-plan.json';path.write_text(json.dumps(self.plan));digest=runner.evidence.digest(path)
        with patch.object(runner,'WORK',self.work),patch.object(runner,'APPROVED_SHA256',digest):
            with self.assertRaises(FileNotFoundError):runner.approved(digest)
            (self.work/'approval.json').write_text(json.dumps(dict(approved=False,planSHA256=digest)))
            with self.assertRaisesRegex(ValueError,'approval'):runner.approved(digest)
            (self.work/'approval.json').write_text(json.dumps(dict(approved=True,planSHA256=digest)))
            runner.verify_inputs(runner.approved(digest))
            tool.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError,'Frozen input'):runner.verify_inputs(self.plan)
            with self.assertRaisesRegex(ValueError,'digest'):runner.approved('0'*64)

    def test_insufficient_capacity_refuses_before_any_mutation_or_child_process(self):
        with patch.object(runner,'WORK',self.work),patch.object(runner.os,'geteuid',return_value=0), \
             patch.object(runner.os,'statvfs',return_value=SimpleNamespace(f_bavail=44<<30,f_frsize=1)), \
             patch.object(runner,'run') as child,patch.object(runner,'clone_file') as clone:
            with self.assertRaises(runner.txn.Refused):runner.execute(self.plan)
            child.assert_not_called();clone.assert_not_called()
            self.assertFalse((self.work/'execution').exists())

    def test_actual_production_capacity_policy_accepts_exact_boundary(self):
        with patch.object(runner.os,'statvfs',return_value=SimpleNamespace(f_bavail=75<<30,f_frsize=1)):
            self.assertEqual(runner.require_capacity(self.plan)['availableBytes'],75<<30)

    def test_first_binding_uses_the_original_owner_without_dropping_producer_privileges(self):
        with patch.object(runner.subprocess,'run') as child:
            runner.run(['/verified/cli','vm','bind-core-bundle'],self.work/'bind.log',{},identity=dict(uid=501,gid=20))
            self.assertEqual(child.call_args.kwargs['user'],501)
            self.assertEqual(child.call_args.kwargs['group'],20)
            self.assertEqual(child.call_args.kwargs['extra_groups'],[])
            runner.run(['/verified/cli','cfw','install'],self.work/'on.log',{})
            self.assertNotIn('user',child.call_args.kwargs)

    def test_source_receipt_binding_and_archive_must_match(self):
        binding=dict(bundle=self.plan['candidate']['version'],guestEnvironment=self.plan['candidate']['version'])
        report=dict(originQualified=True,runtimeValidated=False,componentReceipts=dict(originQualified=True,
            qualifiedProducer=dict(version=binding['bundle'],archiveSHA256='a'*64,executableSHA256='b'*64)))
        runner.verify_origin(self.plan,self.target,'on',report,binding)
        for field in ['version','archiveSHA256','executableSHA256']:
            bad=copy.deepcopy(report);bad['componentReceipts']['qualifiedProducer'][field]='different'
            with self.assertRaises(ValueError):runner.verify_origin(self.plan,self.target,'on',bad,binding)
        with self.assertRaises(ValueError):runner.verify_origin(self.plan,self.target,'on',report,dict(binding,kernel='fabricated'))
        with self.assertRaises(ValueError):runner.verify_origin(self.plan,self.target,'on',dict(report,runtimeValidated=True),binding)

    def test_undo_receipt_cannot_retain_guest_origin_or_remove_other_declarations(self):
        binding=dict(bundle=self.plan['candidate']['version'])
        report=dict(originQualified=False,runtimeValidated=False,componentReceipts=dict(removedDeclarations=['declaration']))
        runner.verify_origin(self.plan,self.target,'off',report,binding)
        with self.assertRaises(ValueError):runner.verify_origin(self.plan,self.target,'off',report,dict(binding,guestEnvironment=binding['bundle']))
        report['componentReceipts']['removedDeclarations'].append('unselected')
        with self.assertRaises(ValueError):runner.verify_origin(self.plan,self.target,'off',report,binding)

    def test_full_original_metadata_and_exact_reapplication_are_required(self):
        original=dict(kind='file',sha256='a'*64,mode=0o755,uid=0,gid=0)
        signed=dict(original,sha256='b'*64);targets=['system:/file'];catalog={targets[0]:dict(state=original)}
        first={targets[0]:signed};restored={targets[0]:original}
        self.assertTrue(runner.transition(first,restored,first,catalog,targets)['passed'])
        for bad in [{}, {targets[0]:dict(signed,sha256='c'*64)}, {targets[0]:dict(signed,mode=0o644)}]:
            with self.assertRaises(ValueError):runner.transition(first,restored,bad,catalog,targets)
        with self.assertRaises(ValueError):runner.transition(first,{targets[0]:dict(original,uid=501)},first,catalog,targets)
        with self.assertRaises(ValueError):runner.transition(restored,restored,restored,catalog,targets)

    def test_first_target_failure_preserves_partial_state_and_never_runs_second(self):
        cli=self.root/'VPhone.bundle/Contents/MacOS/vphone-cli';cli.parent.mkdir(parents=True);cli.write_bytes(b'cli')
        self.plan['candidate'].update(bundle=str(cli.parents[2]),archive=str(self.root/'candidate.tar'),cliSHA256=runner.evidence.digest(cli))
        self.plan['pythonRuntime']=dict(root=str(self.root/'runtime'),venv=str(self.root/'runtime/venv'),
            hostPython='/usr/bin/python3',provisionCommand=['<verified-host-python>','provision.py'],environment={})
        self.plan['sourceBootFiles']={'config.plist':dict(uid=os.getuid(),gid=os.getgid())}
        self.plan['targets']=[dict(variant='regular'),dict(variant='exp')]
        marker=self.root/'partial-target';marker.write_bytes(b'preserve me')
        with patch.object(runner,'WORK',self.work),patch.object(runner.os,'geteuid',return_value=0), \
             patch.object(runner,'preflight'),patch.object(runner,'verify_execution_inputs'), \
             patch.object(runner,'store_cli',return_value=cli),patch.object(runner,'run'), \
             patch.object(runner,'baseline',return_value=dict(fullReadbackPassed=True)), \
             patch.object(runner,'verify_inputs'),patch.object(runner,'target_attachments',return_value=[]), \
             patch.object(runner,'run_target',side_effect=ValueError('injected first target failure')) as target:
            self.assertEqual(runner.execute(self.plan),1)
            self.assertEqual(target.call_count,1)
        self.assertEqual(marker.read_bytes(),b'preserve me')
        result=json.loads((self.work/'execution/result.json').read_bytes())
        self.assertEqual(result['state'],'failed');self.assertEqual(result['targets'],[])
        self.assertEqual(result['VMStarts'],0);self.assertEqual(result['securityWindows'],0)


if __name__=='__main__':unittest.main()
