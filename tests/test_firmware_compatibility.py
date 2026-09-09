"""Validator for research/firmware_compatibility.json (C1 compatibility manifest).

Standard library only; auto-discovered by run_tests.py
(`python -m unittest discover -s tests -p 'test_*.py'`).
"""

import json
import re
import unittest
from pathlib import Path

BUILD_RE = re.compile(r"^[0-9]{2}[A-Z][0-9A-Za-z]+$")
DATE_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
STAGE_ORDER = ["code_selectable", "patch_verified", "boot_verified", "capability_verified"]
RESULTS = {"passed", "failed", "partial"}
REQUIRED_VARIANTS = {"regular", "dev", "jb", "exp"}


def _repo_root():
    # Walk up until the manifest is found; keeps the test location-independent.
    for parent in Path(__file__).resolve().parents:
        if (parent / "research" / "firmware_compatibility.json").exists():
            return parent
    raise FileNotFoundError("research/firmware_compatibility.json not found above this test")


class FirmwareCompatibilityManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = _repo_root()
        cls.path = cls.root / "research" / "firmware_compatibility.json"
        with open(cls.path, encoding="utf-8") as f:
            cls.data = json.load(f)

    # --- top level ---

    def test_schema_version(self):
        self.assertEqual(self.data["schema_version"], 1)

    def test_open_questions_non_empty(self):
        self.assertTrue(self.data.get("open_questions"))

    def test_stage_policy_matches_order(self):
        self.assertEqual(self.data["policy"]["stages"], STAGE_ORDER)

    def test_count_semantics_present(self):
        cs = self.data["policy"]["count_semantics"]
        self.assertIn("method_count", cs)
        self.assertIn("record_count", cs)

    # --- firmware ---

    def test_firmware_builds_regex_or_null(self):
        for e in self.data["firmware"]["ios"]:
            self.assertIsNotNone(e["build"], "catalog iOS entries always carry a build")
            self.assertRegex(e["build"], BUILD_RE, f"bad iOS build {e['build']}")
        for e in self.data["firmware"]["cloudos"]:
            if e["build"] is not None:
                self.assertRegex(e["build"], BUILD_RE, f"bad cloudOS build {e['build']}")
            self.assertEqual(e["build"] is not None, e["build_known"])

    # --- combinations ---

    def test_combination_ids_unique(self):
        ids = [c["id"] for c in self.data["combinations"]]
        self.assertEqual(len(ids), len(set(ids)), "duplicate combination ids")

    def test_combination_enums_and_builds(self):
        variants = set(self.data["dimensions"]["variants"])
        option_ids = {o["id"] for o in self.data["dimensions"]["options"]}
        stages = set(self.data["policy"]["stages"])
        for c in self.data["combinations"]:
            self.assertIn(c["stage"], stages, c["id"])
            cvars = set(c.get("variants", [])) | ({c["variant"]} if "variant" in c else set())
            self.assertTrue(cvars, f"{c['id']}: needs variant or variants")
            self.assertTrue(cvars <= variants, f"{c['id']}: unknown variant in {cvars}")
            self.assertTrue(set(c.get("options", [])) <= option_ids,
                            f"{c['id']}: unknown option")
            for kind in ("ios", "cloudos"):
                b = c[kind]["build"]
                if b is not None:
                    self.assertRegex(b, BUILD_RE, f"{c['id']}: bad {kind} build {b}")
            for cap in c.get("capabilities", []):
                self.assertIn(cap["result"], RESULTS, f"{c['id']}: bad capability result")
                self.assertTrue(cap["id"], f"{c['id']}: empty capability id")

    def test_null_build_has_construct_number_limitation(self):
        for c in self.data["combinations"]:
            if c["ios"]["build"] is None or c["cloudos"]["build"] is None:
                joined = " ".join(c.get("limitations", []))
                self.assertIn("构建号", joined,
                              f"{c['id']}: null build must be flagged with a 构建号 limitation")

    def test_capability_verified_requires_capabilities(self):
        for c in self.data["combinations"]:
            if c["stage"] == "capability_verified":
                self.assertTrue(c.get("capabilities"),
                                f"{c['id']}: capability_verified needs non-empty capabilities")

    def test_boot_or_higher_requires_dated_evidence(self):
        boot_idx = STAGE_ORDER.index("boot_verified")
        for c in self.data["combinations"]:
            if STAGE_ORDER.index(c["stage"]) >= boot_idx:
                ev = c.get("evidence", [])
                self.assertTrue(ev, f"{c['id']}: {c['stage']} needs evidence")
                for e in ev:
                    self.assertRegex(e["date"], DATE_RE, f"{c['id']}: bad ISO date {e.get('date')}")

    def test_combination_versions_appear_in_firmware(self):
        ios_versions = {e["version"] for e in self.data["firmware"]["ios"]}
        cloudos_versions = {e["version"] for e in self.data["firmware"]["cloudos"]}
        for c in self.data["combinations"]:
            self.assertIn(c["ios"]["version"], ios_versions, f"{c['id']}: iOS version")
            self.assertIn(c["cloudos"]["version"], cloudos_versions, f"{c['id']}: cloudOS version")

    def test_evidence_sources_exist(self):
        for c in self.data["combinations"]:
            for e in c.get("evidence", []):
                rel = e["source"].split(":", 1)[0]
                self.assertTrue((self.root / rel).exists(),
                                f"{c['id']}: evidence source missing: {rel}")

    # --- patch configurations ---

    def test_one_patch_config_per_variant(self):
        variants = self.data["dimensions"]["variants"]
        cfg_variants = [p["variant"] for p in self.data["patch_configurations"]]
        self.assertEqual(sorted(cfg_variants), sorted(variants))
        self.assertEqual(len(cfg_variants), len(set(cfg_variants)),
                         "duplicate patch_configurations variant")

    # --- coverage rule ---

    def test_every_catalog_build_selectable_for_each_variant(self):
        catalog_builds = [e["build"] for e in self.data["firmware"]["ios"]
                          if e["source"] == "catalog"]
        self.assertTrue(catalog_builds)
        for build in catalog_builds:
            covered = set()
            for c in self.data["combinations"]:
                if c["ios"]["build"] != build:
                    continue
                cvars = set(c.get("variants", [])) | ({c["variant"]} if "variant" in c else set())
                covered |= cvars
            missing = REQUIRED_VARIANTS - covered
            self.assertFalse(missing,
                             f"catalog build {build} missing code_selectable+ combos for {missing}")


if __name__ == "__main__":
    unittest.main()
