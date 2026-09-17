#!/usr/bin/env python3
"""Run explicit two-VM acceptance scenarios through per-VM host-control sockets."""

import argparse
import base64
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import uuid

from host_control_client import (
    AcceptanceFailure,
    Endpoint,
    camera_status,
    decode_file,
    endpoint,
    request,
    require_ok,
    running_app,
)


class Evidence:
    def __init__(self, output: Path):
        if output.exists():
            raise AcceptanceFailure(f"output already exists: {output}")
        output.mkdir(parents=True)
        self.output = output
        self.requests = output / "requests.jsonl"

    def record(self, endpoint: Endpoint, request, response):
        entry = {
            "time": datetime.now(timezone.utc).isoformat(),
            "instance": endpoint.name,
            "socket": str(endpoint.socket_path),
            "request": request,
            "response": response,
        }
        with self.requests.open("a") as stream:
            stream.write(json.dumps(entry, sort_keys=True) + "\n")

    def summarize(self, summary):
        (self.output / "summary.json").write_text(
            json.dumps(summary, indent=2, sort_keys=True) + "\n"
        )


def validate_distinct(left: Endpoint, right: Endpoint):
    if left.name == right.name:
        raise AcceptanceFailure("instance names must be distinct")
    left_info = left.socket_path.stat()
    right_info = right.socket_path.stat()
    if (left_info.st_dev, left_info.st_ino) == (right_info.st_dev, right_info.st_ino):
        raise AcceptanceFailure("instance sockets resolve to the same endpoint")


def preflight(endpoint: Endpoint, evidence: Evidence, timeout, required=None):
    response = request(endpoint, {"t": "capabilities"}, evidence, timeout)
    require_ok(endpoint, "capabilities", response)
    if response.get("guest_connected") is not True:
        raise AcceptanceFailure(f"{endpoint.name} guest is not connected")
    commands = response.get("commands")
    required = required or ("file_get", "file_put", "shell")
    if not isinstance(commands, dict) or any(commands.get(name) is not True for name in required):
        raise AcceptanceFailure(f"{endpoint.name} does not expose required commands: {required}")


def marker(run_id, endpoint):
    return f"vphone-f2:{run_id}:{endpoint.name}".encode()


def cleanup(endpoint: Endpoint, guest_path, evidence: Evidence, timeout):
    quoted_path = shlex.quote(guest_path)
    command = (
        f"if [ -x /bin/rm ]; then exec /bin/rm -f -- {quoted_path}; fi; "
        f"exec /var/jb/bin/rm -f -- {quoted_path}"
    )
    response = request(
        endpoint,
        {"t": "shell", "cmd": command, "screen": False},
        evidence,
        timeout,
    )
    require_ok(endpoint, "cleanup", response)
    if response.get("code") != 0:
        raise AcceptanceFailure(f"{endpoint.name} cleanup exited with {response.get('code')!r}")


def file_isolation(left, right, guest_path, evidence, timeout):
    if not guest_path.startswith("/tmp/vphone-f2-") or "\0" in guest_path:
        raise AcceptanceFailure("guest path must start with /tmp/vphone-f2- and contain no NUL")
    preflight(left, evidence, timeout)
    preflight(right, evidence, timeout)
    run_id = uuid.uuid4().hex
    expected = {left: marker(run_id, left), right: marker(run_id, right)}
    written = []
    primary_error = None
    try:
        for current in (left, right):
            payload = {
                "t": "file_put",
                "path": guest_path,
                "data_b64": base64.b64encode(expected[current]).decode(),
                "perm": "600",
            }
            response = request(current, payload, evidence, timeout)
            require_ok(current, "file_put", response)
            if response.get("size") != len(expected[current]):
                raise AcceptanceFailure(f"{current.name} file_put size does not match payload")
            written.append(current)
        observed = {}
        for current in (left, right):
            response = request(current, {"t": "file_get", "path": guest_path}, evidence, timeout)
            observed[current] = decode_file(current, response)
        for current in (left, right):
            if observed[current] != expected[current]:
                raise AcceptanceFailure(f"{current.name} returned another instance's file marker")
        if observed[left] == observed[right]:
            raise AcceptanceFailure("two instances returned the same file marker")
    except AcceptanceFailure as error:
        primary_error = error
    cleanup_errors = []
    for current in written:
        try:
            cleanup(current, guest_path, evidence, timeout)
        except AcceptanceFailure as error:
            cleanup_errors.append(str(error))
    if primary_error:
        if cleanup_errors:
            raise AcceptanceFailure(f"{primary_error}; cleanup failures: {cleanup_errors}")
        raise primary_error
    if cleanup_errors:
        raise AcceptanceFailure(f"cleanup failures: {cleanup_errors}")
    return {
        "marker_sha256": {
            current.name: hashlib.sha256(expected[current]).hexdigest()
            for current in (left, right)
        },
        "guest_path": guest_path,
    }


def app_isolation(left, right, bundle_id, evidence, timeout):
    if not bundle_id or any(character in "\r\n\0" for character in bundle_id):
        raise AcceptanceFailure("bundle ID must be a nonempty single-line string")
    required = ("app_launch", "app_terminate", "app_list")
    preflight(left, evidence, timeout, required)
    preflight(right, evidence, timeout, required)
    initial = {
        left: running_app(left, bundle_id, evidence, timeout),
        right: running_app(right, bundle_id, evidence, timeout),
    }
    if any(identity is not None for identity in initial.values()):
        raise AcceptanceFailure("target application must not be running before the scenario")
    launched = []
    observations = {}
    primary_error = None
    try:
        response = request(
            left, {"t": "app_launch", "bundle_id": bundle_id, "screen": False},
            evidence, timeout,
        )
        require_ok(left, "app_launch", response)
        launched.append(left)
        left_pid = response.get("pid")
        if not isinstance(left_pid, int) or isinstance(left_pid, bool) or left_pid <= 0:
            raise AcceptanceFailure(f"{left.name} app_launch returned invalid pid")
        observations["after_left_launch"] = {
            left.name: running_app(left, bundle_id, evidence, timeout),
            right.name: running_app(right, bundle_id, evidence, timeout),
        }
        if observations["after_left_launch"][left.name] is None:
            raise AcceptanceFailure(f"{left.name} did not retain the launched application")
        if observations["after_left_launch"][left.name]["pid"] != left_pid:
            raise AcceptanceFailure(f"{left.name} running pid does not match app_launch")
        if observations["after_left_launch"][right.name] is not None:
            raise AcceptanceFailure(f"{right.name} started the application after {left.name} launch")

        response = request(
            right, {"t": "app_launch", "bundle_id": bundle_id, "screen": False},
            evidence, timeout,
        )
        require_ok(right, "app_launch", response)
        launched.append(right)
        right_pid = response.get("pid")
        if not isinstance(right_pid, int) or isinstance(right_pid, bool) or right_pid <= 0:
            raise AcceptanceFailure(f"{right.name} app_launch returned invalid pid")
        observations["after_right_launch"] = {
            left.name: running_app(left, bundle_id, evidence, timeout),
            right.name: running_app(right, bundle_id, evidence, timeout),
        }
        if observations["after_right_launch"][left.name] is None:
            raise AcceptanceFailure(f"{left.name} application stopped after {right.name} launch")
        if observations["after_right_launch"][left.name]["pid"] != left_pid:
            raise AcceptanceFailure(f"{left.name} application pid changed after {right.name} launch")
        if observations["after_right_launch"][right.name] is None:
            raise AcceptanceFailure(f"{right.name} did not retain the launched application")
        if observations["after_right_launch"][right.name]["pid"] != right_pid:
            raise AcceptanceFailure(f"{right.name} running pid does not match app_launch")

        response = request(
            left, {"t": "app_terminate", "bundle_id": bundle_id, "screen": False},
            evidence, timeout,
        )
        require_ok(left, "app_terminate", response)
        launched.remove(left)
        observations["after_left_terminate"] = {
            left.name: running_app(left, bundle_id, evidence, timeout),
            right.name: running_app(right, bundle_id, evidence, timeout),
        }
        if observations["after_left_terminate"][left.name] is not None:
            raise AcceptanceFailure(f"{left.name} still reports the terminated application")
        if observations["after_left_terminate"][right.name] is None:
            raise AcceptanceFailure(f"{right.name} application stopped after {left.name} terminate")
        if observations["after_left_terminate"][right.name]["pid"] != right_pid:
            raise AcceptanceFailure(f"{right.name} application pid changed after {left.name} terminate")
    except AcceptanceFailure as error:
        primary_error = error
    cleanup_errors = []
    for current in reversed(launched):
        try:
            response = request(
                current, {"t": "app_terminate", "bundle_id": bundle_id, "screen": False},
                evidence, timeout,
            )
            require_ok(current, "app_terminate cleanup", response)
        except AcceptanceFailure as error:
            cleanup_errors.append(str(error))
    if primary_error:
        if cleanup_errors:
            raise AcceptanceFailure(f"{primary_error}; cleanup failures: {cleanup_errors}")
        raise primary_error
    if cleanup_errors:
        raise AcceptanceFailure(f"cleanup failures: {cleanup_errors}")
    return {
        "bundle_id": bundle_id,
        "initial_target_state": {current.name: initial[current] for current in (left, right)},
        "observations": observations,
    }


def camera_isolation(observer, presenter, source_path, consumer_bundle_id, evidence, timeout):
    source = Path(source_path).expanduser().resolve(strict=True)
    info = source.stat()
    if not source.is_file() or info.st_uid != os.geteuid():
        raise AcceptanceFailure(f"camera source must be a current-user-owned file: {source}")
    if not consumer_bundle_id or any(character in "\r\n\0" for character in consumer_bundle_id):
        raise AcceptanceFailure("consumer bundle ID must be a nonempty single-line string")
    preflight(observer, evidence, timeout, ("camera_status", "camera_stop"))
    preflight(
        presenter, evidence, timeout,
        ("camera_present", "camera_status", "camera_stop", "app_launch", "app_terminate", "app_list"),
    )
    generation = f"f2-{uuid.uuid4().hex}"
    initial_consumer = running_app(presenter, consumer_bundle_id, evidence, timeout)
    if initial_consumer is not None:
        raise AcceptanceFailure("camera consumer application must not be running before the scenario")
    initial = {
        observer: camera_status(observer, generation, evidence, timeout),
        presenter: camera_status(presenter, generation, evidence, timeout),
    }
    if any(status["streaming"] for status in initial.values()):
        raise AcceptanceFailure("camera sources must be stopped before the scenario")
    started = False
    consumer_started = False
    consumer_pid = None
    presentation_id = None
    observations = {}
    primary_error = None
    try:
        response = request(
            presenter,
            {"t": "app_launch", "bundle_id": consumer_bundle_id, "screen": False},
            evidence, timeout,
        )
        require_ok(presenter, "camera consumer app_launch", response)
        consumer_started = True
        consumer_pid = response.get("pid")
        if (not isinstance(consumer_pid, int) or isinstance(consumer_pid, bool)
                or consumer_pid <= 0):
            raise AcceptanceFailure(f"{presenter.name} camera consumer returned invalid pid")
        running_consumer = running_app(
            presenter, consumer_bundle_id, evidence, timeout,
        )
        if running_consumer is None or running_consumer["pid"] != consumer_pid:
            raise AcceptanceFailure(f"{presenter.name} camera consumer pid did not remain running")

        response = request(
            presenter,
            {
                "t": "camera_present", "source": "image", "path": str(source),
                "generation": generation, "role": "test", "fps": 8,
            },
            evidence, timeout,
        )
        if response.get("generation") == generation and response.get("streaming") is True:
            started = True
            presentation_id = response.get("presentation_id")
        require_ok(presenter, "camera_present", response)
        if not isinstance(presentation_id, str) or not presentation_id:
            raise AcceptanceFailure(f"{presenter.name} camera_present omitted presentation_id")
        receipt = response.get("transport_receipt")
        if (not isinstance(receipt, dict) or receipt.get("generation") != generation
                or receipt.get("presentation_id") != presentation_id):
            raise AcceptanceFailure(f"{presenter.name} camera_present returned an invalid receipt")
        observations["while_presenting"] = {
            observer.name: camera_status(observer, generation, evidence, timeout),
            presenter.name: camera_status(
                presenter, generation, evidence, timeout, presentation_id,
            ),
        }
        observer_status = observations["while_presenting"][observer.name]
        if observer_status["streaming"] or observer_status.get("generation") == generation:
            raise AcceptanceFailure(f"{observer.name} adopted {presenter.name} camera source")
        presenter_status = observations["while_presenting"][presenter.name]
        if (not presenter_status["streaming"]
                or presenter_status.get("generation") != generation
                or presenter_status.get("presentation_id") != presentation_id
                or presenter_status.get("matches_requested") is not True):
            raise AcceptanceFailure(f"{presenter.name} camera status lost presentation identity")
        status_receipt = presenter_status.get("transport_receipt")
        if (not isinstance(status_receipt, dict)
                or status_receipt.get("generation") != generation
                or status_receipt.get("presentation_id") != presentation_id):
            raise AcceptanceFailure(f"{presenter.name} camera status returned an invalid receipt")

        foreign_stop = request(
            observer,
            {
                "t": "camera_stop", "generation": generation,
                "presentation_id": presentation_id, "policy": "keep_last",
            },
            evidence, timeout,
        )
        if foreign_stop.get("ok") is not False:
            raise AcceptanceFailure(f"{observer.name} accepted another instance's camera identity")
        observations["foreign_stop"] = {observer.name: foreign_stop}
        presenter_after_foreign_stop = camera_status(
            presenter, generation, evidence, timeout, presentation_id,
        )
        if (not presenter_after_foreign_stop["streaming"]
                or presenter_after_foreign_stop.get("generation") != generation
                or presenter_after_foreign_stop.get("presentation_id") != presentation_id
                or presenter_after_foreign_stop.get("matches_requested") is not True):
            raise AcceptanceFailure(f"{presenter.name} changed after foreign camera stop")
        observations["after_foreign_stop"] = {
            presenter.name: presenter_after_foreign_stop,
        }

        response = request(
            presenter,
            {
                "t": "camera_stop", "generation": generation,
                "presentation_id": presentation_id, "policy": "keep_last",
            },
            evidence, timeout,
        )
        require_ok(presenter, "camera_stop", response)
        if response.get("streaming") is not False:
            raise AcceptanceFailure(f"{presenter.name} camera_stop did not report stopped state")
        started = False
        observations["after_stop"] = {
            observer.name: camera_status(observer, generation, evidence, timeout),
            presenter.name: camera_status(presenter, generation, evidence, timeout),
        }
        if any(status["streaming"] for status in observations["after_stop"].values()):
            raise AcceptanceFailure("a camera source remained active after stop")
    except AcceptanceFailure as error:
        primary_error = error
    cleanup_error = None
    if started:
        try:
            payload = {"t": "camera_stop", "generation": generation, "policy": "keep_last"}
            if presentation_id:
                payload["presentation_id"] = presentation_id
            response = request(presenter, payload, evidence, timeout)
            require_ok(presenter, "camera_stop cleanup", response)
        except AcceptanceFailure as error:
            cleanup_error = error
    consumer_cleanup_error = None
    if consumer_started:
        try:
            response = request(
                presenter,
                {"t": "app_terminate", "bundle_id": consumer_bundle_id, "screen": False},
                evidence, timeout,
            )
            require_ok(presenter, "camera consumer app_terminate", response)
            if running_app(presenter, consumer_bundle_id, evidence, timeout) is not None:
                raise AcceptanceFailure(f"{presenter.name} camera consumer remained running")
        except AcceptanceFailure as error:
            consumer_cleanup_error = error
    if primary_error:
        cleanup_errors = [str(error) for error in (cleanup_error, consumer_cleanup_error) if error]
        if cleanup_errors:
            raise AcceptanceFailure(f"{primary_error}; cleanup failures: {cleanup_errors}")
        raise primary_error
    if cleanup_error:
        raise cleanup_error
    if consumer_cleanup_error:
        raise consumer_cleanup_error
    return {
        "observer_instance": observer.name,
        "presenter_instance": presenter.name,
        "source_path": str(source),
        "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "consumer_bundle_id": consumer_bundle_id,
        "consumer_pid": consumer_pid,
        "generation": generation,
        "presentation_id": presentation_id,
        "observations": observations,
    }


def stopped_vm_directory(name, path):
    candidate = Path(path).expanduser().resolve(strict=True)
    info = candidate.stat()
    if not candidate.is_dir() or info.st_uid != os.geteuid():
        raise AcceptanceFailure(f"{name} VM directory must be a current-user-owned directory: {candidate}")
    for relative in ("vphone.sock", ".firmware-transaction"):
        if (candidate / relative).exists():
            raise AcceptanceFailure(f"{name} left runtime state after stop: {relative}")
    stale_runtime_record_present = (candidate / ".vphone-runtime.json").exists()
    descriptor = os.open(candidate, os.O_RDONLY)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise AcceptanceFailure(f"{name} VM directory lock is still held") from error
    finally:
        os.close(descriptor)
    return candidate, stale_runtime_record_present


def run_refused_command(label, command, cwd, timeout):
    try:
        result = subprocess.run(
            [str(part) for part in command], cwd=cwd, capture_output=True,
            text=True, timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        raise AcceptanceFailure(f"{label} did not refuse within {timeout:g}s") from error
    if result.returncode == 0:
        raise AcceptanceFailure(f"{label} unexpectedly succeeded")
    return {
        "command": [str(part) for part in command],
        "returncode": result.returncode,
        "stdout": result.stdout,
        "stderr": result.stderr,
    }


def offline_guard(name, directory, running, executable, vm_lock, evidence, timeout):
    vm = Path(directory).expanduser().resolve(strict=True)
    if vm.name != name or not vm.is_dir() or vm.stat().st_uid != os.geteuid():
        raise AcceptanceFailure("VM name and current-user-owned directory must match")
    binary = Path(executable).expanduser().resolve(strict=True)
    lock_script = Path(vm_lock).expanduser().resolve(strict=True)
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise AcceptanceFailure(f"vphone executable is not executable: {binary}")
    if not lock_script.is_file():
        raise AcceptanceFailure(f"VM lock script is not a file: {lock_script}")
    try:
        running.socket_path.relative_to(vm)
    except ValueError as error:
        raise AcceptanceFailure("running socket does not belong to the guarded VM") from error
    preflight(running, evidence, timeout)
    runtime = vm / ".vphone-runtime.json"
    if not runtime.is_file():
        raise AcceptanceFailure("running VM has no runtime record")
    runtime_before = hashlib.sha256(runtime.read_bytes()).hexdigest()
    config_before = hashlib.sha256((vm / "config.plist").read_bytes()).hexdigest()
    mount_names_before = sorted(path.name for path in vm.glob(".cfw_mount.*"))
    if (vm / ".firmware-transaction").exists():
        raise AcceptanceFailure("running VM has a pending firmware transaction")

    run_id = uuid.uuid4().hex
    archive = Path("/tmp") / f"vphone-f2-guard-{run_id}.tzst"
    clone_name = f"{name}-f2-guard-{run_id}"
    clone = vm.parent / clone_name
    if archive.exists() or clone.exists():
        raise AcceptanceFailure("generated offline-guard output path already exists")
    commands = {
        "export": [
            binary, "vm", "export", "--library-root", vm.parent, name,
            "--out", archive,
        ],
        "clone": [
            binary, "vm", "clone", "--library-root", vm.parent, name, clone_name,
        ],
        "firmware_patch": [
            binary, "fw", "patch", "--library-root", vm.parent, name,
            "--variant", "exp", "--quiet",
        ],
        "cfw_lock": [
            sys.executable, lock_script, vm, "cfw", "--", "/usr/bin/true",
        ],
    }
    results = {
        label: run_refused_command(label, command, vm.parent, timeout)
        for label, command in commands.items()
    }
    for label in ("export", "clone", "firmware_patch"):
        combined = results[label]["stdout"] + results[label]["stderr"]
        if "busy" not in combined:
            raise AcceptanceFailure(f"{label} did not report the shared busy guard")
    if "VM lock unavailable" not in results["cfw_lock"]["stderr"]:
        raise AcceptanceFailure("cfw lock entry did not report lock refusal")
    if archive.exists() or clone.exists():
        raise AcceptanceFailure("a refused offline operation left an output path")
    if (vm / ".firmware-transaction").exists():
        raise AcceptanceFailure("a refused offline operation left a firmware transaction")
    if sorted(path.name for path in vm.glob(".cfw_mount.*")) != mount_names_before:
        raise AcceptanceFailure("a refused offline operation changed CFW mount paths")
    if hashlib.sha256(runtime.read_bytes()).hexdigest() != runtime_before:
        raise AcceptanceFailure("a refused offline operation changed the runtime record")
    if hashlib.sha256((vm / "config.plist").read_bytes()).hexdigest() != config_before:
        raise AcceptanceFailure("a refused offline operation changed config.plist")
    preflight(running, evidence, timeout)
    return {
        "instance": name,
        "vm_dir": str(vm),
        "runtime_sha256": runtime_before,
        "config_sha256": config_before,
        "archive_path": str(archive),
        "clone_path": str(clone),
        "commands": results,
    }


def survivor(stopped_name, stopped_directory, running, guest_path, evidence, timeout):
    if stopped_name == running.name:
        raise AcceptanceFailure("stopped and running instance names must be distinct")
    if not guest_path.startswith("/tmp/vphone-f2-") or "\0" in guest_path:
        raise AcceptanceFailure("guest path must start with /tmp/vphone-f2- and contain no NUL")
    stopped, stale_runtime_record_present = stopped_vm_directory(stopped_name, stopped_directory)
    try:
        running.socket_path.relative_to(stopped)
    except ValueError:
        pass
    else:
        raise AcceptanceFailure("running socket belongs to the stopped VM directory")
    preflight(running, evidence, timeout)
    expected = marker(uuid.uuid4().hex, running)
    written = False
    primary_error = None
    try:
        payload = {
            "t": "file_put",
            "path": guest_path,
            "data_b64": base64.b64encode(expected).decode(),
            "perm": "600",
        }
        response = request(running, payload, evidence, timeout)
        require_ok(running, "file_put", response)
        if response.get("size") != len(expected):
            raise AcceptanceFailure(f"{running.name} file_put size does not match payload")
        written = True
        response = request(running, {"t": "file_get", "path": guest_path}, evidence, timeout)
        observed = decode_file(running, response)
        if observed != expected:
            raise AcceptanceFailure(f"{running.name} returned an incorrect file marker")
    except AcceptanceFailure as error:
        primary_error = error
    cleanup_error = None
    if written:
        try:
            cleanup(running, guest_path, evidence, timeout)
        except AcceptanceFailure as error:
            cleanup_error = error
    if primary_error:
        if cleanup_error:
            raise AcceptanceFailure(f"{primary_error}; cleanup failure: {cleanup_error}")
        raise primary_error
    if cleanup_error:
        raise cleanup_error
    return {
        "stopped_instance": stopped_name,
        "stopped_vm_dir": str(stopped),
        "stale_runtime_record_present": stale_runtime_record_present,
        "running_instance": running.name,
        "guest_path": guest_path,
        "marker_sha256": hashlib.sha256(expected).hexdigest(),
    }


def parse_args():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="scenario", required=True)
    files = subparsers.add_parser("file-isolation", help="write distinct markers to the same guest path")
    files.add_argument("--left-name", required=True)
    files.add_argument("--left-socket", type=Path, required=True)
    files.add_argument("--right-name", required=True)
    files.add_argument("--right-socket", type=Path, required=True)
    files.add_argument("--guest-path", default=f"/tmp/vphone-f2-{uuid.uuid4().hex}.txt")
    files.add_argument("--output", type=Path, required=True)
    files.add_argument("--timeout", type=float, default=20)
    apps = subparsers.add_parser(
        "app-isolation", help="launch and terminate an application through distinct endpoints"
    )
    apps.add_argument("--left-name", required=True)
    apps.add_argument("--left-socket", type=Path, required=True)
    apps.add_argument("--right-name", required=True)
    apps.add_argument("--right-socket", type=Path, required=True)
    apps.add_argument("--bundle-id", default="com.apple.Preferences")
    apps.add_argument("--output", type=Path, required=True)
    apps.add_argument("--timeout", type=float, default=20)
    camera = subparsers.add_parser(
        "camera-isolation", help="present on one endpoint and verify the observer stays stopped"
    )
    camera.add_argument("--observer-name", required=True)
    camera.add_argument("--observer-socket", type=Path, required=True)
    camera.add_argument("--presenter-name", required=True)
    camera.add_argument("--presenter-socket", type=Path, required=True)
    camera.add_argument("--source-path", type=Path, required=True)
    camera.add_argument("--consumer-bundle-id", default="com.apple.camera")
    camera.add_argument("--output", type=Path, required=True)
    camera.add_argument("--timeout", type=float, default=20)
    guard = subparsers.add_parser(
        "offline-guard", help="verify running-VM export, clone, patch and CFW lock refusal"
    )
    guard.add_argument("--name", required=True)
    guard.add_argument("--vm-dir", type=Path, required=True)
    guard.add_argument("--running-socket", type=Path, required=True)
    guard.add_argument("--executable", type=Path, required=True)
    guard.add_argument("--vm-lock", type=Path, required=True)
    guard.add_argument("--output", type=Path, required=True)
    guard.add_argument("--timeout", type=float, default=20)
    survivor_parser = subparsers.add_parser(
        "survivor", help="check stopped-instance cleanup and exercise the surviving instance"
    )
    survivor_parser.add_argument("--stopped-name", required=True)
    survivor_parser.add_argument("--stopped-vm-dir", type=Path, required=True)
    survivor_parser.add_argument("--running-name", required=True)
    survivor_parser.add_argument("--running-socket", type=Path, required=True)
    survivor_parser.add_argument("--guest-path", default=f"/tmp/vphone-f2-{uuid.uuid4().hex}.txt")
    survivor_parser.add_argument("--output", type=Path, required=True)
    survivor_parser.add_argument("--timeout", type=float, default=20)
    return parser.parse_args()


def main():
    args = parse_args()
    evidence = None
    try:
        if args.timeout <= 0 or args.timeout > 120:
            raise AcceptanceFailure("timeout must be in (0, 120]")
        evidence = Evidence(args.output.resolve())
        if args.scenario in ("file-isolation", "app-isolation"):
            left = endpoint(args.left_name, args.left_socket)
            right = endpoint(args.right_name, args.right_socket)
            validate_distinct(left, right)
            if args.scenario == "file-isolation":
                details = file_isolation(left, right, args.guest_path, evidence, args.timeout)
            else:
                details = app_isolation(left, right, args.bundle_id, evidence, args.timeout)
            summary = {
                "result": "pass", "scenario": args.scenario,
                "instances": [left.name, right.name], **details,
            }
            message = f"{left.name}, {right.name}"
        elif args.scenario == "camera-isolation":
            observer = endpoint(args.observer_name, args.observer_socket)
            presenter = endpoint(args.presenter_name, args.presenter_socket)
            validate_distinct(observer, presenter)
            details = camera_isolation(
                observer, presenter, args.source_path, args.consumer_bundle_id,
                evidence, args.timeout,
            )
            summary = {"result": "pass", "scenario": args.scenario, **details}
            message = f"{presenter.name} presented; {observer.name} stayed stopped"
        elif args.scenario == "offline-guard":
            running = endpoint(args.name, args.running_socket)
            details = offline_guard(
                args.name, args.vm_dir, running, args.executable, args.vm_lock,
                evidence, args.timeout,
            )
            summary = {"result": "pass", "scenario": args.scenario, **details}
            message = f"{running.name} refused offline operations and stayed usable"
        else:
            running = endpoint(args.running_name, args.running_socket)
            details = survivor(
                args.stopped_name, args.stopped_vm_dir, running,
                args.guest_path, evidence, args.timeout,
            )
            summary = {"result": "pass", "scenario": args.scenario, **details}
            message = f"{args.stopped_name} stopped; {running.name} usable"
        evidence.summarize(summary)
        print(f"PASS {args.scenario}: {message}")
        return 0
    except (AcceptanceFailure, OSError) as error:
        if evidence:
            evidence.summarize({"result": "fail", "scenario": args.scenario, "error": str(error)})
        print(f"FAIL {args.scenario}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
