"""Tests patch application safeguards on SYNTHETIC Git repositories, not the real app."""
from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile
import unittest

PACKAGE = Path(__file__).resolve().parents[1]


class ApplySafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="vphone-apply-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.pkg = self.root / "package"
        self.repo.mkdir(); self.pkg.mkdir()
        shutil.copy2(PACKAGE / "apply_batch1.py", self.pkg / "apply_batch1.py")
        shutil.copytree(PACKAGE / "files", self.pkg / "files")
        self.manifest = json.loads((PACKAGE / "changes.json").read_text())
        grouped = {}
        for change in self.manifest["changes"]:
            grouped.setdefault(change["path"], []).append(change["before"])
        for relative, blocks in grouped.items():
            path = self.repo / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("// SYNTHETIC application fixture; not full repository source.\n" + "\n".join(blocks))
        self.git("init", "-q")
        self.git("config", "user.name", "Patch Harness")
        self.git("config", "user.email", "patch-harness@example.invalid")
        self.git("add", ".")
        self.git("commit", "-qm", "Synthetic source fragments for application tests")
        self.manifest["base_commit"] = self.git("rev-parse", "HEAD").stdout.strip()
        self.save_manifest()

    def save_manifest(self):
        (self.pkg / "changes.json").write_text(json.dumps(self.manifest))

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], text=True,
                              capture_output=True, check=True)

    def run_apply(self, *args):
        return subprocess.run([sys.executable, str(self.pkg / "apply_batch1.py"),
                               "--repo", str(self.repo), *args], text=True, capture_output=True)

    def test_check_only_never_modifies_repository(self):
        result = self.run_apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.git("status", "--porcelain").stdout, "")

    def test_all_applies_every_reviewed_block_and_payload(self):
        result = self.run_apply("--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        for change in self.manifest["changes"]:
            text = (self.repo / change["path"]).read_text()
            self.assertIn(change["after"], text)
        for names in self.manifest["new_files"].values():
            for name in names:
                self.assertEqual((self.repo / name).read_bytes(), (self.pkg / "files" / name).read_bytes())
        self.assertEqual(self.git("diff", "--cached").stdout, "")

    def test_refuses_modified_source_without_partial_application(self):
        path = self.repo / "sources/VPhoneCore/VPhoneBundleOps.swift"
        path.write_text(path.read_text() + "// user's change\n")
        before = self.git("status", "--porcelain").stdout
        result = self.run_apply("--apply")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.git("status", "--porcelain").stdout, before)
        self.assertFalse((self.repo / "sources/VPhoneCore/VPhoneNVRAMStorage.swift").exists())

    def test_refuses_staged_changes_even_when_worktree_matches_base(self):
        path = self.repo / "sources/VPhoneCore/VPhoneBundleOps.swift"
        original = path.read_bytes()
        path.write_bytes(original + b"// staged change\n")
        self.git("add", str(path.relative_to(self.repo)))
        path.write_bytes(original)
        result = self.run_apply("--apply")
        self.assertEqual(result.returncode, 2)
        self.assertIn("staged changes", result.stderr)

    def test_unrelated_revised_documents_survive(self):
        doc = self.repo / "research/upstream_implementation_plan.md"
        doc.parent.mkdir()
        doc.write_text("User's newer 2.0.8 plan — preserve exactly.\n")
        original = doc.read_bytes()
        result = self.run_apply("--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(doc.read_bytes(), original)

    def test_stages_can_be_applied_separately(self):
        first = self.run_apply("--stage", "nvram", "--apply")
        second = self.run_apply("--stage", "clone", "--apply")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        third = self.run_apply("--stage", "clone", "--apply")
        self.assertEqual(third.returncode, 2)

    def test_refuses_symlink_new_file_and_does_not_touch_target(self):
        target = self.root / "outside"
        target.write_text("do not change")
        link = self.repo / "sources/VPhoneCore/VPhoneNVRAMStorage.swift"
        link.symlink_to(target)
        result = self.run_apply("--apply")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(target.read_text(), "do not change")
        self.assertTrue(link.is_symlink())

    def test_refuses_modified_package_payload(self):
        path = self.pkg / "files/sources/VPhoneCore/VPhoneNVRAMStorage.swift"
        path.write_text(path.read_text() + "// unexpected change\n")
        result = self.run_apply("--apply")
        self.assertEqual(result.returncode, 2)
        self.assertIn("checksum mismatch", result.stderr)
        self.assertEqual(self.git("status", "--porcelain").stdout, "")

    def test_refuses_missing_base_object(self):
        self.manifest["base_commit"] = "0" * 40
        self.save_manifest()
        result = self.run_apply("--apply")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.git("status", "--porcelain").stdout, "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
