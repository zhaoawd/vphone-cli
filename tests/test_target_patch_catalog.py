"""Fixed-source decisions must be complete before generated code can authorize a step."""

import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("target_catalog", ROOT / "scripts/generate_target_patch_catalog.py")
catalog = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(catalog)


class TargetPatchCatalogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vphone-target-catalog-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(ROOT / catalog.EVIDENCE, self.root / catalog.EVIDENCE)
        shutil.copyfile(ROOT / catalog.DECISIONS, self.root / catalog.DECISIONS)
        shutil.copyfile(ROOT / catalog.RESEARCH / "T09_declaration_delta.json",
                        self.root / catalog.RESEARCH / "T09_declaration_delta.json")
        self.decisions = json.loads((self.root / catalog.DECISIONS).read_text())
        for row in self.decisions["decisions"]:
            for path in row["localEvidence"]:
                target = self.root / path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.touch()

    def save(self):
        (self.root / catalog.DECISIONS).write_text(json.dumps(self.decisions))

    def test_repeated_generation_is_byte_identical_to_committed_catalog(self):
        generated = catalog.render(self.root)
        self.assertEqual(generated, catalog.render(self.root))
        self.assertEqual(generated, (ROOT / catalog.OUTPUT).read_text())

    def test_missing_target_decision_cannot_inherit_a_default(self):
        self.decisions["decisions"].pop()
        self.save()
        with self.assertRaisesRegex(ValueError, "exactly one explicit decision"):
            catalog.render(self.root)

    def test_duplicate_target_decision_is_refused(self):
        self.decisions["decisions"].append(self.decisions["decisions"][0])
        self.save()
        with self.assertRaisesRegex(ValueError, "exactly one explicit decision"):
            catalog.render(self.root)

    def test_unreviewed_target_id_is_refused(self):
        self.decisions["decisions"][0]["id"] = "kernel-cfw-unreviewed_future_patch"
        self.save()
        with self.assertRaisesRegex(ValueError, "exactly one explicit decision"):
            catalog.render(self.root)

    def test_changed_fixed_source_blob_is_refused(self):
        manifest = self.root / catalog.EVIDENCE / "fixed-target-source-manifest.json"
        content = json.loads(manifest.read_text())
        content["files"][0]["git_blob"] = "0" * 40
        manifest.write_text(json.dumps(content))
        with self.assertRaisesRegex(ValueError, "Fixed source hash mismatch"):
            catalog.render(self.root)

    def test_stale_source_applicability_is_refused(self):
        self.decisions["decisions"][0]["upstream"]["applicability"] = "unreviewed"
        self.save()
        with self.assertRaisesRegex(ValueError, "does not match fixed source"):
            catalog.render(self.root)

    def test_stale_preset_membership_is_refused(self):
        self.decisions["decisions"][0]["presets"]["standard"] = False
        self.save()
        with self.assertRaisesRegex(ValueError, "Stale fixed-target preset membership"):
            catalog.render(self.root)

    def test_incomplete_mode_or_version_matrix_is_refused(self):
        for key in ["regular", "27"]:
            with self.subTest(missing=key):
                original = json.loads((ROOT / catalog.DECISIONS).read_text())
                self.decisions = original
                matrix = self.decisions["decisions"][0]["applicability"]
                if key == "regular":
                    del matrix[key]
                else:
                    del matrix["regular"][key]
                self.save()
                with self.assertRaisesRegex(ValueError, "Incomplete variant/version decision"):
                    catalog.render(self.root)

    def test_not_implemented_decision_cannot_authorize_a_swift_step(self):
        row = next(r for r in self.decisions["decisions"] if r["id"] == "kernel-cfw-paravirt_user_clients")
        row["declaration"].update(coverage="swift", swiftSteps=["kernelcache.KernelJBPatcher.patchIoucFailedMacf"], versionRule="always")
        self.save()
        with self.assertRaisesRegex(ValueError, "Unsupported decision authorizes execution"):
            catalog.render(self.root)


if __name__ == "__main__":
    unittest.main()
