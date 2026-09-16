import base64
import json
from pathlib import Path
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
                "commands": {"file_get": True, "file_put": True, "shell": True},
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
            path = request["cmd"].removeprefix("rm -f -- ")
            self.files.pop(path, None)
            return {"ok": True, "stdout": "", "stderr": "", "code": 0}
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
