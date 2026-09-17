import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_f1_runtime_acceptance import RuntimeFixture  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
GENERATOR = ROOT / "scripts/f1_support_matrix.py"
PROBE = ROOT / "scripts/f1_runtime_acceptance.py"
EVIDENCE = [{"path": "steps/X/requests.jsonl", "sha256": "0" * 64}]


def step(step_id, status, finished_at="2026-09-18T01:00:00+00:00", **extra):
    record = {"id": step_id, "status": status, "finished_at": finished_at,
              "evidence": EVIDENCE if status in ("passed", "failed", "partial") else []}
    record.update(extra)
    return record


def run(run_id, steps, variant="exp", commit="a" * 40, build="23B85", options=None):
    return {
        "schema_version": 1, "run_id": run_id,
        "tool": {"git_commit": commit, "worktree_clean": True},
        "combination": {"combo_id": "P", "device": "iPhone17,3",
                        "ios": {"version": "26.1", "build": build},
                        "cloudos": {"version": "26.1", "build": "23B85"},
                        "variant": variant, "options": options or {"frida": False}},
        "steps": steps,
    }


class F1SupportMatrixTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="vphone-f1m-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

    def write(self, name, payload):
        path = self.root / name / "run.json"
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps(payload))
        return path

    def generate(self, *inputs):
        json_out, md_out = self.root / "matrix.json", self.root / "matrix.md"
        result = subprocess.run([sys.executable, str(GENERATOR), *map(str, inputs),
                                 "--json-out", str(json_out), "--md-out", str(md_out)],
                                cwd=ROOT, capture_output=True, text=True)
        if result.returncode != 0:
            return result, None, None
        return result, json.loads(json_out.read_text()), md_out.read_text()

    def test_unrun_cells_stay_not_run_and_later_not_run_does_not_override(self):
        self.write("r1", run("r1", [step("S6", "passed", "2026-09-18T01:00:00+00:00")]))
        self.write("r2", run("r2", [step("S6", "not_run", "2026-09-18T02:00:00+00:00"),
                                    step("S9", "partial", "2026-09-18T02:00:00+00:00")]))
        result, matrix, markdown = self.generate(self.root)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(matrix["rows"]), 1)
        cells = matrix["rows"][0]["cells"]
        self.assertEqual(cells["S6"]["status"], "passed")
        self.assertEqual(cells["S6"]["run_id"], "r1")
        self.assertEqual(cells["S9"]["status"], "partial")
        for column in ("S1", "S2", "S3", "S5", "S8", "S11", "S12"):
            self.assertEqual(cells[column]["status"], "not_run")
        self.assertEqual(len(cells["S6"]["history"]), 2)
        self.assertIn("| P | iPhone17,3 | 26.1/23B85 | 26.1/23B85 | exp |", markdown)

    def test_latest_verdict_wins_within_same_exact_combination(self):
        self.write("r1", run("r1", [step("S4", "partial", "2026-09-18T01:00:00+00:00")]))
        self.write("r2", run("r2", [step("S4", "passed", "2026-09-18T03:00:00+00:00")]))
        _, matrix, _ = self.generate(self.root)
        self.assertEqual(matrix["rows"][0]["cells"]["S4"]["status"], "passed")

    def test_different_builds_commits_or_variants_are_not_merged(self):
        self.write("a", run("a", [step("S6", "passed")]))
        self.write("b", run("b", [step("S6", "failed")], build="23B86"))
        self.write("c", run("c", [step("S6", "failed")], commit="b" * 40))
        self.write("d", run("d", [step("S6", "blocked")], variant="jb"))
        _, matrix, _ = self.generate(self.root)
        self.assertEqual(len(matrix["rows"]), 4)
        statuses = sorted(row["cells"]["S6"]["status"] for row in matrix["rows"])
        self.assertEqual(statuses, ["blocked", "failed", "failed", "passed"])

    def test_frida_without_messages_is_partial_and_negative_is_marked(self):
        self.write("r", run("r", [
            step("S11", "passed", observed={"client_version": "17", "server_version": "17"}),
            step("S10", "passed", expectation="absent"),
        ], options={"frida": True}))
        _, matrix, markdown = self.generate(self.root / "r" / "run.json")
        cells = matrix["rows"][0]["cells"]
        self.assertEqual(cells["S11"]["status"], "partial")
        self.assertTrue(cells["S11"]["notes"])
        self.assertEqual(cells["S10"]["expectation"], "absent")
        self.assertIn("passed (negative)", markdown)

    def test_markdown_notes_include_launch_mode_and_failure_classification(self):
        payload = run("r", [step("S7", "failed", failure={
            "stage": "app_launch", "reason": "uiopen unavailable",
            "classification": "capability_declared_but_uiopen_missing"})], variant="regular")
        payload["launch"] = {"declared_mode": "headless", "screen_available": False, "boot_mode": "normal"}
        self.write("r", payload)
        _, matrix, markdown = self.generate(self.root)
        row = matrix["rows"][0]
        self.assertEqual(row["cells"]["S7"]["classification"], "capability_declared_but_uiopen_missing")
        self.assertEqual(row["launch"][0]["declared_mode"], "headless")
        self.assertIn("failed *", markdown)
        self.assertIn("launch=headless, screen_available=False", markdown)
        self.assertIn("S7 failed classification=`capability_declared_but_uiopen_missing`", markdown)

    def test_missing_evidence_digest_or_invalid_status_is_rejected(self):
        bad = run("bad", [{"id": "S6", "status": "passed", "evidence": []}])
        path = self.write("bad", bad)
        result, matrix, _ = self.generate(path)
        self.assertEqual(result.returncode, 1)
        self.assertIn("lacks evidence digests", result.stderr)
        self.assertIsNone(matrix)
        invalid = self.write("invalid", run("invalid", [{"id": "S6", "status": "ok"}]))
        result, _, _ = self.generate(invalid)
        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid status", result.stderr)

    def test_generates_from_runtime_script_output(self):
        with tempfile.TemporaryDirectory(prefix="f1m-") as short:
            fixture = RuntimeFixture(short, "vm")
            fixture.start()
            self.addCleanup(fixture.stop)
            output = self.root / "evidence"
            result = subprocess.run([
                sys.executable, str(PROBE), "--socket", str(fixture.path), "--variant", "exp",
                "--combo", "P", "--out", str(output), "--steps", "S6,S9",
                "--ios-version", "26.1", "--ios-build", "23B85",
            ], cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        result, matrix, _ = self.generate(output / "run.json")
        self.assertEqual(result.returncode, 0, result.stderr)
        cells = matrix["rows"][0]["cells"]
        self.assertEqual(cells["S6"]["status"], "passed")
        self.assertEqual(cells["S9"]["status"], "partial")
        self.assertEqual(cells["S7"]["status"], "not_run")
        self.assertEqual(cells["S1"]["status"], "not_run")


if __name__ == "__main__":
    unittest.main()
