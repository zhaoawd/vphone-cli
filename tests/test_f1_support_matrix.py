import hashlib
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
FRIDA_FIELDS = ("client_version", "server_version", "attach_target", "script_sha256", "messages")


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


def stage(name, status="succeeded", finished_at="2026-09-18T00:10:00Z", evidence=None, reason=None):
    record = {"stage": name, "status": status, "finished_at": finished_at, "evidence": evidence or {}}
    if reason:
        record["reason"] = reason
    return record


def create_status(bundle, variant="exp", frida=False, ios=("26.1", "23B85"), cloudos=("26.1", "23B85"),
                  patch_records="178", restore_exit="0", dfu="matched", wrapped=True, overrides=None):
    finalize = (stage("jb_finalize", "unverified", reason="runs inside the guest")
                if variant in ("jb", "exp") else stage("jb_finalize", "not_applicable"))
    stages = {
        "prepare": stage("prepare", evidence={"ios_version": ios[0], "ios_build": ios[1],
                                              "cloudos_version": cloudos[0], "cloudos_build": cloudos[1]}),
        "patch": stage("patch", evidence={"patch_records": patch_records}),
        "restore": stage("restore", evidence={"restore_update_exit": restore_exit,
                                              "post_restore_dfu_outcome": dfu}),
        "cfw": stage("cfw"),
        "first_boot": stage("first_boot", evidence={"prompt": "matched"}),
        "jb_finalize": finalize,
        "verification": stage("verification", evidence={"boot_analysis": "prompt_detected"}),
    }
    stages.update(overrides or {})
    checkpoint = {"schema_version": 1, "stages": list(stages.values()),
                  "effective_options": {"variant": variant, "enable_frida": frida},
                  "bundle_identity": {"name": Path(bundle).name, "path": str(bundle)},
                  "attempts": [{"attempt_id": "a"}], "tool": {"executable_sha256": "c" * 64}}
    if not wrapped:
        return checkpoint
    statuses = [item["status"] for item in stages.values()]
    overall = "completed_unverified" if "unverified" in statuses else "succeeded"
    return {"bundle": str(bundle), "overall_status": overall, "checkpoint": checkpoint}


def bound_run(run_id, steps, bundle, variant="exp", commit="a" * 40, launch="headless", options=None):
    payload = run(run_id, steps, variant=variant, commit=commit, options=options)
    payload["invocation"] = {"argv": ["--socket", f"{bundle}/vphone.sock", "--bundle", str(bundle)]}
    payload["launch"] = {"declared_mode": launch, "screen_available": launch == "gui", "boot_mode": "normal"}
    return payload


class F1SupportMatrixExtendedTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="vphone-f1x-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bundle = self.root / "lib" / "vm-exp"
        self.bundle.mkdir(parents=True)
        (self.root / "runs").mkdir()

    def write_json(self, relative, payload):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, ensure_ascii=False))
        return path

    def write_run(self, name, payload):
        return self.write_json(f"runs/{name}/run.json", payload)

    def manual(self, name="manual_results.json", variant="exp", combo="P", options=None, **entries):
        payload = {"vm": "vm-exp", "variant": variant, "combo": combo, "recorded_at": "2026-09-18T03:00Z"}
        if options is not None:
            payload["options"] = options
        payload.update(entries)
        return self.write_json(f"logs/manual/{name}", payload)

    def generate(self, *extra):
        json_out, md_out = self.root / "matrix.json", self.root / "matrix.md"
        result = subprocess.run([sys.executable, str(GENERATOR), str(self.root / "runs"), *map(str, extra),
                                 "--json-out", str(json_out), "--md-out", str(md_out)],
                                cwd=ROOT, capture_output=True, text=True)
        if result.returncode != 0:
            return result, None, None
        return result, json.loads(json_out.read_text()), md_out.read_text()

    def row(self, matrix, spec):
        rows = [row for row in matrix["rows"] if row.get("spec") == spec]
        self.assertEqual(len(rows), 1, [row.get("spec") for row in matrix["rows"]])
        return rows[0]

    def test_checkpoint_derives_s1_to_s3_and_binds_runs_across_commits_by_bundle(self):
        self.write_run("a", bound_run("a", [step("S4", "passed")], self.bundle))
        self.write_run("b", bound_run("b", [step("S7", "partial", "2026-09-18T02:00:00+00:00")], self.bundle,
                                      commit="b" * 40, launch="gui"))
        status = self.write_json("logs/create-status.json", create_status(self.bundle))
        log = self.root / "logs/vphone_jb_setup.log"
        log.write_text("[06:02:32] === vphone_jb_setup.sh complete ===\n")
        result, matrix, markdown = self.generate(f"--create-status=P:exp={status}", "--jb-setup-log", f"P:exp={log}")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(matrix["rows"]), 1)
        cells = self.row(matrix, "P:exp")["cells"]
        self.assertEqual((cells["S1"]["status"], cells["S1"]["source"]), ("passed", "checkpoint"))
        self.assertTrue(any("patch_records=178，与历史值一致" in note for note in cells["S1"]["notes"]))
        self.assertEqual((cells["S2"]["status"], cells["S2"]["source"]), ("passed", "checkpoint"))
        self.assertEqual((cells["S3"]["status"], cells["S3"]["source"]), ("passed", "checkpoint+manual"))
        self.assertTrue(any("jb_finalize unverified" in note for note in cells["S3"]["notes"]))
        self.assertEqual((cells["S4"]["status"], cells["S4"]["source"]), ("passed", "auto"))
        self.assertEqual(cells["S7"]["status"], "partial")
        self.assertEqual(len(self.row(matrix, "P:exp")["tool_commits"]), 2)
        self.assertIn("passed [checkpoint+manual]", markdown)
        self.assertIn("## 输入清单", markdown)
        self.assertIn(hashlib.sha256(status.read_bytes()).hexdigest(), markdown)

        result, matrix, _ = self.generate(f"--create-status=P:exp={status}")
        cells = self.row(matrix, "P:exp")["cells"]
        self.assertEqual(cells["S3"]["status"], "partial")
        self.assertTrue(any("未提供 JB 收尾日志" in note for note in cells["S3"]["notes"]))

    def test_checkpoint_mismatches_and_failures(self):
        status = self.write_json("logs/a.json", create_status(self.bundle, ios=("26.1", "23B86"), restore_exit="1"))
        _, matrix, _ = self.generate(f"--create-status=P:exp={status}")
        cells = self.row(matrix, "P:exp")["cells"]
        self.assertEqual(cells["S1"]["status"], "failed")
        self.assertTrue(any("不一致" in note for note in cells["S1"]["notes"]))
        self.assertEqual(cells["S2"]["status"], "failed")

        status = self.write_json("logs/b.json", create_status(self.bundle, patch_records="177", dfu="unknown"))
        _, matrix, _ = self.generate(f"--create-status=P:exp={status}")
        cells = self.row(matrix, "P:exp")["cells"]
        self.assertEqual(cells["S1"]["status"], "partial")
        self.assertEqual(cells["S2"]["status"], "partial")

        less = self.write_json("logs/less.json", create_status(
            self.bundle, variant="less", patch_records="26", wrapped=False,
            overrides={"cfw": stage("cfw", "not_applicable", reason="variant less installs no CFW"),
                       "verification": stage("verification", "unverified", reason="less boot has no success marker")}))
        _, matrix, _ = self.generate(f"--create-status=P:less={less}")
        cells = self.row(matrix, "P:less")["cells"]
        self.assertEqual(cells["S1"]["status"], "passed")
        self.assertTrue(any("由阶段状态推导" in note for note in cells["S1"]["notes"]))
        self.assertEqual(cells["S3"]["status"], "partial")

        failed = self.write_json("logs/c.json", create_status(
            self.bundle, overrides={"first_boot": stage("first_boot", "failed")}))
        _, matrix, _ = self.generate(f"--create-status=P:exp={failed}")
        self.assertEqual(self.row(matrix, "P:exp")["cells"]["S3"]["status"], "failed")

    def test_manual_outranks_earlier_auto_and_keeps_all_records(self):
        self.write_run("h", bound_run("h", [step("S7", "failed", "2026-09-18T01:00:00+00:00",
                                                 failure={"classification": "x", "reason": "no pid"})],
                                      self.bundle))
        self.write_run("g", bound_run("g", [step("S7", "partial", "2026-09-18T02:00:00+00:00")], self.bundle,
                                      launch="gui"))
        status = self.write_json("logs/create-status.json", create_status(self.bundle))
        manual = self.manual(S7_after_setup={"status": "partial", "run": "missing/run", "note": "launch ok"},
                             S8={"status": "blocked", "reason": "Developer Mode disabled"},
                             setup_assistant={"status": "passed"})
        _, matrix, markdown = self.generate(f"--create-status=P:exp={status}", f"--manual=P:exp={manual}")
        cells = self.row(matrix, "P:exp")["cells"]
        self.assertEqual((cells["S7"]["status"], cells["S7"]["source"]), ("partial", "manual"))
        self.assertEqual(sorted(c["source"] for c in cells["S7"]["candidates"]), ["auto", "auto", "manual"])
        self.assertEqual((cells["S8"]["status"], cells["S8"]["source"]), ("blocked", "manual"))
        self.assertTrue(any("setup_assistant" in note for note in cells["S3"]["notes"]))
        self.assertIn("partial [manual]", markdown)
        self.assertIn("auto `h`=failed", markdown)

    def test_failed_is_not_displaced_by_older_or_weaker_records(self):
        status = self.write_json("logs/create-status.json", create_status(self.bundle))
        self.write_run("late", bound_run("late", [step("S8", "failed", "2026-09-18T04:00:00+00:00"),
                                                  step("S11", "passed", "2026-09-18T01:00:00+00:00",
                                                       observed={f: "x" for f in FRIDA_FIELDS})],
                                         self.bundle))
        manual = self.manual(S8={"status": "passed"}, S11={"status": "failed"},
                             S6={"status": "passed"})
        self.write_run("early", bound_run("early", [step("S6", "failed", "2026-09-18T01:00:00+00:00")],
                                          self.bundle))
        _, matrix, markdown = self.generate(f"--create-status=P:exp={status}", f"--manual=P:exp={manual}")
        cells = self.row(matrix, "P:exp")["cells"]
        self.assertEqual((cells["S8"]["status"], cells["S8"]["source"]), ("failed", "auto"))
        self.assertTrue(any("保留 failed" in note for note in cells["S8"]["notes"]))
        self.assertEqual((cells["S11"]["status"], cells["S11"]["source"]), ("failed", "manual"))
        self.assertEqual((cells["S6"]["status"], cells["S6"]["source"]), ("passed", "manual"))
        self.assertIn("failed [auto]", markdown)

    def test_manual_subitems_and_negative_qualifier(self):
        status = self.write_json("logs/create-status.json", create_status(self.bundle))
        self.write_run("r", bound_run("r", [step("S12", "partial"), step("S6", "passed")], self.bundle))
        manual = self.manual(S12_graphics={"status": "passed"}, S10={"status": "passed (negative)"},
                             S6_listing={"status": "failed", "note": "listing wrong"})
        _, matrix, markdown = self.generate(f"--create-status=P:exp={status}", f"--manual=P:exp={manual}")
        cells = self.row(matrix, "P:exp")["cells"]
        self.assertEqual((cells["S12"]["status"], cells["S12"]["source"]), ("partial", "auto"))
        self.assertTrue(any("S12_graphics" in note for note in cells["S12"]["notes"]))
        self.assertEqual((cells["S10"]["status"], cells["S10"]["expectation"]), ("passed", "absent"))
        self.assertIn("passed (negative) [manual]", markdown)
        self.assertEqual(cells["S6"]["status"], "partial")

    def test_known_limits_open_issues_and_excluded_rows(self):
        status = self.write_json("logs/create-status.json", create_status(self.bundle))
        manual = self.manual(S8={"status": "blocked", "reason": "devmode"})
        limits = self.write_json("limits.json", {
            "schema_version": 1,
            "known_limits": [{"id": "L1", "summary": "开发者模式无法开启", "decision": "用户决定 B",
                              "applies_to": [{"spec": "P:exp", "steps": ["S8"]}],
                              "evidence": [{"path": str(manual), "detail": "S8 blocked"}]}],
            "open_issues": [{"id": "O1", "summary": "uiopen 缺失", "tracking": "单独跟踪",
                             "applies_to": [{"spec": "P:exp", "steps": ["S7"]}],
                             "evidence": [{"path": str(status)}]}],
            "excluded_combinations": [{"combo_id": "L", "variants": ["regular", "exp"], "reason": "用户决定不纳入",
                                       "evidence": [{"path": str(status)}]}],
        })
        result, matrix, markdown = self.generate(f"--create-status=P:exp={status}", f"--manual=P:exp={manual}",
                                                 "--limits", limits)
        self.assertEqual(result.returncode, 0, result.stderr)
        row = self.row(matrix, "P:exp")
        self.assertEqual(row["cells"]["S8"]["known_limits"], ["L1"])
        self.assertEqual(row["cells"]["S7"]["open_issues"], ["O1"])
        self.assertIn("blocked [manual] L1", markdown)
        self.assertIn("## 已知限制", markdown)
        self.assertIn("| L1 | 开发者模式无法开启 | P:exp S8 | 用户决定 B |", markdown)
        self.assertIn("## 未解决问题", markdown)
        self.assertIn("| O1 | uiopen 缺失 | P:exp S7 | 单独跟踪 |", markdown)
        excluded = [r for r in matrix["rows"] if r.get("excluded")]
        self.assertEqual([r["spec"] for r in excluded], ["L:regular", "L:exp"])
        self.assertTrue(all(c["status"] == "not_run" for r in excluded for c in r["cells"].values()))
        self.assertEqual(matrix["known_limits"][0]["evidence"][0]["sha256"],
                         hashlib.sha256(manual.read_bytes()).hexdigest())

    def test_invalid_extended_inputs_are_rejected(self):
        status = self.write_json("logs/create-status.json", create_status(self.bundle))
        manual = self.manual(S8={"status": "passed"})
        cases = [
            ([f"--create-status=X:exp={status}"], "unknown combination"),
            ([f"--create-status=P:exp:gpu={status}"], "unsupported options"),
            ([f"--create-status=P:jb={status}"], "does not match spec"),
            ([f"--create-status=N:exp:frida={status}"], "does not match spec"),
            ([f"--create-status=P:exp={self.root / 'absent.json'}"], "file does not exist"),
            ([f"--manual=P:dev={manual}"], "does not match spec"),
            ([f"--manual=P:exp={self.manual('bad-status.json', S8={'status': 'ok'})}"], "invalid status"),
            ([f"--manual=P:exp={self.manual('bad-key.json', notes={'status': 'passed'})}"], "unsupported key"),
            ([f"--manual=P:exp={self.manual('dup.json', S7={'status': 'failed'}, S7_after_setup={'status': 'passed'})}"],
             "duplicate manual records"),
            ([f"--manual=P:exp:frida={self.manual('opts.json')}"], "options"),
            ([f"--create-status=P:exp={status}", f"--create-status=P:exp={status}"], "given twice"),
            ([f"--jb-setup-log=P:regular={status}"], "applies only to jb/exp"),
        ]
        for extra, message in cases:
            with self.subTest(message=message, extra=extra):
                result, matrix, _ = self.generate(*extra)
                self.assertEqual(result.returncode, 1)
                self.assertIn(message, result.stderr)
                self.assertIsNone(matrix)
        mismatched = self.write_run("wrong", bound_run("wrong", [step("S6", "passed")], self.bundle, variant="jb"))
        result, _, _ = self.generate(f"--create-status=P:exp={status}")
        self.assertEqual(result.returncode, 1)
        self.assertIn("conflicts with bundle spec", result.stderr)
        mismatched.unlink()
        for name, payload, message in (
            ("no-evidence.json", {"schema_version": 1, "known_limits": [
                {"id": "L1", "summary": "s", "decision": "d", "applies_to": [{"spec": "P:exp", "steps": ["S8"]}],
                 "evidence": [{"path": str(self.root / "missing.txt")}]}], "open_issues": []},
             "evidence path does not exist"),
            ("no-row.json", {"schema_version": 1, "known_limits": [], "open_issues": [
                {"id": "O1", "summary": "s", "tracking": "t", "applies_to": [{"spec": "P:dev", "steps": ["S7"]}],
                 "evidence": [{"path": str(status)}]}]}, "has no matrix row"),
            ("bad-id.json", {"schema_version": 1, "known_limits": [
                {"id": "O1", "summary": "s", "decision": "d", "applies_to": [{"spec": "P:exp", "steps": ["S8"]}],
                 "evidence": [{"path": str(status)}]}], "open_issues": []}, "id must match L<n>"),
        ):
            limits = self.write_json(name, payload)
            with self.subTest(message=message):
                result, _, _ = self.generate(f"--create-status=P:exp={status}", "--limits", limits)
                self.assertEqual(result.returncode, 1)
                self.assertIn(message, result.stderr)


if __name__ == "__main__":
    unittest.main()
