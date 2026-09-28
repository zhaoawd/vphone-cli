"""Test preflight failures before expensive Swift compilation starts."""

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "scripts/run_tests.py"


class TestRunnerTests(unittest.TestCase):
    def test_relative_fixture_path_survives_runner_changing_working_directory(self):
        spec = importlib.util.spec_from_file_location("vphone_test_runner", RUNNER)
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            for name in runner.FIRMWARE_FILES:
                target = base / "fixtures" / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(b"synthetic preflight input")
            swift = base / "swift"
            swift.write_text('#!/bin/sh\nprintf "FIXTURES=%s\\n" "$VPHONE_TEST_FIXTURES"\n')
            swift.chmod(0o755)
            result = subprocess.run(
                [sys.executable, str(RUNNER), "firmware"], cwd=base,
                env=dict(os.environ, PATH=tmp, VPHONE_TEST_FIXTURES="fixtures"),
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"FIXTURES={(base / 'fixtures').resolve()}", result.stdout)

    def test_fast_swift_does_not_inherit_firmware_acceptance_selectors(self):
        spec = importlib.util.spec_from_file_location("vphone_test_runner", RUNNER)
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        selectors = dict(VPHONE_C4_PIPELINE_VM="must-not-run",
                         VPHONE_LESS_PIPELINE_VM="must-not-run", VPHONE_TEST_VMDIR="must-not-run")
        with mock.patch.dict(os.environ, selectors), mock.patch.object(runner, "run") as run:
            runner.run_swift()
        self.assertEqual(run.call_count, 2)
        self.assertEqual(run.call_args_list[0].args[0][0], "swift")
        self.assertEqual(run.call_args_list[1].args[0][1], ROOT / "scripts/check_tar_pipe_memory.py")
        for invocation in run.call_args_list:
            for name in selectors:
                self.assertNotIn(name, invocation.kwargs["env"])

    def test_swift_failure_reaches_the_callers_exit_status(self):
        with tempfile.TemporaryDirectory() as tmp:
            swift = Path(tmp) / "swift"
            swift.write_text("#!/bin/sh\nexit 23\n")
            swift.chmod(0o755)
            result = subprocess.run(
                [sys.executable, str(RUNNER), "swift"],
                env=dict(os.environ, PATH=tmp), capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 23, result.stderr)

    def test_missing_firmware_lists_all_required_files_before_running_swift(self):
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, VPHONE_TEST_FIXTURES=tmp, PATH=tmp)
            result = subprocess.run(
                [sys.executable, str(RUNNER), "firmware"], env=env,
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("raw_payloads/ibss.bin", result.stderr)
            self.assertIn("reference_patches/kernelcache_jb.json", result.stderr)
            self.assertIn("Firmware/txm.iphoneos.research.im4p", result.stderr)
            self.assertNotIn("FileNotFoundError", result.stderr)

    def test_preflight_rejects_empty_files_and_directories(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            (base / "raw_payloads").mkdir()
            (base / "raw_payloads/ibss.bin").touch()
            (base / "raw_payloads/txm.bin").mkdir()
            result = subprocess.run(
                [sys.executable, str(RUNNER), "fixtures"],
                env=dict(os.environ, VPHONE_TEST_FIXTURES=tmp),
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("raw_payloads/ibss.bin", result.stderr)
            self.assertIn("raw_payloads/txm.bin", result.stderr)

    def test_complete_preflight_does_not_claim_firmware_tests_passed(self):
        spec = importlib.util.spec_from_file_location("vphone_test_runner", RUNNER)
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        with tempfile.TemporaryDirectory() as tmp:
            for name in runner.FIRMWARE_FILES:
                target = Path(tmp) / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(b"synthetic preflight input")
            result = subprocess.run(
                [sys.executable, str(RUNNER), "fixtures"],
                env=dict(os.environ, VPHONE_TEST_FIXTURES=tmp),
                capture_output=True, text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("not executed", result.stdout)


if __name__ == "__main__":
    unittest.main()
