"""Saved-report checks; no native worker, mounted image or VM is started."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import finalize_t33_target_binding_acceptance as finalizer


class FinalizationTests(unittest.TestCase):
    def test_partial_cleanup_and_scope_changes_are_rejected(self):
        plan=dict(retirementAmendment=dict(authorizedRetirementPaths=['a','b','c','d']))
        value=dict(state='completed',amendedPlanSHA256=finalizer.PLAN,removed=['a','b','c','d'],
            sourceBaselineBefore=dict(files=10,fullReadbackPassed=True),
            sourceBaselineAfter=dict(files=10,fullReadbackPassed=True),VMStarts=0,CFWWrites=0,securityWindows=0)
        finalizer.validate_cleanup(value,plan)
        for key,changed in [('state','failed'),('removed',['a']),('VMStarts',1),
                            ('sourceBaselineAfter',dict(files=10,fullReadbackPassed=False))]:
            with self.subTest(key=key):
                bad=dict(value);bad[key]=changed
                with self.assertRaises(ValueError):finalizer.validate_cleanup(bad,plan)

    def run_reports(self,change=None):
        with tempfile.TemporaryDirectory() as temporary:
            work=Path(temporary);folder=work/'execution/exp';folder.mkdir(parents=True)
            plan=dict(targets=[dict(targets=['system:/one','system:/two'])])
            for phase in ('on','off','reapplied'):
                value=dict(generationID='generation',transactionID=phase,sourceReceipt={},binding={},
                    independentAudit=dict(passed=True,generationID='generation',transactionID=phase),
                    targets={name:{'sha256':'original' if phase=='off' else 'applied','mode':420,'uid':0,'gid':0}
                             for name in plan['targets'][0]['targets']})
                if change is not None:value=change(phase,value)
                if value is not None:(folder/(phase+'.json')).write_text(json.dumps(value))
            (folder/'transition.json').write_text(json.dumps(dict(passed=True,runtimeValidated=False,
                scope='complete file bytes and mode/uid/gid',targets=plan['targets'][0]['targets'])))
            with patch.object(finalizer,'WORK',work),patch.object(finalizer.runner.base,'verify_origin'):
                return finalizer.phases(plan,dict(state='offline-qualified-on-off-on-passed'))

    def test_three_complete_reports_are_required(self):
        self.assertEqual(set(self.run_reports()),{'on','off','reapplied'})
        with self.assertRaisesRegex(ValueError,'all three'):
            self.run_reports(lambda phase,row:None if phase=='off' else row)

    def test_byte_or_metadata_drift_does_not_finalize_success(self):
        for key,value in [('sha256','different'),('mode',384),('uid',501)]:
            def change(phase,row):
                if phase=='reapplied':row['targets']['system:/one'][key]=value
                return row
            with self.subTest(key=key),self.assertRaisesRegex(ValueError,'complete first-on'):
                self.run_reports(change)

    def test_generation_and_audit_mismatch_are_rejected(self):
        def change(phase,row):
            if phase=='off':row['independentAudit']['generationID']='other'
            return row
        with self.assertRaisesRegex(ValueError,'audit evidence'):self.run_reports(change)


if __name__=='__main__':unittest.main()
