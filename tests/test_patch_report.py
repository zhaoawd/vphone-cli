import copy
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("patch_report", Path(__file__).resolve().parents[1] / "scripts/check_patch_report.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PatchReportTests(unittest.TestCase):
    def report(self):
        gates = {"iosBaseIs27": False}
        return {"variant": "test", "gates": gates, "ablation": [], "components": [{
            "component": "test", "coverage": "structured", "records": [{}], "results": [{
                "id": "test.Patcher.first", "requirement": "required", "outcome": "applied",
                "recordIndices": [0], "gates": gates,
            }],
        }]}

    def test_required_failure_cannot_hide_behind_success(self):
        report = self.report()
        failed = copy.deepcopy(report["components"][0]["results"][0])
        failed.update(id="test.Patcher.second", outcome="failed", recordIndices=[])
        report["components"][0]["results"].append(failed)
        self.assertTrue(module.validate(report))

    def test_optional_absence_and_verified_idempotence_are_accepted(self):
        report = self.report()
        result = report["components"][0]["results"][0]
        result.update(outcome="alreadyApplied", recordIndices=[])
        self.assertEqual(module.validate(report), [])
        result.update(requirement="optional", outcome="notApplicable")
        self.assertEqual(module.validate(report), [])
        result.update(requirement="conditional", rule="iosBaseIs27")
        self.assertEqual(module.validate(report), [])
        result["gates"]["iosBaseIs27"] = True
        self.assertTrue(module.validate(report))

    def test_incomplete_legacy_ablated_and_malformed_reports_fail(self):
        for change in (lambda r: r.update(ablation=["test"]),
                       lambda r: r.update(components=[]),
                       lambda r: r["components"][0].update(coverage="legacy"),
                       lambda r: r["components"][0].update(results=[]),
                       lambda r: r["components"][0]["results"][0].update(recordIndices=[8])):
            with self.subTest(change=change):
                report = self.report()
                change(report)
                self.assertTrue(module.validate(report))

    def test_missing_method_is_rejected_even_when_all_reported_methods_pass(self):
        report = self.report()
        manifest = {"patch_configurations": [{"variant": "test", "components": [{
            "component": "test", "methods": [{"name": "first"}, {"name": "second"}],
        }]}]}
        self.assertEqual(module.validate(report), [])
        self.assertTrue(module.validate_coverage(report, manifest))
        manifest["patch_configurations"][0]["components"][0]["methods"].pop()
        self.assertEqual(module.validate_coverage(report, manifest), [])
