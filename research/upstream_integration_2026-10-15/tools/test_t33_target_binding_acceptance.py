"""Scope, capacity and failure-stop checks without Store, disk or VM writes."""
from contextlib import ExitStack
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import execute_t33_target_binding_acceptance as runner


class FreshEXPAcceptanceTests(unittest.TestCase):
    def plan(self):
        return dict(targets=[dict(vm=str(runner.VM), variant='exp', mode='fresh-copy-and-generation',
            targets=list(runner.TARGETS), declarations=['system-systemversion-cfw-build_version'],
            installCommand=['store-cli'], firstBindingBackup='new-binding-backup')],
            candidate=dict(targetRulesSHA256=runner.RULES, bundle='candidate', version='test',
                           archive='archive.tar', archiveSHA256='a'*64, cliSHA256='b'*64),
            reuseLockedPythonRuntime=True, VMStarts=0, normalGUIBoots=0, securityWindows=0,
            automaticRetry=False, automaticRollback=False, runtimeProbeCommand=['probe'])

    def test_exact_fresh_exp_scope_is_accepted(self):
        runner.validate(self.plan())

    def test_previous_target_or_target_set_cannot_be_substituted(self):
        for update in (dict(vm=str(runner.ROOT/'.build/t33q-20261024')), dict(variant='regular'),
                       dict(mode='reuse-existing-generation'), dict(targets=['system:/other']),
                       dict(declarations=['another'])):
            with self.subTest(update=update):
                plan=self.plan();plan['targets'][0].update(update)
                with self.assertRaises(ValueError):runner.validate(plan)

    def test_old_rules_boot_window_retry_and_rollback_are_refused(self):
        for key in ('VMStarts','normalGUIBoots','securityWindows','automaticRetry','automaticRollback'):
            with self.subTest(key=key):
                plan=self.plan();plan[key]=True
                with self.assertRaises(ValueError):runner.validate(plan)
        plan=self.plan();plan['candidate']['targetRulesSHA256']='5f259f42583bb7b1f1426b986a86801fc421e17921fc157fe4a74bd596771213'
        with self.assertRaises(ValueError):runner.validate(plan)

    def test_capacity_failure_precedes_store_or_vm_mutation(self):
        with patch.object(runner.base,'approved'), \
             patch.object(runner.base,'require_capacity',side_effect=ValueError('capacity')), \
             patch.object(runner.base,'baseline') as baseline,patch.object(runner.base,'run') as run:
            with self.assertRaisesRegex(ValueError,'capacity'):runner.preflight(self.plan(),'a'*64)
            baseline.assert_not_called();run.assert_not_called()

    def execute_fixture(self,fail=False,preservation_fails=False):
        plan=self.plan();calls=[]
        with tempfile.TemporaryDirectory() as temporary,ExitStack() as stack:
            work=Path(temporary)
            stack.enter_context(patch.object(runner,'WORK',work))
            stack.enter_context(patch.object(runner.os,'geteuid',return_value=0))
            stack.enter_context(patch.object(runner,'preflight'))
            stack.enter_context(patch.object(runner,'unrelated'))
            for name in ('verify_inputs','verify_execution_inputs'):
                stack.enter_context(patch.object(runner.base,name))
            stack.enter_context(patch.object(runner.base,'runtime_environment',return_value={}))
            stack.enter_context(patch.object(runner.base,'baseline',
                side_effect=ValueError('preservation') if preservation_fails else None,return_value={'fullReadbackPassed':True}))
            stack.enter_context(patch.object(runner.base,'target_attachments',return_value=[]))
            stack.enter_context(patch.object(runner.base.evidence,'digest',return_value='b'*64))
            def run(argv,log,*_):
                calls.append(argv)
                if log.name=='runtime-probe.log':log.write_text('{"ok":true}')
            stack.enter_context(patch.object(runner.base,'run',side_effect=run))
            producer=stack.enter_context(patch.object(runner.base,'run_target',
                side_effect=RuntimeError('phase failed') if fail else None,return_value={'transition':{'passed':True}}))
            status=runner.execute(plan,'a'*64)
            result=json.loads((work/'execution/result.json').read_text())
            return status,result,producer.call_count,calls

    def test_qualified_native_result_is_still_offline_only(self):
        status,result,count,_=self.execute_fixture()
        self.assertEqual(status,0);self.assertEqual(count,1)
        self.assertEqual(result['VMStarts'],0);self.assertEqual(result['securityWindows'],0)

    def test_producer_failure_is_saved_without_retry_or_rollback(self):
        status,result,count,calls=self.execute_fixture(fail=True)
        self.assertEqual(status,1);self.assertEqual(result['state'],'failed')
        self.assertEqual(result['error'],'phase failed');self.assertEqual(count,1)
        self.assertEqual(len(calls),3)

    def test_preservation_failure_cannot_return_success(self):
        status,result,count,_=self.execute_fixture(preservation_fails=True)
        self.assertEqual(status,1);self.assertEqual(result['state'],'failed')
        self.assertIn('preservationOrCleanupError',result);self.assertEqual(count,1)


if __name__=='__main__':unittest.main()
