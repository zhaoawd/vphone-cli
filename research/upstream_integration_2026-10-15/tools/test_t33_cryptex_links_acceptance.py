"""Check scope, strict transitions, and failure-stop before native execution."""
import copy
from contextlib import ExitStack
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import execute_t33_cryptex_links_acceptance as runner


class EXPContinuationTests(unittest.TestCase):
    def plan(self):
        names=['Disk.img','launchpad.json','.firmware-desired-plan.json',
               '.cfw_temp/CryptexSystemOS.dmg','.cfw_temp/.CryptexSystemOS.dmg.source.json']
        names += ['boot-'+str(i) for i in range(9)]
        return dict(targets=[dict(vm=str(runner.ROOT/'.build/t33q-20261024'),variant='exp',
            generationID=runner.GENERATION,installCommand=['install'],undoCommand=['undo'],
            targets=['system:/a','preboot:/b'])],VMStarts=0,normalGUIBoots=0,securityWindows=0,
            automaticRetry=False,automaticRollback=False,currentTargetSnapshot=dict(files=dict.fromkeys(names)))

    def test_exact_offline_scope_is_accepted(self):
        runner.validate_plan(self.plan())

    def test_changed_target_generation_or_variant_is_rejected(self):
        for update in (dict(vm='/other'),dict(variant='regular'),dict(generationID='b'*64)):
            plan=self.plan();plan['targets'][0].update(update)
            with self.subTest(update=update), self.assertRaises(ValueError):runner.validate_plan(plan)

    def test_boot_window_retry_and_rollback_cannot_be_added(self):
        for key in ('VMStarts','normalGUIBoots','securityWindows','automaticRetry','automaticRollback'):
            plan=self.plan();plan[key]=True
            with self.subTest(key=key), self.assertRaises(ValueError):runner.validate_plan(plan)

    def test_cache_and_private_desired_backup_are_required(self):
        for key in ('.firmware-desired-plan.json','.cfw_temp/CryptexSystemOS.dmg'):
            plan=self.plan();plan['currentTargetSnapshot']['files'].pop(key)
            with self.subTest(key=key), self.assertRaises(ValueError):runner.validate_plan(plan)

    def run_phases(self, *, fail=None, drift=False):
        plan=self.plan();calls=[];seen=[];originals={name:dict(state={'value':'original'}) for name in plan['targets'][0]['targets']}
        def execute(argv,*_args):
            calls.append(argv)
            if len(calls)==fail:raise RuntimeError('fixture phase failure')
        def inspect(_plan,_target,_generation,phase):
            seen.append(phase)
            value='original' if phase=='off' else ('drift' if drift and phase=='reapplied' else 'applied')
            return dict(transactionID=phase,targets={name:{'value':value} for name in originals}),originals
        with tempfile.TemporaryDirectory() as temporary,ExitStack() as stack:
            for name in ('approved','verify_execution_inputs','verify_inputs','require_capacity','verify_restored'):
                stack.enter_context(patch.object(runner.base,name))
            stack.enter_context(patch.object(runner.base,'run',side_effect=execute))
            stack.enter_context(patch.object(runner.base,'inspect_phase',side_effect=inspect))
            try:result=runner.phases(plan,Path(temporary),{},'a'*64)
            except (RuntimeError,ValueError) as error:result=error
        return result,calls,seen

    def test_all_three_phases_keep_strict_whole_file_transition(self):
        result,calls,seen=self.run_phases()
        self.assertTrue(result['transition']['passed'])
        self.assertFalse(result['transition']['runtimeValidated'])
        self.assertEqual(calls,[['install'],['undo'],['install']])
        self.assertEqual(seen,['on','off','reapplied'])

    def test_failed_phase_stops_without_retry_or_rollback(self):
        for fail in (1,2,3):
            result,calls,seen=self.run_phases(fail=fail)
            self.assertIsInstance(result,RuntimeError)
            self.assertEqual(len(calls),fail)
            self.assertEqual(len(seen),fail-1)

    def test_reapplication_drift_remains_a_failure(self):
        result,_,_=self.run_phases(drift=True)
        self.assertIsInstance(result,ValueError)
        self.assertIn('Reapplication differs',str(result))


if __name__=='__main__':unittest.main()
