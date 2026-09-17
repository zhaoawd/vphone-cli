import base64
from datetime import datetime
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_f2_dual_vm_acceptance import HostControlFixture  # noqa: E402


ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / "scripts/f1_runtime_acceptance.py"
ALL_COMMANDS = (
    "capabilities", "screenshot", "tap", "swipe", "key", "type", "shell", "file_get", "file_put",
    "app_launch", "app_terminate", "app_list", "app_foreground", "open_url", "ipa_install",
    "location", "location_stop", "location_source_set", "location_stream_start",
    "location_stream_push", "location_source_control", "location_source_stop",
    "location_source_status", "camera_present", "camera_status", "camera_stop",
)
ALL_GUEST_CAPS = ("hid", "devmode", "file", "keychain", "location", "location_owned", "ipa_install",
                  "clipboard", "apps", "url", "settings", "shell", "touch", "touch_edge",
                  "vcam_status", "vcam_receipt_v3")
EXP_SYSCTL = {"kern.Xv_vmm_present": "1", "hw.machine": "iPhone17,3"}
REGULAR_SYSCTL = {"kern.hv_vmm_present": "1", "hw.machine": "iPhone99,11"}


class RuntimeFixture(HostControlFixture):
    """Single-instance fake host-control socket extending the F2 fixture."""

    def __init__(self, directory, name="vm", *, commands_off=(), guest_caps=ALL_GUEST_CAPS,
                 guest_connected=True, sysctl=None, missing_tools=(), hang=(), boottime=(1000, 1),
                 location_runs=True, camera_receipts=True, files=None, corrupt_reads=False,
                 stuck_apps=False, uiopen_missing=False, headless=False):
        super().__init__(directory, name, corrupt_reads=corrupt_reads)
        self.commands_off = set(commands_off)
        self.guest_caps = list(guest_caps)
        self.guest_connected = guest_connected
        self.sysctl = dict(EXP_SYSCTL if sysctl is None else sysctl)
        self.missing_tools = set(missing_tools)
        self.hang = set(hang)
        self.boottime = boottime
        self.location_runs = location_runs
        self.camera_receipts = camera_receipts
        self.stuck_apps = stuck_apps
        self.uiopen_missing = uiopen_missing
        self.headless = headless
        if headless:
            # VPhoneHostCommandExecutor: no VM window -> screenshot/tap/swipe false.
            self.commands_off |= {"screenshot", "tap", "swipe", "camera_present"}
        self.files.update(files or {})
        self.location = {"state": "off", "generation": None, "fix": None, "ack": False}

    def _serve(self):
        while not self._stopped.is_set():
            try:
                connection, _ = self._server.accept()
            except TimeoutError:
                continue
            except OSError:
                return
            with connection:
                try:
                    request = json.loads(self._read_line(connection))
                    self.requests.append(request)
                    if request["t"] in self.hang:
                        self._stopped.wait(1.0)
                        continue
                    response = self._handle(request)
                    connection.sendall(json.dumps(response).encode() + b"\n")
                except (OSError, RuntimeError):
                    continue

    def types(self):
        return [request["t"] for request in self.requests]

    def _handle(self, request):
        command = request["t"]
        if command == "capabilities":
            return {"ok": True, "protocol_version": 1, "boot_mode": "normal",
                    "guest_connected": self.guest_connected,
                    "guest_capabilities": self.guest_caps if self.guest_connected else [],
                    "screen_available": not self.headless, "limits": {"inline_file_bytes": 1048576},
                    "commands": {name: self.guest_connected and name not in self.commands_off
                                 for name in ALL_COMMANDS}}
        if command == "file_put":
            if "load" in request:
                data = Path(request["load"]).read_bytes()
            else:
                data = base64.b64decode(request["data_b64"])
            self.files[request["path"]] = data
            return {"ok": True, "size": len(data)}
        if command == "file_get":
            if request["path"] not in self.files:
                return {"ok": False, "error": "open failed: No such file or directory"}
            data = self.files[request["path"]]
            if self.corrupt_reads:
                data += b"-corrupt"
            if "save" in request:
                Path(request["save"]).write_bytes(data)
                return {"ok": True, "path": request["save"], "size": len(data)}
            return {"ok": True, "size": len(data), "data": base64.b64encode(data).decode()}
        if command == "shell":
            return self._shell(request["cmd"])
        if command == "app_launch" and self.uiopen_missing:
            return {"ok": False, "error": f"uiopen unavailable to launch {request['bundle_id']}"}
        if command == "app_list" and self.uiopen_missing:
            return {"ok": True, "apps": []}
        if command == "app_terminate" and self.stuck_apps:
            return {"ok": True}
        if command == "screenshot":
            Path(request["path"]).write_bytes(b"png")
            return {"ok": True, "path": request["path"], "image": base64.b64encode(b"img").decode()}
        if command == "ipa_install":
            return {"ok": True, "bundle_id": "com.vphone.vptest", "msg": "installed"}
        if command.startswith("location_source_"):
            return self._location(request)
        if command == "camera_present" and not self.camera_receipts:
            return {"ok": False, "error": "camera receipt v3 requires updated vphoned and libvcamcaptured"}
        if command == "camera_status" and not self.camera_receipts:
            return {"ok": True, "streaming": False, "generation": "", "presentation_id": "",
                    "matches_requested": False, "connected": False}
        return super()._handle(request)

    def _shell(self, command):
        match = re.search(r"exec (\S+) ([^;]*); fi", command)
        path, arguments = match.group(1), shlex.split(match.group(2))
        tool = Path(path).name
        if tool in self.missing_tools:
            return {"ok": True, "stdout": "", "stderr": f"vphone-f1: {tool} not found\n", "code": 127,
                    "timed_out": False, "truncated": False}
        result = {"ok": True, "stdout": "", "stderr": "", "code": 0, "timed_out": False, "truncated": False}
        if tool == "sysctl":
            name = arguments[-1]
            if name == "kern.boottime":
                result["stdout"] = f"{{ sec = {self.boottime[0]}, usec = {self.boottime[1]} }} Thu\n"
            elif name in self.sysctl:
                result["stdout"] = self.sysctl[name] + "\n"
            else:
                result.update(stderr=f"sysctl: unknown oid '{name}'\n", code=1)
        elif tool == "ls":
            directory = arguments[-1].rstrip("/")
            result["stdout"] = "".join(Path(item).name + "\n" for item in self.files
                                       if str(Path(item).parent) == directory)
        elif tool == "mv":
            source, target = arguments[-2:]
            self.files[target] = self.files.pop(source)
        elif tool == "rm":
            for item in arguments[arguments.index("--") + 1:]:
                self.files.pop(item, None)
        return result

    @staticmethod
    def _number(value):
        return isinstance(value, (int, float)) and not isinstance(value, bool)

    def _validate_fixed_set(self, request):
        """Mirror VPhoneHostCommandExecutor + VPhoneSystemLocationController fixed-source checks."""
        if request.get("mode") != "fixed":
            return "location_source_set mode must be fixed"
        if str(request.get("coordinate_system", "")).lower() != "wgs84":
            return "coordinate_system must be wgs84"
        if not isinstance(request.get("owner"), str):
            return "owner must be a string"
        heartbeat = request.get("heartbeat_s", 1.0)
        if not self._number(heartbeat):
            return "heartbeat_s must be a number"
        sequence = request.get("producer_sequence")
        if not self._number(sequence) or int(sequence) != sequence:
            return "producer_sequence must be a safe integer"
        for key in ("lat", "lon"):
            if not self._number(request.get(key)):
                return f"{key} must be a number"
        timestamp = request.get("timestamp", 0)
        if isinstance(timestamp, str):
            try:
                timestamp = datetime.fromisoformat(timestamp.replace("Z", "+00:00")).timestamp()
            except ValueError:
                return "timestamp must be ISO-8601"
        elif not self._number(timestamp):
            return "timestamp must be a number or ISO-8601 string"
        for key in ("replace", "persist"):
            if key in request and not isinstance(request[key], bool):
                return f"{key} must be a boolean"
        if not request["owner"].strip():
            return "owner is required"
        if sequence < 0:
            return "producer_sequence must be non-negative"
        if not timestamp > 0:
            return "timestamp must be > 0"
        if not -90 <= request["lat"] <= 90 or not -180 <= request["lon"] <= 180:
            return "lat/lon out of range"
        for key in ("hacc", "vacc"):
            if key in request and not request[key] > 0:
                return f"{key} must be > 0"
        if sequence != 0:
            return "fixed source producer_sequence must be 0"
        if not 0.01 <= heartbeat <= 86400:
            return "heartbeat_s must be between 0.01 and 86400.0 seconds"
        return None

    def _location(self, request):
        command = request["t"]
        if command == "location_source_set":
            error = self._validate_fixed_set(request)
            if error:
                return {"ok": False, "error": error, "code": "invalid_location_source"}
            self.location = {"state": "applying", "generation": "loc-1",
                             "fix": (request["lat"], request["lon"]), "ack": False}
        elif command == "location_source_stop":
            if request.get("generation") != self.location["generation"]:
                return {"ok": False, "error": "generation does not own current source",
                        "code": "location_generation_conflict"}
            self.location = {"state": "off", "generation": None, "fix": None, "ack": False}
        elif self.location["state"] == "applying" and self.location_runs:
            self.location.update(state="running", ack=True)
        applied = {"last_delivery_sequence": 3 if self.location["ack"] else 0}
        if self.location["fix"]:
            applied["last_fix"] = {"latitude": self.location["fix"][0],
                                   "longitude": self.location["fix"][1]}
        if self.location["ack"]:
            applied["last_ack_at"] = "2026-09-17T00:00:00Z"
        return {"ok": True, "state": self.location["state"], "generation": self.location["generation"],
                "desired": {"owner": "vphone-f1-acceptance"} if self.location["generation"] else {},
                "applied": applied}


class F1RuntimeAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="vphone-f1-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def fixture(self, **options):
        fixture = RuntimeFixture(self.root, f"vm{len(list(self.root.glob('*.sock')))}", **options)
        fixture.start()
        self.addCleanup(fixture.stop)
        return fixture

    def run_probe(self, fixture_or_socket, variant, steps, *extra, out="evidence"):
        socket_path = getattr(fixture_or_socket, "path", fixture_or_socket)
        output = self.root / out
        result = subprocess.run([
            sys.executable, str(PROBE), "--socket", str(socket_path), "--variant", variant,
            "--combo", "P", "--out", str(output), "--steps", steps, "--timeout", "2", *extra,
        ], cwd=ROOT, capture_output=True, text=True)
        run = json.loads((output / "run.json").read_text()) if (output / "run.json").exists() else None
        return result, run, output

    @staticmethod
    def steps(run):
        return {step["id"]: step for step in run["steps"]}

    # MARK: - Full run and evidence

    def test_exp_run_records_statuses_evidence_and_redacts_payloads(self):
        fixture = self.fixture()
        image = self.root / "qr.png"
        image.write_bytes(b"qr fixture")
        result, run, output = self.run_probe(fixture, "exp", "all", "--camera-image", str(image),
                                             "--vm-name", "vm-test")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        steps = self.steps(run)
        self.assertEqual(run["schema_version"], 1)
        self.assertEqual(run["combination"]["variant"], "exp")
        self.assertEqual([step["id"] for step in run["steps"]],
                         ["preflight", "S4", "S5", "S6", "S7", "S8", "S9", "S10", "S11", "S12"])
        expected = {"preflight": "passed", "S4": "not_run", "S5": "not_run", "S6": "passed",
                    "S7": "partial", "S8": "not_run", "S9": "partial", "S10": "partial",
                    "S11": "not_applicable", "S12": "partial"}
        self.assertEqual({key: step["status"] for key, step in steps.items()}, expected)
        self.assertEqual(steps["preflight"]["observed"]["protocol_version"], 1)
        set_request = [r for r in fixture.requests if r["t"] == "location_source_set"][0]
        self.assertEqual(set_request["producer_sequence"], 0)
        self.assertGreater(set_request["timestamp"], 1_700_000_000)
        s9_checks = {check["name"]: check["status"] for check in steps["S9"]["checks"]}
        self.assertEqual(s9_checks, {"protocol_set_status": "passed", "protocol_stop": "passed",
                                     "app_layer_reading": "not_run"})
        s10_checks = {check["name"]: check["status"] for check in steps["S10"]["checks"]}
        self.assertEqual(s10_checks["copy_receipt"], "passed")
        self.assertEqual(s10_checks["qr_recognition"], "not_run")
        s12_checks = {check["name"]: check["status"] for check in steps["S12"]["checks"]}
        self.assertEqual(s12_checks["hv_vmm_sysctl"], "passed")
        self.assertEqual(s12_checks["dt_model_via_hw_machine"], "passed")
        self.assertEqual(s12_checks["compute"], "blocked")
        for step_id in ("S6", "S7", "S9", "S10", "S12"):
            record = steps[step_id]
            self.assertTrue((output / record["record"]).is_file())
            self.assertTrue(all(item["sha256"] for item in record["evidence"]))
            self.assertTrue(record["started_at"] <= record["finished_at"])
        requests = (output / "steps/S6/requests.jsonl").read_text()
        self.assertNotIn(base64.b64encode(b"vphone-f1-s6").decode()[:12], requests)
        self.assertIn("omitted_base64_bytes", requests)
        self.assertFalse(any(name.startswith("/tmp/vphone-f1-") for name in fixture.files))
        self.assertFalse(fixture.camera["streaming"])
        self.assertEqual(fixture.location["state"], "off")

    def test_exp_ipa_install_launches_and_terminates_installed_bundle(self):
        fixture = self.fixture()
        ipa = self.root / "test.ipa"
        ipa.write_bytes(b"ipa fixture")
        result, run, _ = self.run_probe(fixture, "exp", "S7", "--ipa", str(ipa))
        self.assertEqual(result.returncode, 0, result.stderr)
        checks = {check["name"]: check["status"] for check in self.steps(run)["S7"]["checks"]}
        self.assertEqual(checks["ipa_install"], "passed")
        self.assertIn("ipa_install", fixture.types())
        self.assertEqual(fixture.foreground["bundle_id"], "")

    def test_missing_socket_blocks_socket_steps_and_still_writes_run(self):
        result, run, _ = self.run_probe(self.root / "missing.sock", "regular", "S6,S9")
        self.assertEqual(result.returncode, 0, result.stderr)
        steps = self.steps(run)
        self.assertEqual(steps["preflight"]["status"], "blocked")
        self.assertEqual(steps["S6"]["status"], "blocked")
        self.assertEqual(steps["S7"]["status"], "not_run")

    def test_guest_disconnected_fails_preflight_and_blocks_steps(self):
        fixture = self.fixture(guest_connected=False)
        result, run, _ = self.run_probe(fixture, "regular", "S6")
        self.assertEqual(result.returncode, 1)
        steps = self.steps(run)
        self.assertEqual(steps["preflight"]["status"], "failed")
        self.assertEqual(steps["S6"]["status"], "blocked")

    def test_existing_output_is_refused(self):
        fixture = self.fixture()
        (self.root / "evidence").mkdir()
        result, run, _ = self.run_probe(fixture, "exp", "S6")
        self.assertEqual(result.returncode, 2)
        self.assertIsNone(run)
        self.assertEqual(fixture.requests, [])

    # MARK: - S4

    def test_s4_write_then_verify_passes_when_marker_persists_and_boottime_changes(self):
        fixture = self.fixture()
        result, run, output = self.run_probe(fixture, "regular", "S4", "--second-boot-phase", "write",
                                             out="write")
        self.assertEqual(result.returncode, 0, result.stderr)
        write = self.steps(run)["S4"]
        self.assertEqual(write["status"], "partial")
        state = output / write["observed"]["state_file"]
        fixture.boottime = (2000, 5)
        result, run, _ = self.run_probe(fixture, "regular", "S4", "--second-boot-phase", "verify",
                                        "--s4-state", str(state), out="verify")
        self.assertEqual(result.returncode, 0, result.stderr)
        verify = self.steps(run)["S4"]
        self.assertEqual(verify["status"], "passed", verify)
        self.assertNotIn(write["observed"]["marker_path"], fixture.files)

    def test_s4_verify_fails_when_boottime_unchanged_or_marker_missing(self):
        fixture = self.fixture()
        _, run, output = self.run_probe(fixture, "regular", "S4", "--second-boot-phase", "write", out="w")
        state = output / self.steps(run)["S4"]["observed"]["state_file"]
        result, run, _ = self.run_probe(fixture, "regular", "S4", "--second-boot-phase", "verify",
                                        "--s4-state", str(state), out="v1")
        self.assertEqual(result.returncode, 1)
        checks = {check["name"]: check["status"] for check in self.steps(run)["S4"]["checks"]}
        self.assertEqual(checks, {"marker_readback": "passed", "restart_evidence": "failed"})
        fixture.boottime = (3000, 0)
        result, run, _ = self.run_probe(fixture, "regular", "S4", "--second-boot-phase", "verify",
                                        "--s4-state", str(state), out="v2")
        checks = {check["name"]: check["status"] for check in self.steps(run)["S4"]["checks"]}
        self.assertEqual(checks["marker_readback"], "failed")

    def test_s4_without_shell_blocks_boottime_and_without_phase_is_not_run(self):
        fixture = self.fixture(commands_off=("shell",))
        _, run, output = self.run_probe(fixture, "less", "S4", "--second-boot-phase", "write", out="w")
        checks = {check["name"]: check["status"] for check in self.steps(run)["S4"]["checks"]}
        self.assertEqual(checks["restart_baseline_recorded"], "blocked")
        state = output / self.steps(run)["S4"]["observed"]["state_file"]
        _, run, _ = self.run_probe(fixture, "less", "S4", "--second-boot-phase", "verify",
                                   "--s4-state", str(state), out="v")
        step = self.steps(run)["S4"]
        self.assertEqual(step["status"], "partial")
        self.assertEqual({c["name"]: c["status"] for c in step["checks"]},
                         {"marker_readback": "passed", "restart_evidence": "blocked"})
        _, run, _ = self.run_probe(fixture, "less", "S4", out="none")
        self.assertEqual(self.steps(run)["S4"]["status"], "not_run")

    def write_runtime(self, bundle, pid, started):
        bundle.mkdir(exist_ok=True)
        (bundle / ".vphone-runtime.json").write_text(json.dumps(
            {"pid": pid, "startedAt": started, "instanceID": f"id-{pid}", "operation": "boot",
             "bundlePath": str(bundle)}))

    def test_s4_bundle_runtime_record_is_restart_evidence_without_shell(self):
        fixture = self.fixture(commands_off=("shell",))
        bundle = self.root / "bundle"
        self.write_runtime(bundle, 100, "2026-09-17T12:00:00Z")
        before = (bundle / ".vphone-runtime.json").read_bytes()
        _, run, output = self.run_probe(fixture, "regular", "S4", "--second-boot-phase", "write",
                                        "--bundle", str(bundle), out="w")
        write = self.steps(run)["S4"]
        self.assertEqual((bundle / ".vphone-runtime.json").read_bytes(), before)
        self.assertEqual(write["observed"]["host_runtime"]["pid"], 100)
        self.assertIn("not equivalent to guest kernel boottime", write["observed"]["host_runtime"]["note"])
        state = output / write["observed"]["state_file"]
        # Only pid changes: not accepted as restart evidence.
        self.write_runtime(bundle, 200, "2026-09-17T12:00:00Z")
        result, run, _ = self.run_probe(fixture, "regular", "S4", "--second-boot-phase", "verify",
                                        "--s4-state", str(state), "--bundle", str(bundle), out="v1")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.steps(run)["S4"]["status"], "failed")
        self.write_runtime(bundle, 200, "2026-09-17T12:05:00Z")
        result, run, _ = self.run_probe(fixture, "regular", "S4", "--second-boot-phase", "verify",
                                        "--s4-state", str(state), "--bundle", str(bundle), out="v2")
        self.assertEqual(result.returncode, 0, result.stderr)
        step = self.steps(run)["S4"]
        self.assertEqual(step["status"], "passed")
        evidence = [c for c in step["checks"] if c["name"] == "restart_evidence"][0]
        self.assertEqual(evidence["source"], "host_runtime_record")
        self.assertIn("not equivalent to guest kernel boottime", evidence["detail"])

    def test_s4_boottime_takes_precedence_over_bundle_record_when_shell_exists(self):
        fixture = self.fixture()
        bundle = self.root / "bundle"
        self.write_runtime(bundle, 100, "2026-09-17T12:00:00Z")
        _, run, output = self.run_probe(fixture, "regular", "S4", "--second-boot-phase", "write",
                                        "--bundle", str(bundle), out="w")
        write = self.steps(run)["S4"]
        self.assertIsNotNone(write["observed"]["boottime"])
        self.assertIsNotNone(write["observed"]["host_runtime"])
        self.write_runtime(bundle, 200, "2026-09-17T12:05:00Z")
        result, run, _ = self.run_probe(fixture, "regular", "S4", "--second-boot-phase", "verify",
                                        "--s4-state", str(output / write["observed"]["state_file"]),
                                        "--bundle", str(bundle), out="v")
        self.assertEqual(result.returncode, 1)
        step = self.steps(run)["S4"]
        evidence = [c for c in step["checks"] if c["name"] == "restart_evidence"][0]
        self.assertEqual((evidence["status"], evidence["source"]), ("failed", "kern.boottime"))
        self.assertEqual(step["observed"]["host_runtime_result"], "passed")

    # MARK: - S6

    def test_s6_corrupt_readback_fails_and_cleans_guest_file(self):
        fixture = self.fixture(corrupt_reads=True)
        result, run, _ = self.run_probe(fixture, "regular", "S6")
        self.assertEqual(result.returncode, 1)
        step = self.steps(run)["S6"]
        self.assertEqual(step["status"], "failed")
        self.assertEqual(step["failure"]["stage"], "get")
        self.assertEqual(fixture.types()[-1], "shell")
        self.assertFalse(any(name.startswith("/tmp/vphone-f1-") for name in fixture.files))

    def test_s6_without_shell_is_partial_and_without_file_capability_not_applicable(self):
        fixture = self.fixture(commands_off=("shell",))
        _, run, _ = self.run_probe(fixture, "regular", "S6", out="noshell")
        step = self.steps(run)["S6"]
        self.assertEqual(step["status"], "partial")
        self.assertEqual({check["name"]: check["status"] for check in step["checks"]},
                         {"put_get": "passed", "list": "blocked", "rename": "blocked", "delete": "blocked"})
        nofile = self.fixture(commands_off=("file_get", "file_put"),
                              guest_caps=[cap for cap in ALL_GUEST_CAPS if cap != "file"])
        _, run, _ = self.run_probe(nofile, "less", "S6", out="nofile")
        self.assertEqual(self.steps(run)["S6"]["status"], "not_applicable")

    # MARK: - S7

    def test_s7_fails_when_pid_remains_after_terminate(self):
        fixture = self.fixture(stuck_apps=True)
        result, run, _ = self.run_probe(fixture, "regular", "S7")
        self.assertEqual(result.returncode, 1)
        checks = {check["name"]: check["status"] for check in self.steps(run)["S7"]["checks"]}
        self.assertEqual(checks["terminate_pid_gone"], "failed")
        self.assertEqual(checks["ipa_install"], "not_applicable")

    def test_s7_uiopen_missing_is_failed_with_classification_and_empty_list_observed(self):
        fixture = self.fixture(uiopen_missing=True)
        result, run, _ = self.run_probe(fixture, "regular", "S7")
        self.assertEqual(result.returncode, 1)
        step = self.steps(run)["S7"]
        self.assertEqual(step["status"], "failed")
        self.assertEqual(step["failure"]["classification"], "capability_declared_but_uiopen_missing")
        self.assertEqual(step["observed"]["initial_running_apps"], {"count": 0, "empty": True, "bundle_ids": []})

    def test_s7_split_guest_without_app_launch_marks_launch_checks_not_applicable(self):
        caps = [cap for cap in ALL_GUEST_CAPS if cap != "url"] + ["apps_v2"]
        fixture = self.fixture(guest_caps=caps, commands_off=("app_launch", "open_url"),
                               uiopen_missing=True)
        for variant in ("regular", "jb"):
            result, run, _ = self.run_probe(fixture, variant, "S7", out=variant)
            self.assertEqual(result.returncode, 0, result.stderr)
            step = self.steps(run)["S7"]
            self.assertEqual(step["status"], "not_applicable")
            checks = {check["name"]: check for check in step["checks"]}
            self.assertEqual({name: check["status"] for name, check in checks.items()},
                             dict.fromkeys(("launch_pid", "screenshot_shows_app",
                                            "terminate_pid_gone", "ipa_install"), "not_applicable"))
            self.assertIn("apps_v2 without app_launch", checks["launch_pid"]["detail"])
            self.assertFalse(step["observed"]["app_launch_declared"])
        self.assertNotIn("app_launch", fixture.types())
        self.assertNotIn("app_terminate", fixture.types())

    def test_s7_split_guest_declaring_app_launch_still_fails_on_launch_error(self):
        fixture = self.fixture(guest_caps=list(ALL_GUEST_CAPS) + ["apps_v2", "app_launch"],
                               uiopen_missing=True)
        result, run, _ = self.run_probe(fixture, "jb", "S7")
        self.assertEqual(result.returncode, 1)
        step = self.steps(run)["S7"]
        self.assertEqual(step["status"], "failed")
        self.assertEqual(step["failure"]["classification"], "capability_declared_but_uiopen_missing")

    def test_s10_split_guest_without_app_launch_is_not_applicable_before_present(self):
        caps = [cap for cap in ALL_GUEST_CAPS if cap != "url"] + ["apps_v2"]
        fixture = self.fixture(guest_caps=caps, commands_off=("app_launch", "open_url"))
        image = self.root / "qr.png"
        image.write_bytes(b"qr")
        result, run, _ = self.run_probe(fixture, "exp", "S10", "--camera-image", str(image))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.steps(run)["S10"]["status"], "not_applicable")
        self.assertNotIn("camera_present", fixture.types())
        self.assertNotIn("app_launch", fixture.types())

    def test_headless_records_launch_and_blocks_screen_dependent_camera(self):
        fixture = self.fixture(headless=True)
        image = self.root / "qr.png"
        image.write_bytes(b"qr")
        _, run, _ = self.run_probe(fixture, "exp", "S7,S10", "--camera-image", str(image),
                                   "--launch-mode", "headless")
        self.assertEqual(run["launch"], {"declared_mode": "headless", "screen_available": False,
                                         "boot_mode": "normal"})
        steps = self.steps(run)
        self.assertFalse(steps["preflight"]["observed"]["screen_available"])
        self.assertEqual(steps["S10"]["status"], "blocked")
        self.assertIn("requires GUI launch (screen_available=false", steps["S10"]["failure"]["reason"])
        self.assertNotIn("camera_present", fixture.types())
        checks = {c["name"]: c for c in steps["S7"]["checks"]}
        self.assertEqual(checks["screenshot_shows_app"]["status"], "blocked")
        self.assertIn("screen_available=false", checks["screenshot_shows_app"]["detail"])

    def test_fixture_rejects_invalid_fixed_location_request(self):
        fixture = RuntimeFixture(self.root, "direct")
        base = {"t": "location_source_set", "mode": "fixed", "coordinate_system": "wgs84",
                "owner": "o", "lat": 1.0, "lon": 2.0, "producer_sequence": 0, "timestamp": 1.0}
        self.assertEqual(fixture._location({**base, "timestamp": 0})["error"], "timestamp must be > 0")
        missing = dict(base)
        del missing["timestamp"]
        self.assertEqual(fixture._location(missing)["error"], "timestamp must be > 0")
        self.assertEqual(fixture._location({**base, "producer_sequence": 1})["error"],
                         "fixed source producer_sequence must be 0")
        self.assertTrue(fixture._location(base)["ok"])
        fixture._server.close()

    def test_s7_missing_app_commands_blocked_when_guest_declares_apps(self):
        fixture = self.fixture(commands_off=("app_launch",))
        _, run, _ = self.run_probe(fixture, "regular", "S7")
        self.assertEqual(self.steps(run)["S7"]["status"], "blocked")
        self.assertNotIn("app_launch", fixture.types())

    # MARK: - S9

    def test_s9_timeout_is_blocked_with_timeout_flag(self):
        fixture = self.fixture(hang=("location_source_set",))
        output = self.root / "evidence"
        result = subprocess.run([
            sys.executable, str(PROBE), "--socket", str(fixture.path), "--variant", "exp",
            "--combo", "P", "--out", str(output), "--steps", "S9", "--timeout", "0.3",
        ], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        step = self.steps(json.loads((output / "run.json").read_text()))["S9"]
        self.assertEqual(step["status"], "blocked")
        self.assertTrue(step["failure"]["timed_out"])
        self.assertEqual(step["failure"]["stage"], "set")
        log = [json.loads(line) for line in (output / "steps/S9/requests.jsonl").read_text().splitlines()]
        self.assertTrue(log[-1]["timed_out"])

    def test_s9_fails_when_source_never_runs_and_not_applicable_without_capability(self):
        fixture = self.fixture(location_runs=False)
        result, run, _ = self.run_probe(fixture, "exp", "S9", "--location-wait", "0.5", out="stuck")
        self.assertEqual(result.returncode, 1)
        step = self.steps(run)["S9"]
        self.assertEqual((step["status"], step["failure"]["stage"]), ("failed", "await_running"))
        self.assertEqual(fixture.location["state"], "off")
        nocap = self.fixture(commands_off=("location_source_set", "location_source_stop"),
                             guest_caps=[cap for cap in ALL_GUEST_CAPS if cap != "location_owned"])
        _, run, _ = self.run_probe(nocap, "exp", "S9", out="nocap")
        self.assertEqual(self.steps(run)["S9"]["status"], "not_applicable")

    def test_s9_active_foreign_source_is_blocked_without_replacement(self):
        fixture = self.fixture()
        fixture.location = {"state": "running", "generation": "other", "fix": (1.0, 2.0), "ack": True}
        _, run, _ = self.run_probe(fixture, "exp", "S9")
        self.assertEqual(self.steps(run)["S9"]["status"], "blocked")
        self.assertNotIn("location_source_set", fixture.types())

    # MARK: - S10

    def test_s10_non_exp_negative_passes_when_injection_absent_and_no_receipt(self):
        fixture = self.fixture(sysctl=REGULAR_SYSCTL, camera_receipts=False)
        image = self.root / "qr.png"
        image.write_bytes(b"qr")
        result, run, _ = self.run_probe(fixture, "regular", "S10", "--camera-image", str(image))
        self.assertEqual(result.returncode, 0, result.stderr)
        step = self.steps(run)["S10"]
        self.assertEqual((step["status"], step["expectation"]), ("passed", "absent"))
        self.assertIn("camera receipt v3", step["observed"]["camera_present"]["error"])

    def test_s10_non_exp_fails_when_injection_file_exists(self):
        fixture = self.fixture(sysctl=REGULAR_SYSCTL, camera_receipts=False,
                               files={"/var/jb/usr/lib/libvcamcaptured.dylib": b"dylib"})
        result, run, output = self.run_probe(fixture, "jb", "S10")
        self.assertEqual(result.returncode, 1)
        step = self.steps(run)["S10"]
        self.assertEqual(step["status"], "failed")
        self.assertTrue((output / "steps/S10/unexpected_libvcamcaptured.dylib").is_file())

    def test_s10_exp_without_receipt_fails_and_without_image_not_run(self):
        fixture = self.fixture(camera_receipts=False)
        image = self.root / "qr.png"
        image.write_bytes(b"qr")
        result, run, _ = self.run_probe(fixture, "exp", "S10", "--camera-image", str(image), out="bad")
        self.assertEqual(result.returncode, 1)
        step = self.steps(run)["S10"]
        self.assertEqual((step["status"], step["failure"]["stage"]), ("failed", "present"))
        self.assertEqual(fixture.foreground["bundle_id"], "")
        _, run, _ = self.run_probe(fixture, "exp", "S10", out="noimage")
        self.assertEqual(self.steps(run)["S10"]["status"], "not_run")

    # MARK: - S12

    def test_s12_non_exp_negative_and_exp_mismatch(self):
        regular = self.fixture(sysctl=REGULAR_SYSCTL)
        _, run, _ = self.run_probe(regular, "regular", "S12", out="regular")
        step = self.steps(run)["S12"]
        checks = {check["name"]: check["status"] for check in step["checks"]}
        self.assertEqual(step["expectation"], "absent")
        self.assertEqual(checks["hv_vmm_sysctl"], "passed")
        self.assertEqual(checks["dt_model_via_hw_machine"], "passed")
        self.assertEqual(checks["dt_target_type_compatible"], "blocked")
        self.assertEqual(step["status"], "partial")
        exp_like_regular = self.fixture(sysctl=REGULAR_SYSCTL)
        result, run, _ = self.run_probe(exp_like_regular, "exp", "S12", out="exp")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.steps(run)["S12"]["status"], "failed")

    def test_s12_missing_sysctl_tool_is_blocked(self):
        fixture = self.fixture(missing_tools=("sysctl",))
        _, run, _ = self.run_probe(fixture, "exp", "S12")
        step = self.steps(run)["S12"]
        self.assertEqual(step["status"], "blocked")
        checks = {check["name"]: check["status"] for check in step["checks"]}
        self.assertEqual(checks["hv_vmm_sysctl"], "blocked")


if __name__ == "__main__":
    unittest.main()
