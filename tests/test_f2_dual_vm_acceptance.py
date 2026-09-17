import base64
import json
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / "scripts/f2_dual_vm_acceptance.py"


class HostControlFixture:
    def __init__(self, directory, name, corrupt_reads=False):
        self.name = name
        self.corrupt_reads = corrupt_reads
        self.path = Path(directory) / f"{name}.sock"
        self.files = {}
        self.foreground = {"bundle_id": "", "pid": 0, "name": ""}
        self.next_pid = 100
        self.camera = {"streaming": False, "generation": "", "presentation_id": ""}
        self.requests = []
        self._server = socket.socket(socket.AF_UNIX)
        self._server.bind(str(self.path))
        self._server.listen()
        self._server.settimeout(0.1)
        self._stopped = threading.Event()
        self._thread = threading.Thread(target=self._serve, daemon=True)

    def start(self):
        self._thread.start()

    def stop(self):
        self._stopped.set()
        self._server.close()
        self._thread.join(timeout=2)

    def _serve(self):
        while not self._stopped.is_set():
            try:
                connection, _ = self._server.accept()
            except TimeoutError:
                continue
            except OSError:
                return
            with connection:
                request = json.loads(self._read_line(connection))
                self.requests.append(request)
                response = self._handle(request)
                connection.sendall(json.dumps(response).encode() + b"\n")

    @staticmethod
    def _read_line(connection):
        data = b""
        while b"\n" not in data:
            chunk = connection.recv(4096)
            if not chunk:
                raise RuntimeError("unexpected EOF")
            data += chunk
        return data.split(b"\n", 1)[0]

    def _handle(self, request):
        command = request["t"]
        if command == "capabilities":
            return {
                "ok": True,
                "guest_connected": True,
                "commands": {
                    "file_get": True, "file_put": True, "shell": True,
                    "app_launch": True, "app_terminate": True, "app_foreground": True,
                    "app_list": True,
                    "camera_present": True, "camera_status": True, "camera_stop": True,
                },
            }
        if command == "file_put":
            data = base64.b64decode(request["data_b64"])
            self.files[request["path"]] = data
            return {"ok": True, "size": len(data)}
        if command == "file_get":
            data = self.files[request["path"]]
            if self.corrupt_reads:
                data += b"-corrupt"
            return {"ok": True, "size": len(data), "data": base64.b64encode(data).decode()}
        if command == "shell":
            shell_command = request["cmd"]
            if "/bin/rm" not in shell_command or "/var/jb/bin/rm" not in shell_command:
                return {
                    "ok": True,
                    "stdout": "",
                    "stderr": "/var/jb/bin/sh: 1: rm: not found\n",
                    "code": 127,
                }
            path = shlex.split(shell_command)[-1]
            self.files.pop(path, None)
            return {"ok": True, "stdout": "", "stderr": "", "code": 0}
        if command == "app_launch":
            self.next_pid += 1
            self.foreground = {
                "bundle_id": request["bundle_id"], "pid": self.next_pid, "name": "Settings",
            }
            return {"ok": True, "pid": self.next_pid}
        if command == "app_terminate":
            if self.foreground["bundle_id"] == request["bundle_id"]:
                self.foreground = {"bundle_id": "", "pid": 0, "name": ""}
            return {"ok": True}
        if command == "app_foreground":
            return {"ok": True, **self.foreground}
        if command == "app_list":
            apps = []
            if self.foreground["bundle_id"]:
                apps.append({"state": "running", **self.foreground})
            return {"ok": True, "apps": apps}
        if command == "camera_present":
            self.camera = {
                "streaming": True,
                "generation": request["generation"],
                "presentation_id": f"presentation-{self.name}",
            }
            receipt = {
                "generation": self.camera["generation"],
                "presentation_id": self.camera["presentation_id"],
            }
            return {
                "ok": True, **self.camera, "source": "image", "role": request["role"],
                "transport_receipt": receipt,
            }
        if command == "camera_status":
            matches = (
                self.camera["streaming"]
                and request["generation"] == self.camera["generation"]
                and (not request.get("presentation_id")
                     or request["presentation_id"] == self.camera["presentation_id"])
            )
            response = {
                "ok": True, **self.camera, "connected": True,
                "matches_requested": matches,
            }
            if matches:
                response["transport_receipt"] = {
                    "generation": self.camera["generation"],
                    "presentation_id": self.camera["presentation_id"],
                }
            return response
        if command == "camera_stop":
            if (self.camera["generation"] != request["generation"]
                    or (request.get("presentation_id")
                        and self.camera["presentation_id"] != request["presentation_id"])):
                return {"ok": False, "error": "camera identity mismatch"}
            self.camera = {"streaming": False, "generation": "", "presentation_id": ""}
            return {"ok": True, "streaming": False, "stop_policy": request["policy"]}
        raise AssertionError(f"unexpected command: {command}")


class DualVMAcceptanceTests(unittest.TestCase):
    def test_file_isolation_routes_same_path_to_distinct_endpoints_and_records_evidence(self):
        with tempfile.TemporaryDirectory(prefix="vphone-f2-") as temporary:
            left = HostControlFixture(temporary, "left")
            right = HostControlFixture(temporary, "right")
            left.start()
            right.start()
            self.addCleanup(left.stop)
            self.addCleanup(right.stop)
            output = Path(temporary) / "evidence"
            guest_path = "/tmp/vphone-f2-test.txt"

            result = subprocess.run([
                sys.executable, str(PROBE), "file-isolation",
                "--left-name", "vm-left", "--left-socket", str(left.path),
                "--right-name", "vm-right", "--right-socket", str(right.path),
                "--guest-path", guest_path, "--output", str(output),
            ], cwd=ROOT, capture_output=True, text=True)

            self.assertEqual(result.returncode, 0, result.stderr)
            summary = json.loads((output / "summary.json").read_text())
            self.assertEqual(summary["result"], "pass")
            self.assertEqual(summary["scenario"], "file-isolation")
            self.assertEqual(summary["instances"], ["vm-left", "vm-right"])
            records = [json.loads(line) for line in (output / "requests.jsonl").read_text().splitlines()]
            self.assertEqual({record["instance"] for record in records}, {"vm-left", "vm-right"})
            sockets = {str(left.path.resolve()), str(right.path.resolve())}
            self.assertTrue(all(record["socket"] in sockets for record in records))
            self.assertNotEqual(left.requests[1]["data_b64"], right.requests[1]["data_b64"])
            self.assertIn("exec /bin/rm", left.requests[-1]["cmd"])
            self.assertIn("exec /var/jb/bin/rm", left.requests[-1]["cmd"])
            self.assertNotIn(guest_path, left.files)
            self.assertNotIn(guest_path, right.files)

    def test_survivor_checks_stopped_cleanup_and_keeps_running_instance_usable(self):
        with tempfile.TemporaryDirectory(prefix="vphone-f2-") as temporary:
            running = HostControlFixture(temporary, "running")
            running.start()
            self.addCleanup(running.stop)
            stopped_vm = Path(temporary) / "stopped-vm"
            stopped_vm.mkdir()
            output = Path(temporary) / "evidence"
            guest_path = "/tmp/vphone-f2-survivor.txt"

            result = subprocess.run([
                sys.executable, str(PROBE), "survivor",
                "--stopped-name", "vm-stopped", "--stopped-vm-dir", str(stopped_vm),
                "--running-name", "vm-running", "--running-socket", str(running.path),
                "--guest-path", guest_path, "--output", str(output),
            ], cwd=ROOT, capture_output=True, text=True)

            self.assertEqual(result.returncode, 0, result.stderr)
            summary = json.loads((output / "summary.json").read_text())
            self.assertEqual(summary["result"], "pass")
            self.assertEqual(summary["scenario"], "survivor")
            self.assertEqual(summary["stopped_instance"], "vm-stopped")
            self.assertEqual(summary["running_instance"], "vm-running")
            self.assertEqual([request["t"] for request in running.requests],
                             ["capabilities", "file_put", "file_get", "shell"])
            self.assertNotIn(guest_path, running.files)

    def test_app_isolation_routes_lifecycle_and_leaves_other_instance_unchanged(self):
        with tempfile.TemporaryDirectory(prefix="vphone-f2-") as temporary:
            left = HostControlFixture(temporary, "left")
            right = HostControlFixture(temporary, "right")
            left.start()
            right.start()
            self.addCleanup(left.stop)
            self.addCleanup(right.stop)
            output = Path(temporary) / "evidence"

            result = subprocess.run([
                sys.executable, str(PROBE), "app-isolation",
                "--left-name", "vm-left", "--left-socket", str(left.path),
                "--right-name", "vm-right", "--right-socket", str(right.path),
                "--bundle-id", "com.apple.Preferences", "--output", str(output),
            ], cwd=ROOT, capture_output=True, text=True)

            self.assertEqual(result.returncode, 0, result.stderr)
            summary = json.loads((output / "summary.json").read_text())
            self.assertEqual(summary["result"], "pass")
            self.assertEqual(summary["scenario"], "app-isolation")
            self.assertEqual(summary["bundle_id"], "com.apple.Preferences")
            self.assertEqual(left.foreground["bundle_id"], "")
            self.assertEqual(right.foreground["bundle_id"], "")
            self.assertEqual(
                [request["t"] for request in left.requests],
                ["capabilities", "app_list", "app_launch", "app_list",
                 "app_list", "app_terminate", "app_list"],
            )
            self.assertEqual(
                [request["t"] for request in right.requests],
                ["capabilities", "app_list", "app_list", "app_launch",
                 "app_list", "app_list", "app_terminate"],
            )

    def test_path_alias_is_rejected_before_requests_are_sent(self):
        with tempfile.TemporaryDirectory(prefix="vphone-f2-") as temporary:
            endpoint = HostControlFixture(temporary, "endpoint")
            endpoint.start()
            self.addCleanup(endpoint.stop)
            alias = Path(temporary) / "alias.sock"
            alias.symlink_to(endpoint.path)
            output = Path(temporary) / "evidence"

            result = subprocess.run([
                sys.executable, str(PROBE), "file-isolation",
                "--left-name", "vm-left", "--left-socket", str(endpoint.path),
                "--right-name", "vm-right", "--right-socket", str(alias),
                "--output", str(output),
            ], cwd=ROOT, capture_output=True, text=True)

            self.assertEqual(result.returncode, 1)
            self.assertIn("same endpoint", result.stderr)
            self.assertEqual(endpoint.requests, [])
            summary = json.loads((output / "summary.json").read_text())
            self.assertEqual(summary["result"], "fail")

    def test_camera_isolation_keeps_observer_stopped_and_cleans_presenter(self):
        with tempfile.TemporaryDirectory(prefix="vphone-f2-") as temporary:
            observer = HostControlFixture(temporary, "observer")
            presenter = HostControlFixture(temporary, "presenter")
            observer.start()
            presenter.start()
            self.addCleanup(observer.stop)
            self.addCleanup(presenter.stop)
            source = Path(temporary) / "source.png"
            source.write_bytes(b"test image fixture")
            output = Path(temporary) / "evidence"

            result = subprocess.run([
                sys.executable, str(PROBE), "camera-isolation",
                "--observer-name", "vm-observer", "--observer-socket", str(observer.path),
                "--presenter-name", "vm-presenter", "--presenter-socket", str(presenter.path),
                "--source-path", str(source), "--output", str(output),
            ], cwd=ROOT, capture_output=True, text=True)

            self.assertEqual(result.returncode, 0, result.stderr)
            summary = json.loads((output / "summary.json").read_text())
            self.assertEqual(summary["result"], "pass")
            self.assertEqual(summary["scenario"], "camera-isolation")
            self.assertEqual(summary["observer_instance"], "vm-observer")
            self.assertEqual(summary["presenter_instance"], "vm-presenter")
            self.assertFalse(observer.camera["streaming"])
            self.assertFalse(presenter.camera["streaming"])
            self.assertNotIn("camera_present", [request["t"] for request in observer.requests])
            self.assertFalse(summary["observations"]["foreign_stop"]["vm-observer"]["ok"])
            self.assertEqual(
                [request["t"] for request in presenter.requests],
                ["capabilities", "app_list", "camera_status", "app_launch", "app_list",
                 "camera_present", "camera_status", "camera_status", "camera_stop",
                 "camera_status", "app_terminate", "app_list"],
            )

    def test_failed_file_attribution_cleans_both_instances(self):
        with tempfile.TemporaryDirectory(prefix="vphone-f2-") as temporary:
            left = HostControlFixture(temporary, "left", corrupt_reads=True)
            right = HostControlFixture(temporary, "right")
            left.start()
            right.start()
            self.addCleanup(left.stop)
            self.addCleanup(right.stop)
            output = Path(temporary) / "evidence"
            guest_path = "/tmp/vphone-f2-failure.txt"

            result = subprocess.run([
                sys.executable, str(PROBE), "file-isolation",
                "--left-name", "vm-left", "--left-socket", str(left.path),
                "--right-name", "vm-right", "--right-socket", str(right.path),
                "--guest-path", guest_path, "--output", str(output),
            ], cwd=ROOT, capture_output=True, text=True)

            self.assertEqual(result.returncode, 1)
            self.assertIn("another instance's file marker", result.stderr)
            self.assertNotIn(guest_path, left.files)
            self.assertNotIn(guest_path, right.files)
            self.assertEqual(left.requests[-1]["t"], "shell")
            self.assertEqual(right.requests[-1]["t"], "shell")

    def test_offline_guard_requires_refusal_without_outputs_and_rechecks_endpoint(self):
        with tempfile.TemporaryDirectory(prefix="vphone-f2-") as temporary:
            root = Path(temporary)
            vm = root / "vm-running"
            vm.mkdir()
            (vm / "config.plist").write_bytes(b"config")
            (vm / ".vphone-runtime.json").write_text('{"operation":"boot"}\n')
            running = HostControlFixture(vm, "vphone")
            running.start()
            self.addCleanup(running.stop)
            fake_cli = root / "fake-vphone"
            fake_cli.write_text(
                "#!/bin/sh\nprintf '%s\\n' \"VM 'vm-running' is busy\" >&2\nexit 1\n"
            )
            fake_cli.chmod(0o755)
            fake_lock = root / "fake-lock.py"
            fake_lock.write_text(
                "import sys\nprint('VM lock unavailable: busy', file=sys.stderr)\nraise SystemExit(1)\n"
            )
            output = root / "evidence"

            result = subprocess.run([
                sys.executable, str(PROBE), "offline-guard",
                "--name", vm.name, "--vm-dir", str(vm),
                "--running-socket", str(running.path),
                "--executable", str(fake_cli), "--vm-lock", str(fake_lock),
                "--output", str(output),
            ], cwd=ROOT, capture_output=True, text=True)

            self.assertEqual(result.returncode, 0, result.stderr)
            summary = json.loads((output / "summary.json").read_text())
            self.assertEqual(summary["result"], "pass")
            self.assertEqual(summary["scenario"], "offline-guard")
            self.assertEqual(set(summary["commands"]),
                             {"export", "clone", "firmware_patch", "cfw_lock"})
            self.assertTrue(all(item["returncode"] == 1
                                for item in summary["commands"].values()))
            self.assertEqual([request["t"] for request in running.requests],
                             ["capabilities", "capabilities"])

    def test_survivor_accepts_stale_diagnostic_runtime_record_when_lock_is_free(self):
        with tempfile.TemporaryDirectory(prefix="vphone-f2-") as temporary:
            running = HostControlFixture(temporary, "running")
            running.start()
            self.addCleanup(running.stop)
            stopped_vm = Path(temporary) / "stopped-vm"
            stopped_vm.mkdir()
            (stopped_vm / ".vphone-runtime.json").write_text("{}")
            output = Path(temporary) / "evidence"

            result = subprocess.run([
                sys.executable, str(PROBE), "survivor",
                "--stopped-name", "vm-stopped", "--stopped-vm-dir", str(stopped_vm),
                "--running-name", "vm-running", "--running-socket", str(running.path),
                "--output", str(output),
            ], cwd=ROOT, capture_output=True, text=True)

            self.assertEqual(result.returncode, 0, result.stderr)
            summary = json.loads((output / "summary.json").read_text())
            self.assertTrue(summary["stale_runtime_record_present"])
            self.assertEqual([request["t"] for request in running.requests],
                             ["capabilities", "file_put", "file_get", "shell"])


if __name__ == "__main__":
    unittest.main()
