import base64
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from test_f2_dual_vm_acceptance import HostControlFixture  # noqa: E402

import f3_benchmark  # noqa: E402
import host_control_client  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / "scripts/f3_benchmark.py"
GUEST_DIR = "/var/mobile/Library/f3-bench/"


class BenchFixture(HostControlFixture):
    """Fake host-control socket with the commands the F3 driver sends."""

    def __init__(self, directory, name="vm", *, screen=True, fail_commands=(),
                 fail_code="guest_error", location_generation="loc-1", down_cycles=0,
                 shell_available=True, stat_output=None):
        super().__init__(directory, name)
        self.screen = screen
        self.shell_available = shell_available
        self.stat_output = stat_output
        self.log_size = 4096
        self.stat_requests = []
        self.fail_commands = set(fail_commands)
        self.fail_code = fail_code
        self.location_generation = location_generation
        self.location_state = "off"
        self.down_cycles = down_cycles
        self.down_remaining = 0
        self.frame_index = 0

    def types(self):
        return [request["t"] for request in self.requests]

    def _handle(self, request):
        command = request["t"]
        if command in self.fail_commands:
            return {"ok": False, "error": "injected failure", "code": self.fail_code}
        if command == "capabilities":
            connected = self.down_remaining <= 0
            if not connected:
                self.down_remaining -= 1
            return {
                "ok": True, "protocol_version": 1, "boot_mode": "normal",
                "guest_connected": connected,
                "guest_capabilities": ["file", "apps", "location_owned", "shell", "touch"],
                "screen_available": self.screen,
                "limits": {"command_timeout_ms": 180000},
                "commands": {
                    "capabilities": True, "file_get": True, "file_put": True,
                    "shell": self.shell_available,
                    "app_launch": True, "app_terminate": True, "app_list": True,
                    "location_source_set": True, "location_source_stop": True,
                    "location_source_status": True,
                    "screenshot": self.screen, "tap": self.screen, "swipe": self.screen,
                    "camera_present": True, "camera_status": True, "camera_stop": True,
                },
            }
        if command == "file_put" and "load" in request:
            data = Path(request["load"]).read_bytes()
            self.files[request["path"]] = data
            return {"ok": True, "size": len(data)}
        if command == "file_get":
            if request["path"] not in self.files:
                return {"ok": False, "error": "open failed: No such file or directory",
                        "code": "guest_error"}
            data = self.files[request["path"]]
            if "save" in request:
                Path(request["save"]).write_bytes(data)
                return {"ok": True, "path": request["save"], "size": len(data)}
            return {"ok": True, "size": len(data), "data": base64.b64encode(data).decode()}
        if command == "screenshot":
            Path(request["path"]).write_bytes(b"png")
            return {"ok": True, "path": request["path"]}
        if command in ("tap", "swipe", "key"):
            return {"ok": True}
        if command == "shell":
            shell_command = request.get("cmd", "")
            if "vphoned" in shell_command:
                self.down_remaining = self.down_cycles
            if "stat -f %z" in shell_command:
                self.stat_requests.append(shell_command)
                if self.stat_output is not None:
                    return dict({"ok": True, "stdout": "", "stderr": "", "code": 0},
                                **self.stat_output)
                self.log_size += 1024
                return {"ok": True, "stdout": f"{self.log_size}\n", "stderr": "", "code": 0}
            return {"ok": True, "stdout": "", "stderr": "", "code": 0}
        if command == "location_source_status":
            return {"ok": True, "state": self.location_state, "generation": None}
        if command == "location_source_set":
            self.location_state = "running"
            return {"ok": True, "state": "running", "generation": self.location_generation}
        if command == "location_source_stop":
            self.location_state = "off"
            return {"ok": True, "state": "off", "generation": None}
        response = super()._handle(request)
        if command == "camera_status" and response.get("streaming"):
            self.frame_index += 16
            response["host_scheduled_frame_index"] = self.frame_index
            receipt = response.get("transport_receipt")
            if isinstance(receipt, dict):
                published = time.monotonic_ns()
                receipt.update({"vphoned_published_frame_index": self.frame_index,
                                "libvcam_observed_frame_index": self.frame_index,
                                "vphoned_published_at_ns": published,
                                "libvcam_observed_at_ns": published + 2_000_000})
        return response


class DriverTestCase(unittest.TestCase):
    """Shared fixture and subprocess helpers; holds no tests of its own."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="vphone-f3-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def fixture(self, directory=None, **options):
        fixture = BenchFixture(directory or self.root, **options)
        fixture.start()
        self.addCleanup(fixture.stop)
        return fixture

    def run_probe(self, *arguments, expect=None):
        result = subprocess.run([sys.executable, "-B", str(PROBE), *[str(item) for item in arguments]],
                                cwd=ROOT, capture_output=True, text=True)
        if expect is not None:
            self.assertEqual(result.returncode, expect, result.stderr + result.stdout)
        return result


class F3SafetyTests(DriverTestCase):
    def test_socket_inside_vm_2607_is_refused_before_any_request(self):
        bundle = self.root / "vm-2607"
        bundle.mkdir()
        fixture = self.fixture(bundle, name="vphone")
        result = self.run_probe("latency", "--sock", fixture.path, "--out", self.root / "out",
                                "--samples", 1, expect=2)
        self.assertIn("vm-2607", result.stderr)
        self.assertEqual(fixture.requests, [])
        self.assertFalse((self.root / "out").exists())

    def test_existing_output_directory_is_refused(self):
        fixture = self.fixture()
        (self.root / "out").mkdir()
        result = self.run_probe("latency", "--sock", fixture.path, "--out", self.root / "out",
                                "--samples", 1, expect=2)
        self.assertIn("already exists", result.stderr)
        self.assertEqual(fixture.requests, [])

    def test_guest_directory_outside_the_benchmark_prefix_is_refused(self):
        fixture = self.fixture()
        for candidate in ("/var/mobile/Library/other/", "/var/mobile/Library/f3-bench/../evil/",
                          "/tmp/f3-bench/"):
            result = self.run_probe("latency", "--sock", fixture.path,
                                    "--out", self.root / f"out{abs(hash(candidate))}",
                                    "--guest-dir", candidate, "--samples", 1, expect=2)
            self.assertIn("/var/mobile/Library/f3-bench/", result.stderr)
        self.assertEqual(fixture.requests, [])

    def test_recovery_boot_requires_the_vm_lifecycle_flag(self):
        fixture = self.fixture()
        result = self.run_probe("recovery-boot", "--sock", fixture.path,
                                "--out", self.root / "out",
                                "--launch-command", "/usr/bin/true", expect=2)
        self.assertIn("--allow-vm-lifecycle", result.stderr)
        self.assertFalse((self.root / "out").exists())
        self.assertEqual(fixture.requests, [])

    def test_guest_file_helper_rejects_escapes(self):
        self.assertEqual(f3_benchmark.guest_file(GUEST_DIR, "a.bin"),
                         "/var/mobile/Library/f3-bench/a.bin")
        with self.assertRaises(f3_benchmark.BenchmarkError):
            f3_benchmark.guest_file(GUEST_DIR, "../escape.bin")
        with self.assertRaises(f3_benchmark.BenchmarkError):
            f3_benchmark.guest_file(GUEST_DIR, "/etc/passwd")


class F3LatencyTests(DriverTestCase):
    def latency(self, fixture, *extra, out="out", commands="capabilities,app_list:running",
                samples=3, warmup=1, expect=0):
        output = self.root / out
        result = self.run_probe("latency", "--sock", fixture.path, "--out", output,
                                "--commands", commands, "--samples", samples,
                                "--warmup", warmup, "--timeout", 5, *extra, expect=expect)
        run = json.loads((output / "run.json").read_text())
        samples_path = output / "samples" / "latency.jsonl"
        records = [json.loads(line) for line in samples_path.read_text().splitlines()]
        return result, run, records, output

    def test_latency_writes_run_json_and_complete_sample_records(self):
        fixture = self.fixture()
        _, run, records, output = self.latency(fixture, "--note", "unit test")
        self.assertEqual(run["experiment"], "latency")
        self.assertEqual(run["schema_version"], 1)
        self.assertEqual(run["note"], "unit test")
        self.assertIsNotNone(run["host"])
        self.assertIn("commit", run["git"])
        self.assertEqual(run["seed"], 20260918)
        self.assertEqual(run["capabilities"]["guest_connected"], True)
        self.assertEqual(run["counts"]["requests"], len(records))
        measured = [record for record in records if record["phase"] == "measure"]
        self.assertEqual(len(measured), 6)
        for record in measured:
            for key in ("seq", "class", "command", "params", "ok", "code", "error",
                        "response_bytes", "started_utc", "t_start_ns", "t_connect_ns",
                        "t_send_ns", "t_total_ns"):
                self.assertIn(key, record)
            self.assertTrue(record["ok"])
            self.assertGreaterEqual(record["t_total_ns"], record["t_send_ns"])
            self.assertGreaterEqual(record["t_send_ns"], record["t_connect_ns"])
            self.assertGreater(record["response_bytes"], 0)
        self.assertEqual({record["class"] for record in measured},
                         {"capabilities", "app_list:running"})
        self.assertEqual(len([r for r in records if r["phase"] == "warmup"]), 2)

    def test_latency_samples_never_contain_base64_payloads(self):
        fixture = self.fixture()
        _, run, records, output = self.latency(
            fixture, commands="file_put:1k,file_get:1k", samples=2, warmup=0)
        text = (output / "samples" / "latency.jsonl").read_text()
        self.assertNotIn("data_b64", text)
        self.assertNotIn(base64.b64encode(f3_benchmark.payload_bytes(run["seed"], 1024))
                         .decode()[:24], text)
        file_records = [record for record in records if record["class"].startswith("file_")]
        self.assertTrue(all(set(record["params"]) <= {"path", "bytes", "sha256", "mode"}
                            for record in file_records))
        self.assertTrue(all(record["params"]["path"].startswith(GUEST_DIR)
                            for record in file_records))
        self.assertTrue(all(record["ok"] for record in file_records))

    def test_latency_counts_failures_by_code_and_keeps_going(self):
        fixture = self.fixture(fail_commands=("app_list",), fail_code="guest_error")
        _, run, records, _ = self.latency(fixture, samples=4, warmup=0)
        self.assertEqual(run["counts"]["failures_by_code"], {"guest_error": 4})
        failed = [record for record in records if record["ok"] is False]
        self.assertEqual(len(failed), 4)
        self.assertTrue(all(record["code"] == "guest_error" for record in failed))
        self.assertTrue(all(record["error"] == "injected failure" for record in failed))
        self.assertEqual(len([r for r in records if r["class"] == "capabilities"
                              and r["phase"] == "measure"]), 4)

    def test_latency_aborts_after_too_many_consecutive_failures(self):
        fixture = self.fixture(fail_commands=("app_list",))
        output = self.root / "abort"
        result = self.run_probe("latency", "--sock", fixture.path, "--out", output,
                                "--commands", "app_list:running", "--samples", 10,
                                "--warmup", 0, "--max-consecutive-failures", 2, expect=1)
        run = json.loads((output / "run.json").read_text())
        self.assertIn("consecutive failed requests", run["aborted"])
        self.assertIn("aborted", result.stderr)

    def test_latency_skips_unavailable_commands_with_a_recorded_reason(self):
        fixture = self.fixture(screen=False)
        _, run, records, _ = self.latency(
            fixture, commands="capabilities,screenshot:gray,shell", out="skip", samples=2, warmup=0)
        self.assertIn("screenshot:gray", run["counts"]["skipped"])
        self.assertIn("screenshot", run["counts"]["skipped"]["screenshot:gray"])
        self.assertNotIn("screenshot", fixture.types())
        self.assertEqual({record["class"] for record in records if record["phase"] == "measure"},
                         {"capabilities", "shell"})

    def test_screen_dependent_class_is_skipped_when_the_command_exists_without_a_window(self):
        item = f3_benchmark.CommandClass("screenshot:gray", 1, lambda index, worker: None,
                                         commands=("screenshot",), needs_screen=True)
        available = {"commands": {"screenshot": True}, "screen_available": False,
                     "guest_capabilities": ["file"]}
        self.assertIn("screen_available", item.skip_reason(available))
        self.assertIsNone(item.skip_reason({**available, "screen_available": True}))
        missing = {"commands": {"screenshot": False}, "screen_available": True,
                   "guest_capabilities": ["file"]}
        self.assertIn("unavailable", item.skip_reason(missing))

    def test_capability_skip_reason_names_the_missing_guest_capability(self):
        item = f3_benchmark.CommandClass("shell", 1, lambda index, worker: None,
                                         commands=("shell",), capability="shell")
        reason = item.skip_reason({"commands": {"shell": False}, "guest_capabilities": ["file"]})
        self.assertIn("'shell'", reason)
        self.assertIn("does not declare", reason)

    def test_same_seed_reproduces_the_command_order(self):
        first = self.fixture(name="a")
        second = self.fixture(name="b")
        _, _, left, _ = self.latency(first, out="seed-a", samples=6, warmup=0)
        _, _, right, _ = self.latency(second, out="seed-b", samples=6, warmup=0)
        order = lambda records: [record["class"] for record in records
                                 if record["phase"] == "measure"]
        self.assertEqual(order(left), order(right))
        self.assertGreater(len(set(order(left))), 1)
        third = self.fixture(name="c")
        _, _, other, _ = self.latency(third, "--seed", "7", out="seed-c", samples=6, warmup=0)
        self.assertEqual(sorted(order(other)), sorted(order(left)))

    def test_concurrent_latency_runs_the_full_schedule(self):
        fixture = self.fixture()
        _, run, records, _ = self.latency(fixture, "--concurrency", "3", out="concurrent",
                                          samples=5, warmup=1)
        measured = [record for record in records if record["phase"] == "measure"]
        self.assertEqual(len(measured), 10)
        self.assertEqual(len({record["seq"] for record in measured}), 10)
        self.assertEqual(run["counts"]["failures_by_code"], {})
        self.assertEqual(run["parameters"]["concurrency"], 3)

    def gesture_args(self, *extra):
        return f3_benchmark.parse_args(["latency", "--sock", str(self.root / "s"),
                                        "--out", str(self.root / "o"), *extra])

    def test_swipe_spacing_follows_the_configured_swipe_duration(self):
        args = self.gesture_args()
        tap, swipe = f3_benchmark.resolve_gesture_spacing(args)
        self.assertAlmostEqual(tap, 0.100)
        self.assertAlmostEqual(swipe, 0.350)
        self.assertEqual(args.swipe_ms, 300)
        self.assertEqual(args.swipe_spacing_ms, 350)
        longer = self.gesture_args("--swipe-ms", "500")
        self.assertAlmostEqual(f3_benchmark.resolve_gesture_spacing(longer)[1], 0.550)
        self.assertEqual(longer.swipe_spacing_ms, 550)
        explicit = self.gesture_args("--swipe-ms", "500", "--swipe-spacing-ms", "120")
        self.assertAlmostEqual(f3_benchmark.resolve_gesture_spacing(explicit)[1], 0.120)

    def test_gesture_pacing_stays_outside_the_recorded_latency(self):
        fixture = self.fixture()
        spacing_ns = 150 * 1_000_000
        _, run, records, _ = self.latency(
            fixture, "--tap-spacing-ms", "150", "--swipe-ms", "100",
            commands="tap:noscreen,swipe:noscreen", out="pacing", samples=3, warmup=1)
        # The derived swipe spacing and the tap spacing are both recorded.
        self.assertEqual(run["parameters"]["tap_spacing_ms"], 150)
        self.assertEqual(run["parameters"]["swipe_spacing_ms"], 150)
        measured = sorted((record for record in records if record["phase"] == "measure"),
                          key=lambda record: record["seq"])
        self.assertEqual(len(measured), 6)
        starts = [record["t_start_ns"] for record in measured]
        # The gate reserves the injector just before the request starts, so the
        # start-to-start gap carries that much scheduling jitter.
        jitter_ns = 20 * 1_000_000
        for before, after in zip(starts, starts[1:]):
            self.assertGreaterEqual(after - before, spacing_ns - jitter_ns)
        for record in measured:
            self.assertTrue(record["ok"])
            self.assertLess(record["t_total_ns"], spacing_ns)
        span = starts[-1] + measured[-1]["t_total_ns"] - starts[0]
        self.assertGreater(span, 4 * spacing_ns)
        self.assertLess(sum(record["t_total_ns"] for record in measured), span / 2)

    def test_round_longer_than_the_spacing_does_not_add_a_sleep(self):
        now = [1000.0]
        gate = f3_benchmark.InjectorGate(clock=lambda: now[0])
        self.assertEqual(gate.reserve(0.35), 0.0)
        now[0] += 0.5  # the other classes in the round already took longer than the spacing
        self.assertEqual(gate.reserve(0.35), 0.0)
        now[0] += 0.1  # a shorter round waits out only the remainder
        self.assertAlmostEqual(gate.reserve(0.10), 0.25)
        now[0] += 0.25
        self.assertAlmostEqual(gate.reserve(0.10), 0.10)


class F3RecoveryAndLoadTests(DriverTestCase):
    def test_recovery_boot_records_each_interval_and_keeps_the_log(self):
        fixture = self.fixture()
        output = self.root / "boot"
        self.run_probe("recovery-boot", "--sock", fixture.path, "--out", output,
                       "--allow-vm-lifecycle", "--launch-command", "/usr/bin/true",
                       "--count", 1, "--gap", 0, "--boot-timeout", 20, expect=0)
        records = [json.loads(line) for line in
                   (output / "samples/recovery_boot.jsonl").read_text().splitlines()]
        self.assertEqual(len(records), 1)
        record = records[0]
        self.assertTrue(record["ok"])
        self.assertIsNotNone(record["t_sock_s"])
        self.assertIsNotNone(record["t_guest_s"])
        self.assertIsNotNone(record["t_caps_s"])
        self.assertIsNotNone(record["t_screen_s"])
        self.assertTrue((output / "boot-1.log").is_file())
        self.assertTrue((output / "boot-1.png").is_file())
        run = json.loads((output / "run.json").read_text())
        self.assertEqual(run["details"]["failed"], 0)

    def test_recovery_daemon_measures_the_reconnect_intervals(self):
        fixture = self.fixture(down_cycles=2)
        output = self.root / "daemon"
        self.run_probe("recovery-daemon", "--sock", fixture.path, "--out", output,
                       "--samples", 2, "--gap", 0, "--restart-timeout", 15, expect=0)
        records = [json.loads(line) for line in
                   (output / "samples/recovery_daemon.jsonl").read_text().splitlines()]
        self.assertEqual(len(records), 2)
        for record in records:
            self.assertTrue(record["ok"])
            self.assertLessEqual(record["t_down_s"], record["t_up_s"])
            self.assertLessEqual(record["t_up_s"], record["t_ok_s"])
            self.assertGreaterEqual(record["t_up_minus_down_s"], 0)
        self.assertIn("killall -9 vphoned", fixture.requests[2]["cmd"])

    def test_soak_cycle_sends_the_planned_command_group(self):
        fixture = self.fixture()
        output = self.root / "soak"
        self.run_probe("soak", "--sock", fixture.path, "--out", output, "--minutes", 0.01,
                       "--tail-minutes", 0, "--interval", 0.05, expect=0)
        records = [json.loads(line) for line in
                   (output / "samples/soak.jsonl").read_text().splitlines()]
        measured = {record["class"] for record in records if record["phase"] == "measure"}
        self.assertEqual(measured, {"capabilities", "location_source_status", "app_list:running",
                                    "file_put:64k", "file_get:64k", "screenshot:gray",
                                    "location_source_set", "location_source_stop"})
        self.assertTrue(all(record["ok"] for record in records))
        run = json.loads((output / "run.json").read_text())
        self.assertGreaterEqual(run["details"]["cycles"], 1)

    def test_camera_run_writes_receipt_samples_and_stops_the_source(self):
        fixture = self.fixture()
        image = self.root / "qr.png"
        image.write_bytes(b"qr fixture")
        output = self.root / "camera"
        self.run_probe("camera", "--sock", fixture.path, "--out", output, "--image", image,
                       "--minutes", 0.005, "--interval", 0.05, "--fps", 8,
                       "--launch-consumer", expect=0)
        records = [json.loads(line) for line in
                   (output / "camera_samples.jsonl").read_text().splitlines()]
        self.assertGreaterEqual(len(records), 2)
        for record in records:
            self.assertTrue(record["ok"])
            self.assertLessEqual(record["h_req_ns"], record["h_resp_ns"])
            self.assertIn("vphoned_published_frame_index", record["transport_receipt"])
        metrics = f3_benchmark.camera_metrics(records, min_window_seconds=0.0)
        self.assertEqual(metrics["usable_samples"], len(records))
        self.assertIsNotNone(metrics["r_sched_p50"])
        self.assertAlmostEqual(metrics["publish_to_copy_ms"]["p50"], 2.0, places=3)
        self.assertFalse(fixture.camera["streaming"])
        self.assertEqual(fixture.types()[-1], "app_terminate")
        run = json.loads((output / "run.json").read_text())
        self.assertEqual(run["details"]["fps"], 8)
        self.assertEqual(run["counts"]["failures_by_code"], {})

    def test_guest_log_size_is_sampled_during_soak(self):
        fixture = self.fixture()
        output = self.root / "guest-log"
        self.run_probe("soak", "--sock", fixture.path, "--out", output, "--minutes", 0.01,
                       "--tail-minutes", 0, "--interval", 0.05,
                       "--guest-log", "/var/jb/var/mobile/Library/vphone-vcam.log",
                       "--guest-log", "/var/jb/var/mobile/Library/other.log",
                       "--guest-log-interval", 0.2, expect=0)
        records = [json.loads(line) for line in
                   (output / "samples/guest_log.jsonl").read_text().splitlines()]
        self.assertGreaterEqual(len(records), 2)
        for record in records:
            self.assertEqual(set(record),
                             {"t_wall", "t_mono", "path", "size_bytes", "ok", "code", "error"})
            self.assertTrue(record["ok"])
            self.assertIsNone(record["code"])
            self.assertGreater(record["size_bytes"], 0)
        self.assertEqual({record["path"] for record in records},
                         {"/var/jb/var/mobile/Library/vphone-vcam.log",
                          "/var/jb/var/mobile/Library/other.log"})
        self.assertIn("stat -f %z", fixture.stat_requests[0])
        self.assertIn("-- /var/jb/var/mobile/Library/vphone-vcam.log;", fixture.stat_requests[0])
        self.assertIn("-- '/var/jb/a b.log'",
                      f3_benchmark.guest_stat_command("/var/jb/a b.log"))
        run = json.loads((output / "run.json").read_text())
        self.assertEqual(run["details"]["guest_log_paths"],
                         ["/var/jb/var/mobile/Library/vphone-vcam.log",
                          "/var/jb/var/mobile/Library/other.log"])
        self.assertEqual(run["details"]["guest_log_samples"], len(records))
        self.assertNotIn("guest_log", run["counts"]["skipped"])
        soak = [json.loads(line) for line in
                (output / "samples/soak.jsonl").read_text().splitlines()]
        self.assertTrue(any(record["phase"] == "guest_log" for record in soak))
        self.assertNotIn("guest_log", {record["phase"] for record in soak
                                       if record["class"].startswith("file_")})

    def test_guest_log_is_skipped_without_the_shell_capability(self):
        fixture = self.fixture(shell_available=False)
        output = self.root / "no-shell"
        self.run_probe("idle", "--sock", fixture.path, "--out", output, "--minutes", 0.005,
                       "--interval", 0.05, "--guest-log-interval", 0.1, expect=0)
        run = json.loads((output / "run.json").read_text())
        self.assertIn("guest_log", run["counts"]["skipped"])
        self.assertIn("shell", run["counts"]["skipped"]["guest_log"])
        self.assertFalse((output / "samples/guest_log.jsonl").exists())
        self.assertEqual(fixture.stat_requests, [])
        self.assertEqual(run["counts"]["failures_by_code"], {})

    def test_non_numeric_stat_output_is_a_recorded_failure_that_does_not_stop_the_loop(self):
        fixture = self.fixture(stat_output={"stdout": "stat: no such file\n", "code": 0})
        output = self.root / "bad-stat"
        self.run_probe("idle", "--sock", fixture.path, "--out", output, "--minutes", 0.02,
                       "--interval", 0.05, "--guest-log-interval", 0.05,
                       "--max-consecutive-failures", 1, expect=0)
        records = [json.loads(line) for line in
                   (output / "samples/guest_log.jsonl").read_text().splitlines()]
        self.assertGreater(len(records), 1)
        for record in records:
            self.assertFalse(record["ok"])
            self.assertIsNone(record["size_bytes"])
            self.assertEqual(record["code"], "invalid_size")
            self.assertIn("stat: no such file", record["error"])
        run = json.loads((output / "run.json").read_text())
        self.assertIsNone(run["aborted"])
        self.assertGreaterEqual(run["details"]["probes"], 1)

    def test_missing_guest_log_file_is_recorded_with_the_exit_code(self):
        fixture = self.fixture(stat_output={"stdout": "", "stderr": "No such file\n", "code": 1})
        output = self.root / "missing-log"
        self.run_probe("idle", "--sock", fixture.path, "--out", output, "--minutes", 0.005,
                       "--interval", 0.05, "--guest-log-interval", 0.05, expect=0)
        records = [json.loads(line) for line in
                   (output / "samples/guest_log.jsonl").read_text().splitlines()]
        self.assertEqual(records[0]["code"], "exit_1")
        self.assertIn("No such file", records[0]["error"])

    def test_guest_log_failures_do_not_count_towards_the_abort_threshold(self):
        output = self.root / "threshold"
        output.mkdir()
        args = f3_benchmark.parse_args(["idle", "--sock", str(self.root / "x.sock"),
                                        "--out", str(output), "--max-consecutive-failures", "1"])
        run = f3_benchmark.Run(args, "idle", output, None)
        self.addCleanup(run.close)
        for _ in range(5):
            run.note_result(False, "invalid_size", "guest_log")
        self.assertEqual(run.consecutive_failures, 0)
        self.assertEqual(run.failures_by_code["invalid_size"], 5)
        run.note_result(False, "error", "measure")
        with self.assertRaises(f3_benchmark.TooManyFailures):
            run.note_result(False, "error", "measure")

    def test_empty_guest_log_path_is_refused(self):
        fixture = self.fixture()
        result = self.run_probe("idle", "--sock", fixture.path, "--out", self.root / "bad-path",
                                "--guest-log", "  ", expect=2)
        self.assertIn("guest log paths", result.stderr)
        self.assertEqual(fixture.requests, [])

    def test_idle_with_a_location_source_sets_and_stops_it(self):
        fixture = self.fixture()
        output = self.root / "idle"
        self.run_probe("idle", "--sock", fixture.path, "--out", output, "--minutes", 0.005,
                       "--interval", 0.05, "--location-source", expect=0)
        types = fixture.types()
        self.assertEqual(types[1], "location_source_set")
        self.assertEqual(types[-1], "location_source_stop")
        self.assertEqual(fixture.location_state, "off")
        run = json.loads((output / "run.json").read_text())
        self.assertEqual(run["details"]["location_generation"], "loc-1")
        self.assertGreaterEqual(run["details"]["probes"], 1)


class F3BootTimeTests(DriverTestCase):
    """§2.1 fixed item: the time since the VM under test was started (evidence 10.11)."""

    def bundle(self, name="d4-acc", *, record=None):
        directory = self.root / name
        directory.mkdir()
        with (directory / "config.plist").open("wb") as handle:
            plistlib.dump({"cpuCount": 8, "memorySize": 8 * (1 << 30)}, handle)
        if record is not None:
            (directory / ".vphone-runtime.json").write_text(json.dumps(record))
        return directory

    @staticmethod
    def runtime_record(pid, started_at, operation="boot"):
        return {"bundleIdentifier": "com.vphone.d4-acc", "bundlePath": "/tmp/d4-acc",
                "pid": pid, "instanceID": "instance-1", "startedAt": started_at,
                "operation": operation}

    @staticmethod
    def dead_pid():
        """A pid that no process holds, for the stale-record case."""
        for candidate in range(90000, 60000, -1):
            try:
                os.kill(candidate, 0)
            except ProcessLookupError:
                return candidate
            except OSError:
                continue
        raise unittest.SkipTest("no free pid found")

    def run_with_bundle(self, bundle):
        tag = uuid.uuid4().hex[:6]
        fixture = self.fixture(name=f"sock-{tag}")
        output = self.root / f"out-{bundle.name}-{tag}"
        self.run_probe("latency", "--sock", fixture.path, "--out", output,
                       "--commands", "capabilities", "--samples", 1, "--warmup", 0,
                       "--timeout", 5, "--bundle", bundle, expect=0)
        return json.loads((output / "run.json").read_text())["vm"]

    def test_run_json_records_the_vm_start_time_and_its_age_at_the_run_start(self):
        started = datetime.now(timezone.utc) - timedelta(seconds=1800)
        bundle = self.bundle(record=self.runtime_record(os.getpid(), started.isoformat()))
        vm = self.run_with_bundle(bundle)
        boot = vm["boot"]
        self.assertEqual(boot["started_at"], started.isoformat())
        self.assertEqual(boot["pid"], os.getpid())
        self.assertTrue(boot["pid_alive"])
        self.assertFalse(boot["stale"])
        self.assertTrue(boot["is_boot_operation"])
        self.assertEqual(boot["operation"], "boot")
        self.assertIsNone(boot["unavailable"])
        self.assertAlmostEqual(boot["uptime_at_run_start_s"], 1800, delta=120)
        self.assertIn(".vphone-runtime.json", boot["source"])
        self.assertEqual(vm["config"]["cpuCount"], 8)

    def test_a_missing_or_stale_runtime_record_is_recorded_without_failing_the_run(self):
        absent = self.run_with_bundle(self.bundle("no-record"))["boot"]
        self.assertIsNone(absent["started_at"])
        self.assertIsNone(absent["uptime_at_run_start_s"])
        self.assertIsNone(absent["pid_alive"])
        self.assertIn("cannot read", absent["unavailable"])

        started = datetime.now(timezone.utc) - timedelta(seconds=600)
        pid = self.dead_pid()
        stale = self.run_with_bundle(
            self.bundle("stale", record=self.runtime_record(pid, started.isoformat())))["boot"]
        self.assertEqual(stale["pid"], pid)
        self.assertIs(stale["pid_alive"], False)
        self.assertTrue(stale["stale"])
        self.assertEqual(stale["started_at"], started.isoformat())
        self.assertAlmostEqual(stale["uptime_at_run_start_s"], 600, delta=120)
        self.assertIn("stale", stale["unavailable"])

    def test_a_run_without_a_bundle_records_why_the_boot_time_is_unknown(self):
        fixture = self.fixture()
        output = self.root / "no-bundle"
        self.run_probe("latency", "--sock", fixture.path, "--out", output,
                       "--commands", "capabilities", "--samples", 1, "--warmup", 0,
                       "--timeout", 5, expect=0)
        boot = json.loads((output / "run.json").read_text())["vm"]["boot"]
        self.assertEqual(boot["unavailable"], "no --bundle given")
        self.assertIsNone(boot["started_at"])
        self.assertIsNone(boot["uptime_at_run_start_s"])


class F3SignalTests(DriverTestCase):
    def test_sigterm_still_writes_run_json(self):
        fixture = self.fixture()
        output = self.root / "signal"
        process = subprocess.Popen(
            [sys.executable, "-B", str(PROBE), "idle", "--sock", str(fixture.path),
             "--out", str(output), "--minutes", "5", "--interval", "30"],
            cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and not fixture.requests:
            time.sleep(0.05)
        self.assertTrue(fixture.requests, "the driver never sent its first request")
        process.send_signal(signal.SIGTERM)
        process.communicate(timeout=20)
        run = json.loads((output / "run.json").read_text())
        self.assertEqual(run["interrupted"], "SIGTERM")
        self.assertEqual(run["experiment"], "idle")
        self.assertGreaterEqual(run["counts"]["requests"], 1)


class RequestTimingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="vphone-f3t-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_timing_dict_is_filled_in_order(self):
        fixture = BenchFixture(self.root, "timing")
        fixture.start()
        self.addCleanup(fixture.stop)
        endpoint = host_control_client.endpoint("timing", fixture.path)
        timing = {}
        response = host_control_client.request(
            endpoint, {"t": "capabilities"}, f3_benchmark.NullRecorder(), 5, timing=timing)
        self.assertTrue(response["ok"])
        self.assertEqual(set(timing),
                         {"t_wall_utc", "t_start_ns", "t_connect_ns", "t_send_ns", "t_total_ns"})
        self.assertGreaterEqual(timing["t_total_ns"], timing["t_send_ns"])
        self.assertGreaterEqual(timing["t_send_ns"], timing["t_connect_ns"])
        self.assertGreaterEqual(timing["t_connect_ns"], 0)
        self.assertTrue(timing["t_wall_utc"].endswith("+00:00"))

    def test_failed_request_keeps_the_points_it_reached(self):
        missing = self.root / "missing.sock"
        missing.symlink_to(self.root)  # resolve() works; connect() fails
        endpoint = host_control_client.Endpoint(name="gone", socket_path=missing)
        timing = {}
        with self.assertRaises(host_control_client.HostControlTransportError):
            host_control_client.request(endpoint, {"t": "capabilities"},
                                        f3_benchmark.NullRecorder(), 1, timing=timing)
        self.assertIn("t_start_ns", timing)
        self.assertIn("t_total_ns", timing)
        self.assertNotIn("t_send_ns", timing)
        self.assertGreaterEqual(timing["t_total_ns"], 0)

    def test_existing_callers_are_unaffected_without_timing(self):
        fixture = BenchFixture(self.root, "plain")
        fixture.start()
        self.addCleanup(fixture.stop)
        endpoint = host_control_client.endpoint("plain", fixture.path)

        class Recorder:
            def __init__(self):
                self.entries = []

            def record(self, endpoint, request, response):
                self.entries.append((request, response))

        recorder = Recorder()
        response = host_control_client.request(endpoint, {"t": "capabilities"}, recorder, 5)
        self.assertTrue(response["ok"])
        self.assertEqual(len(recorder.entries), 1)


class CameraMetricTests(unittest.TestCase):
    @staticmethod
    def sample(seq, h_s, sched, pub, obs, *, generation="g1", presentation="p1",
               pub_at=None, obs_at=None, receipt=True, ok=True, streaming=True):
        record = {"seq": seq, "ok": ok, "streaming": streaming, "generation": generation,
                  "presentation_id": presentation, "host_scheduled_frame_index": sched,
                  "h_req_ns": int(h_s * 1e9), "h_resp_ns": int(h_s * 1e9) + 1000}
        if receipt:
            record["transport_receipt"] = {
                "generation": generation, "presentation_id": presentation,
                "vphoned_published_frame_index": pub,
                "libvcam_observed_frame_index": obs,
                "vphoned_published_at_ns": int((pub_at if pub_at is not None else h_s) * 1e9),
                "libvcam_observed_at_ns": int((obs_at if obs_at is not None else h_s) * 1e9),
            }
        return record

    def steady(self, count=40, fps=8, start_seq=0, generation="g1", presentation="p1"):
        return [self.sample(start_seq + index, 2.0 * index, fps * 2 * index, fps * 2 * index,
                            fps * 2 * index, generation=generation, presentation=presentation)
                for index in range(count)]

    def test_steady_stream_reports_the_nominal_rates_and_no_loss(self):
        metrics = f3_benchmark.camera_metrics(self.steady())
        self.assertEqual(metrics["segments"], 1)
        self.assertAlmostEqual(metrics["r_sched_p50"], 8.0, places=6)
        self.assertAlmostEqual(metrics["r_pub_p50"], 8.0, places=6)
        self.assertEqual(metrics["receipt_availability"], 1.0)
        self.assertAlmostEqual(metrics["transport_loss_mean"], 0.0, places=9)
        self.assertEqual(metrics["backlog_max"], 0)
        self.assertEqual(metrics["lag_frames_max"], 0)
        self.assertEqual(metrics["publish_to_copy_ms"]["count"], metrics["usable_samples"])

    def test_publisher_restart_breaks_the_pair_and_splits_segments(self):
        samples = self.steady(20)
        restart = self.sample(20, 40.0, 320, 5, 5)  # pub falls back: vphoned restarted
        after = [self.sample(21 + index, 42.0 + 2.0 * index, 336 + 16 * index,
                             21 + 16 * index, 21 + 16 * index) for index in range(20)]
        metrics = f3_benchmark.camera_metrics(samples + [restart] + after)
        self.assertFalse(f3_benchmark.usable_pair(
            f3_benchmark.camera_sample(samples[-1]), f3_benchmark.camera_sample(restart)))
        self.assertEqual(metrics["segments"], 2)
        self.assertEqual(metrics["usable_samples"], 41)

    def test_presentation_id_change_is_not_a_usable_pair(self):
        first = f3_benchmark.camera_sample(self.sample(0, 0.0, 0, 0, 0, presentation="p1"))
        second = f3_benchmark.camera_sample(self.sample(1, 2.0, 16, 16, 16, presentation="p2"))
        third = f3_benchmark.camera_sample(self.sample(1, 2.0, 16, 16, 16, generation="g2"))
        self.assertFalse(f3_benchmark.usable_pair(first, second))
        self.assertFalse(f3_benchmark.usable_pair(first, third))

    def test_publish_to_copy_delay_uses_only_obs_equals_pub_samples(self):
        samples = [
            self.sample(0, 0.0, 0, 100, 100, pub_at=1.0, obs_at=1.004),
            self.sample(1, 2.0, 16, 116, 114, pub_at=3.0, obs_at=3.5),
            self.sample(2, 4.0, 32, 132, 132, pub_at=5.0, obs_at=5.002),
        ]
        metrics = f3_benchmark.camera_metrics(samples, min_window_seconds=1.0)
        self.assertEqual(metrics["publish_to_copy_ms"]["count"], 2)
        self.assertAlmostEqual(metrics["publish_to_copy_ms"]["p50"], 3.0, places=3)
        self.assertAlmostEqual(metrics["publish_to_copy_ms"]["max"], 4.0, places=3)
        self.assertEqual(metrics["lag_frames_max"], 2)

    def test_samples_without_receipt_are_counted_but_never_paired(self):
        samples = self.steady(10) + [self.sample(10, 20.0, 160, 160, 160, receipt=False)]
        metrics = f3_benchmark.camera_metrics(samples)
        self.assertEqual(metrics["samples"], 11)
        self.assertEqual(metrics["usable_samples"], 10)
        self.assertEqual(metrics["samples_without_receipt"], 1)
        self.assertAlmostEqual(metrics["receipt_availability"], 10 / 11)
        self.assertIsNone(f3_benchmark.camera_sample(samples[-1]))

    def test_transport_loss_needs_a_long_enough_window_and_reports_drops(self):
        lossy = [self.sample(index, 2.0 * index, 16 * index, 12 * index, 12 * index)
                 for index in range(40)]
        metrics = f3_benchmark.camera_metrics(lossy)
        self.assertEqual(len(metrics["transport_loss_windows"]), 1)
        self.assertAlmostEqual(metrics["transport_loss_mean"], 0.25, places=6)
        self.assertGreater(metrics["backlog_max"], 0)
        short = f3_benchmark.camera_metrics(lossy[:5])
        self.assertEqual(short["transport_loss_windows"], [])
        self.assertIsNone(short["transport_loss_mean"])


class SummarizeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="vphone-f3s-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    STARTED_AT = "2026-09-18T00:00:00+00:00"

    @staticmethod
    def wall(seconds):
        """The run-relative wall clock the samplers would write for `seconds` after the start."""
        return (datetime(2026, 9, 18, tzinfo=timezone.utc)
                + timedelta(seconds=seconds)).isoformat()

    @staticmethod
    def footprint_mib(index, slope_per_sample, step_mib, step_index, jitter_mib):
        """Footprint sample: a linear part, an optional discrete step, and small jitter.

        The jitter keeps the point-to-point differences from being all identical, so the
        step criterion has a non-zero robust scale to measure against.
        """
        value = 300.0 + index * slope_per_sample
        if step_index is not None and index >= step_index:
            value += step_mib
        return value + jitter_mib * ((index * 7) % 5 - 2)

    def build_run(self, name, *, slope_per_sample=0.0, vz_after=(11, 12), latency_ms=None,
                  log_growth_kib=64.0, guest_log_ok=True, load_seconds=None,
                  step_mib=0.0, step_index=None, jitter_mib=0.0, vz_process=False,
                  vz_marker="is_vz", quantize_footprint=False):
        directory = self.root / name
        (directory / "samples").mkdir(parents=True)
        run_json = {
            "schema_version": 1, "experiment": "soak", "run_id": name,
            "started_at": self.STARTED_AT, "finished_at": "2026-09-18T01:00:00+00:00",
            "counts": {"requests": 10, "failures_by_code": {}, "skipped": {}},
            "interrupted": None, "aborted": None,
        }
        if load_seconds is not None:
            run_json["details"] = {"cycles": 100, "load_seconds": load_seconds}
        (directory / "run.json").write_text(json.dumps(run_json))
        values = latency_ms if latency_ms is not None else [1.0 + index * 0.01
                                                            for index in range(120)]
        lines = []
        for index, value in enumerate(values):
            lines.append(json.dumps({
                "experiment": "soak", "phase": "measure", "seq": index, "class": "capabilities",
                "command": "capabilities", "params": {}, "ok": True, "code": None, "error": None,
                "response_bytes": 100, "started_utc": "2026-09-18T00:00:00+00:00",
                "t_start_ns": 0, "t_connect_ns": 1, "t_send_ns": 2,
                "t_total_ns": int(value * 1e6)}))
        lines.append(json.dumps({
            "experiment": "soak", "phase": "measure", "seq": len(values), "class": "screenshot:gray",
            "command": "screenshot", "params": {}, "ok": False, "code": "encodingFailed",
            "error": "encodingFailed", "response_bytes": 40, "t_total_ns": None}))
        (directory / "samples" / "soak.jsonl").write_text("\n".join(lines) + "\n")
        boot = {"iteration": 1, "ok": True, "t_sock_s": 3.0, "t_guest_s": 20.0, "t_caps_s": 21.0,
                "t_screen_s": 25.0, "spawn_epoch": 1000.0,
                "vz_pids_before": [1], "vz_pids_after": [1, *vz_after],
                "vz_lstart": {str(pid): 1005.0 for pid in vz_after}}
        (directory / "samples" / "recovery_boot.jsonl").write_text(json.dumps(boot) + "\n")
        host = []
        for index in range(120):
            t_mono = 1000.0 + index * 60.0
            t_wall = self.wall(index * 60.0)
            footprint = self.footprint_mib(index, slope_per_sample, step_mib, step_index,
                                           jitter_mib)
            if quantize_footprint:
                # What `footprint -p` really reports: whole MiB.
                footprint = float(int(footprint))
            cli = {"kind": "process", "label": "vphone-cli", "pid": 4242, "t_mono": t_mono,
                   "t_wall": t_wall, "source": "argument", "cpu_seconds": index * 6.0,
                   "footprint_bytes": int(footprint * (1 << 20))}
            if vz_marker == "is_vz":
                cli["is_vz"] = False
            host.append(cli)
            if vz_process:
                # The operator passes the Virtualization pid with --pid, so its
                # `source` is "argument" exactly like the vphone-cli process.
                vz = {"kind": "process", "label": "d4acc-vz-a", "pid": 83588,
                      "t_mono": t_mono, "t_wall": t_wall, "source": "argument",
                      "cpu_seconds": index * 6.0,
                      "footprint_bytes": int(footprint * (1 << 20))}
                if vz_marker == "is_vz":
                    vz["is_vz"] = True
                host.append(vz)
                if vz_marker == "vz_scan":
                    host.append({"kind": "vz_scan", "t_mono": t_mono, "t_wall": t_wall,
                                 "error": None, "pids": [83588]})
            host.append({"kind": "disk", "label": "Disk.img", "t_mono": t_mono, "t_wall": t_wall,
                         "st_blocks": 42473888 + index * 8})
            host.append({"kind": "file", "label": "boot.log", "path": "/tmp/boot.log",
                         "t_mono": t_mono, "t_wall": t_wall, "present": True,
                         "size_bytes": int((100 + index * 30) * 1024), "blocks": 8,
                         "allocated_bytes": 4096})
        (directory / "host_samples.jsonl").write_text(
            "\n".join(json.dumps(record) for record in host) + "\n")
        guest = []
        for index in range(24):
            size = int((2048 + index * log_growth_kib) * 1024)
            guest.append({"t_wall": self.wall(index * 600.0), "t_mono": 1000.0 + index * 600.0,
                          "path": "/var/jb/var/mobile/Library/vphone-vcam.log",
                          "size_bytes": size if guest_log_ok else None,
                          "ok": guest_log_ok,
                          "code": None if guest_log_ok else "exit_1",
                          "error": None if guest_log_ok else "No such file"})
        (directory / "samples" / "guest_log.jsonl").write_text(
            "\n".join(json.dumps(record) for record in guest) + "\n")
        return directory

    def summarize(self, *directories, out="summary", expect=0, extra=()):
        output = self.root / out
        result = subprocess.run(
            [sys.executable, "-B", str(PROBE), "summarize", *[str(item) for item in directories],
             "--out", str(output), "--resamples", "80", *extra],
            cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, expect, result.stderr + result.stdout)
        if expect != 0:
            return result, None, output
        return result, json.loads((output / "summary.json").read_text()), output

    def test_summary_reports_quantiles_failures_slopes_and_growth(self):
        first = self.build_run("run-a", slope_per_sample=0.5)
        second = self.build_run("run-b", slope_per_sample=0.5)
        _, summary, output = self.summarize(first, second)
        self.assertEqual(len(summary["runs"]), 2)
        latency = summary["runs"][0]["latency"]
        self.assertEqual(latency["unit"], "ms")
        capabilities = latency["classes"]["capabilities"]
        self.assertEqual(capabilities["count"], 120)
        self.assertAlmostEqual(capabilities["p50"], 1.595, places=3)
        self.assertIsNotNone(capabilities["p99"])
        self.assertEqual(len(capabilities["p50_ci"]), 2)
        self.assertEqual(latency["failures_by_code"]["screenshot:gray"], {"encodingFailed": 1})
        slopes = summary["runs"][0]["resources"]["slopes"]
        footprint = slopes["process/vphone-cli/footprint_mib"]
        self.assertAlmostEqual(footprint["slope_per_hour"], 30.0, places=6)
        self.assertAlmostEqual(slopes["process/vphone-cli/cpu_cores"]["first_value"], 0.1, places=6)
        self.assertGreater(footprint["head_tail_delta"], 0)
        growth = summary["growth"]["process/vphone-cli/footprint_mib"]
        self.assertEqual(growth["verdict"], "confirmed")
        self.assertEqual(growth["verdict_source"], "f3_stats.growth_verdict")
        self.assertEqual(len(growth["runs"]), 2)
        # §3.7 host stdout log (sampler kind="file") and guest vcam log.
        host_log = slopes["file/boot.log/size_kib"]
        self.assertAlmostEqual(host_log["slope_per_hour"], 1800.0, places=6)
        guest_log = slopes["guest_log/vphone-vcam.log/size_kib"]
        self.assertAlmostEqual(guest_log["slope_per_hour"], 384.0, places=6)
        self.assertEqual(guest_log["count"], 23)
        self.assertEqual(summary["growth"]["guest_log/vphone-vcam.log/size_kib"]["verdict"],
                         "confirmed")
        markdown = (output / "summary.md").read_text()
        self.assertIn("guest_log/vphone-vcam.log/size_kib", markdown)
        self.assertIn("file/boot.log/size_kib", markdown)
        self.assertIn("# F3 性能基线汇总", markdown)
        self.assertIn("命令延迟（毫秒）", markdown)
        self.assertIn("Theil–Sen 斜率", markdown)
        self.assertIn("增长判定", markdown)
        self.assertIn("恢复区间", markdown)

    def test_a_clean_trend_keeps_its_verdict_and_reports_no_step(self):
        first = self.build_run("trend-a", slope_per_sample=0.5, jitter_mib=0.05)
        second = self.build_run("trend-b", slope_per_sample=0.5, jitter_mib=0.05)
        _, summary, output = self.summarize(first, second, out="trend-summary")
        footprint = summary["runs"][0]["resources"]["slopes"]["process/vphone-cli/footprint_mib"]
        self.assertEqual(footprint["step_count"], 0)
        self.assertEqual(footprint["steps"], [])
        self.assertFalse(footprint["step_dominated"])
        growth = summary["growth"]["process/vphone-cli/footprint_mib"]
        self.assertEqual(growth["verdict"], "confirmed")
        self.assertEqual(summary["step_detection"]["dominance_share"], 0.5)
        self.assertIn("阶跃检测", (output / "summary.md").read_text())

    def test_a_flat_series_with_one_step_is_reported_as_step_dominated(self):
        first = self.build_run("step-a", step_mib=80.0, step_index=60, jitter_mib=0.05)
        second = self.build_run("step-b", step_mib=80.0, step_index=60, jitter_mib=0.05)
        _, summary, output = self.summarize(first, second, out="step-summary")
        footprint = summary["runs"][0]["resources"]["slopes"]["process/vphone-cli/footprint_mib"]
        self.assertGreater(footprint["ci_low"], 0)
        self.assertEqual(footprint["step_count"], 1)
        step = footprint["steps"][0]
        self.assertAlmostEqual(step["delta"], 80.0, delta=0.5)
        self.assertAlmostEqual(step["offset_s"], 3000.0, places=3)
        self.assertGreater(footprint["step_dominated_share"], 0.9)
        self.assertTrue(footprint["step_dominated"])
        self.assertEqual(footprint["step_criterion"]["dominance_share"], 0.5)
        growth = summary["growth"]["process/vphone-cli/footprint_mib"]
        self.assertEqual(growth["verdict"], "step_dominated")
        markdown = (output / "summary.md").read_text()
        self.assertIn("阶跃主导", markdown)
        self.assertIn("t+50.00 分", markdown)

    def test_the_dominance_share_is_a_recorded_command_line_choice(self):
        run = self.build_run("share", step_mib=80.0, step_index=60, jitter_mib=0.05)
        _, summary, _ = self.summarize(run, out="share-summary",
                                       extra=("--step-dominance-share", "0.999"))
        self.assertEqual(summary["step_detection"]["dominance_share"], 0.999)
        footprint = summary["runs"][0]["resources"]["slopes"]["process/vphone-cli/footprint_mib"]
        self.assertEqual(footprint["step_count"], 1)
        self.assertFalse(footprint["step_dominated"])
        self.assertEqual(summary["growth"]["process/vphone-cli/footprint_mib"]["verdict"],
                         "candidate")

    def test_a_constant_series_has_no_step_and_no_verdict_change(self):
        run = self.build_run("constant")
        _, summary, _ = self.summarize(run, out="constant-summary")
        footprint = summary["runs"][0]["resources"]["slopes"]["process/vphone-cli/footprint_mib"]
        self.assertEqual(footprint["step_count"], 0)
        self.assertEqual(footprint["net_change"], 0.0)
        self.assertIsNone(footprint["step_dominated_share"])
        self.assertFalse(footprint["step_dominated"])
        self.assertEqual(summary["growth"]["process/vphone-cli/footprint_mib"]["verdict"],
                         "not_detected")

    def test_virtualization_processes_are_marked_as_background_covariates(self):
        run = self.build_run("vz-role", slope_per_sample=0.5, jitter_mib=0.05, vz_process=True)
        _, summary, output = self.summarize(run, out="vz-role-summary")
        slopes = summary["runs"][0]["resources"]["slopes"]
        self.assertEqual(slopes["process/vphone-cli/footprint_mib"]["role"], "judged")
        self.assertEqual(slopes["process/d4acc-vz-a/footprint_mib"]["role"], "covariate")
        self.assertEqual(slopes["disk/Disk.img/actual_mib"]["role"], "judged")
        self.assertEqual(slopes["file/boot.log/size_kib"]["role"], "judged")
        self.assertEqual(slopes["guest_log/vphone-vcam.log/size_kib"]["role"], "judged")
        growth = summary["growth"]
        self.assertEqual(growth["process/d4acc-vz-a/footprint_mib"]["role"], "covariate")
        self.assertEqual(growth["process/vphone-cli/footprint_mib"]["role"], "judged")
        # Sampling is unchanged: the covariate series keeps its slope and interval.
        self.assertAlmostEqual(slopes["process/d4acc-vz-a/footprint_mib"]["slope_per_hour"],
                               30.0, places=6)
        self.assertIn("背景协变量", (output / "summary.md").read_text())

    def test_an_older_run_without_is_vz_falls_back_to_the_scan_records(self):
        run = self.build_run("vz-scan", slope_per_sample=0.5, jitter_mib=0.05,
                             vz_process=True, vz_marker="vz_scan")
        _, summary, _ = self.summarize(run, out="vz-scan-summary")
        slopes = summary["runs"][0]["resources"]["slopes"]
        self.assertEqual(slopes["process/d4acc-vz-a/footprint_mib"]["role"], "covariate")
        self.assertIn("vz_scan", slopes["process/d4acc-vz-a/footprint_mib"]["role_reason"])
        self.assertEqual(slopes["process/vphone-cli/footprint_mib"]["role"], "judged")

    def test_a_process_no_evidence_identifies_is_reported_as_unknown_not_guessed(self):
        run = self.build_run("vz-none", slope_per_sample=0.5, jitter_mib=0.05,
                             vz_process=True, vz_marker="none")
        _, summary, output = self.summarize(run, out="vz-none-summary")
        slopes = summary["runs"][0]["resources"]["slopes"]
        for label in ("vphone-cli", "d4acc-vz-a"):
            entry = slopes[f"process/{label}/footprint_mib"]
            self.assertEqual(entry["role"], "unknown")
            self.assertIn("无法判断", entry["role_reason"])
        self.assertEqual(summary["growth"]["process/d4acc-vz-a/footprint_mib"]["role"], "unknown")
        self.assertIn("归属未知", (output / "summary.md").read_text())

    def test_a_quantized_staircase_is_a_trend_not_a_series_of_events(self):
        """§3.6: footprint is sampled in whole MiB, so a slow rise arrives as 1 MiB jumps."""
        run = self.build_run("quantized", slope_per_sample=0.05, quantize_footprint=True)
        _, summary, _ = self.summarize(run, out="quantized-summary")
        footprint = summary["runs"][0]["resources"]["slopes"]["process/vphone-cli/footprint_mib"]
        # The series really is a staircase of single-MiB jumps.
        self.assertEqual(footprint["first_value"], 300.0)
        self.assertEqual(footprint["last_value"], 305.0)
        self.assertEqual(footprint["step_criterion"]["scale_source"], "sparse moves")
        self.assertEqual(footprint["step_count"], 0)
        self.assertFalse(footprint["step_dominated"])
        self.assertNotEqual(summary["growth"]["process/vphone-cli/footprint_mib"]["verdict"],
                            "step_dominated")

    def test_a_quantized_series_still_reports_a_jump_of_many_quanta(self):
        run = self.build_run("quantized-step", step_mib=80.0, step_index=60,
                             quantize_footprint=True)
        _, summary, _ = self.summarize(run, out="quantized-step-summary")
        footprint = summary["runs"][0]["resources"]["slopes"]["process/vphone-cli/footprint_mib"]
        self.assertEqual(footprint["step_count"], 1)
        self.assertAlmostEqual(footprint["steps"][0]["delta"], 80.0, delta=0.5)
        self.assertTrue(footprint["step_dominated"])

    def test_flat_series_is_not_detected_as_growth(self):
        run = self.build_run("flat", slope_per_sample=0.0)
        _, summary, _ = self.summarize(run, out="flat-summary")
        growth = summary["growth"]["process/vphone-cli/footprint_mib"]
        self.assertEqual(growth["verdict"], "not_detected")

    def test_vz_attribution_is_uncertain_when_the_pid_count_differs(self):
        run = self.build_run("vz", vz_after=(11,))
        _, summary, output = self.summarize(run, out="vz-summary")
        attribution = summary["runs"][0]["vz_attribution"][0]
        self.assertFalse(attribution["attributed"])
        self.assertIn("归属不确定", attribution["reason"])
        self.assertIn("归属不确定", (output / "summary.md").read_text())
        expected = self.build_run("vz-ok", vz_after=(11, 12))
        _, summary, _ = self.summarize(expected, out="vz-ok-summary")
        self.assertTrue(summary["runs"][0]["vz_attribution"][0]["attributed"])

    def test_vz_attribution_rejects_a_late_lstart(self):
        record = {"spawn_epoch": 1000.0, "vz_pids_before": [1], "vz_pids_after": [1, 11, 12],
                  "vz_lstart": {"11": 1005.0, "12": 1400.0}}
        result = f3_benchmark.vz_attribution(record)
        self.assertFalse(result["attributed"])
        self.assertIn("lstart", result["reason"])

    def test_resource_series_reports_unavailable_fields_instead_of_guessing(self):
        run = self.build_run("missing-fields")
        records = [json.loads(line)
                   for line in (run / "host_samples.jsonl").read_text().splitlines()]
        for record in records:
            record.pop("footprint_bytes", None)
        (run / "host_samples.jsonl").write_text(
            "\n".join(json.dumps(record) for record in records) + "\n")
        _, summary, _ = self.summarize(run, out="missing-summary")
        unavailable = summary["runs"][0]["resources"]["unavailable"]
        self.assertIn("process/vphone-cli/footprint_mib", unavailable)
        self.assertIn("footprint", unavailable["process/vphone-cli/footprint_mib"])

    def test_failed_guest_log_readings_are_unavailable_not_guessed(self):
        run = self.build_run("bad-log", guest_log_ok=False)
        _, summary, output = self.summarize(run, out="bad-log-summary")
        resources = summary["runs"][0]["resources"]
        self.assertNotIn("guest_log/vphone-vcam.log/size_kib", resources["slopes"])
        reason = resources["unavailable"]["guest_log/vphone-vcam.log/size_kib"]
        self.assertIn("0 reading(s)", reason)
        self.assertIn("24 sample(s)", reason)

    def test_guest_log_series_drops_the_warmup_window_and_keeps_sparse_readings(self):
        records = [{"t_mono": 100.0 + index * 300.0,
                    "path": "/var/jb/var/mobile/Library/vphone-vcam.log",
                    "size_bytes": (1024 + index * 16) * 1024, "ok": True,
                    "code": None, "error": None}
                   for index in range(10)]
        records.append({"t_mono": 3100.0, "path": "/var/jb/var/mobile/Library/vphone-vcam.log",
                        "size_bytes": None, "ok": False, "code": "invalid_size", "error": "x"})
        built = f3_benchmark.guest_log_series(records)
        times, values = built["series"]["guest_log/vphone-vcam.log/size_kib"]
        self.assertEqual(len(values), 8)
        self.assertEqual(times[0], 600.0)
        self.assertEqual(values[0], 1056.0)
        self.assertEqual(f3_benchmark.guest_log_series([]),
                         {"series": {}, "roles": {}, "role_reasons": {}, "unavailable": {}})

    def test_file_records_build_a_size_series(self):
        samples = [{"kind": "file", "label": "boot.log", "path": "/tmp/boot.log", "present": True,
                    "t_mono": 1000.0 + index * 60.0, "size_bytes": (10 + index) * 1024,
                    "blocks": 8, "allocated_bytes": 4096} for index in range(20)]
        built = f3_benchmark.resource_series(samples, warmup_seconds=0.0)
        times, values = built["series"]["file/boot.log/size_kib"]
        self.assertEqual(values[:3], [10.0, 11.0, 12.0])
        self.assertEqual(len(times), 20)
        absent = [{"kind": "file", "label": "boot.log", "t_mono": 1000.0 + index * 60.0,
                   "present": False, "error": "No such file"} for index in range(5)]
        built = f3_benchmark.resource_series(absent, warmup_seconds=0.0)
        self.assertIn("size", built["unavailable"]["file/boot.log/size_kib"])

    def test_sparse_footprint_records_still_build_a_series(self):
        # f3_host_sampler merges footprint only every --slow-interval tick.
        samples = []
        for index in range(80):
            record = {"kind": "process", "label": "vphone-cli", "pid": 1, "measurement": "ps",
                      "t_mono": 1000.0 + index * 5, "cpu_seconds": index * 0.5,
                      "rss_bytes": 1 << 20}
            if index % 12 == 0:
                record["measurement"] = "ps+footprint"
                record["footprint_bytes"] = (300 + index) * (1 << 20)
            samples.append(record)
        built = f3_benchmark.resource_series(samples, warmup_seconds=0.0)
        times, values = built["series"]["process/vphone-cli/footprint_mib"]
        self.assertEqual(len(values), 7)
        self.assertEqual(values[0], 300.0)
        self.assertNotIn("process/vphone-cli/footprint_mib", built["unavailable"])
        self.assertEqual(len(built["series"]["process/vphone-cli/cpu_cores"][1]), 79)

    def test_disk_series_accepts_both_sampler_field_names(self):
        for extra in ({"allocated_bytes": 512 * 100}, {"st_blocks": 100}, {"blocks": 100}):
            samples = [{"kind": "disk", "label": "d4-acc/Disk.img", "t_mono": 1000.0 + index * 60,
                        **{key: value + index for key, value in extra.items()}}
                       for index in range(5)]
            built = f3_benchmark.resource_series(samples, warmup_seconds=0.0)
            self.assertIn("disk/d4-acc/Disk.img/actual_mib", built["series"], extra)

    def test_host_samples_inside_the_warmup_window_are_dropped(self):
        samples = [{"kind": "process", "label": "x", "t_mono": 100.0 + index * 10,
                    "cpu_seconds": index, "footprint_bytes": 1 << 20} for index in range(30)]
        built = f3_benchmark.resource_series(samples)
        self.assertEqual(built["series"], {})
        self.assertIn("warm-up", built["unavailable"]["all"])

    def test_soak_tail_samples_are_dropped_from_the_slope_window(self):
        # 3600 s of load inside a 7140 s sample span: everything after 01:00:00Z is the idle tail.
        run = self.build_run("soak-tail", slope_per_sample=0.5, load_seconds=3600.0)
        _, summary, output = self.summarize(run, out="soak-tail-summary")
        window = summary["runs"][0]["resources"]["window"]
        self.assertTrue(window["tail_excluded"])
        self.assertEqual(window["load_seconds"], 3600.0)
        self.assertEqual(window["load_ends_at"], "2026-09-18T01:00:00+00:00")
        self.assertEqual(window["sources"]["host_samples"]["start"], "2026-09-18T00:10:00+00:00")
        self.assertEqual(window["sources"]["host_samples"]["end"], "2026-09-18T01:00:00+00:00")
        # 61 of 120 ticks per kind survive the deadline; the warm-up then drops the first 10.
        self.assertEqual(window["sources"]["host_samples"]["kept"], 183)
        self.assertEqual(window["sources"]["host_samples"]["dropped"], 177)
        self.assertEqual(window["sources"]["guest_log"]["dropped"], 17)
        slopes = summary["runs"][0]["resources"]["slopes"]
        self.assertEqual(slopes["process/vphone-cli/footprint_mib"]["count"], 51)
        self.assertEqual(slopes["guest_log/vphone-vcam.log/size_kib"]["count"], 6)
        markdown = (output / "summary.md").read_text()
        self.assertIn("分析窗口：2026-09-18T00:10:00+00:00 至 2026-09-18T01:00:00+00:00", markdown)
        self.assertIn("空载尾段不属于负载阶段，已排除在斜率估计之外", markdown)
        self.assertIn("剔除宿主采样尾段 177 条", markdown)

    def test_run_without_load_seconds_keeps_every_sample(self):
        run = self.build_run("no-load", slope_per_sample=0.5)
        _, summary, output = self.summarize(run, out="no-load-summary")
        window = summary["runs"][0]["resources"]["window"]
        self.assertFalse(window["tail_excluded"])
        self.assertIsNone(window["load_seconds"])
        self.assertIsNone(window["load_ends_at"])
        self.assertEqual(window["sources"]["host_samples"]["dropped"], 0)
        self.assertEqual(window["sources"]["host_samples"]["kept"], 360)
        self.assertEqual(window["sources"]["guest_log"]["dropped"], 0)
        slopes = summary["runs"][0]["resources"]["slopes"]
        self.assertEqual(slopes["process/vphone-cli/footprint_mib"]["count"], 110)
        self.assertEqual(slopes["guest_log/vphone-vcam.log/size_kib"]["count"], 23)
        self.assertIn("run.json 无 details.load_seconds", (output / "summary.md").read_text())

    def test_a_sample_exactly_at_the_load_deadline_is_kept(self):
        window = f3_benchmark.analysis_window(
            {"started_at": self.STARTED_AT, "details": {"load_seconds": 600.0}})
        records = [{"t_wall": self.wall(index * 60.0), "t_mono": 5000.0 + index * 60.0}
                   for index in range(12)]
        kept, applied = f3_benchmark.windowed_records(records, window)
        self.assertEqual(kept[-1]["t_wall"], "2026-09-18T00:10:00+00:00")
        self.assertEqual(len(kept), 11)
        self.assertEqual(applied["dropped"], 1)
        self.assertEqual(applied["end"], "2026-09-18T00:10:00+00:00")

    def test_summarize_refuses_an_existing_output_directory(self):
        run = self.build_run("run-x")
        (self.root / "taken").mkdir()
        result, _, _ = self.summarize(run, out="taken", expect=2)
        self.assertIn("already exists", result.stderr)


if __name__ == "__main__":
    unittest.main()
