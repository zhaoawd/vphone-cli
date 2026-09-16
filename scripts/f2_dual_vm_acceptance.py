#!/usr/bin/env python3
"""Run explicit two-VM acceptance scenarios through per-VM host-control sockets."""

import argparse
import base64
from dataclasses import dataclass
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shlex
import socket
import stat
import sys
import uuid


MAXIMUM_MESSAGE_BYTES = 2 * 1024 * 1024


class AcceptanceFailure(RuntimeError):
    pass


@dataclass(frozen=True)
class Endpoint:
    name: str
    socket_path: Path


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


def endpoint(name, path):
    if not name or any(character in "\r\n\0" for character in name):
        raise AcceptanceFailure("instance names must be nonempty single-line strings")
    candidate = Path(path).expanduser().resolve(strict=True)
    info = candidate.stat()
    if not stat.S_ISSOCK(info.st_mode):
        raise AcceptanceFailure(f"host-control endpoint is not a Unix socket: {candidate}")
    if info.st_uid != os.geteuid():
        raise AcceptanceFailure(f"host-control socket is not owned by the current user: {candidate}")
    return Endpoint(name=name, socket_path=candidate)


def validate_distinct(left: Endpoint, right: Endpoint):
    if left.name == right.name:
        raise AcceptanceFailure("instance names must be distinct")
    left_info = left.socket_path.stat()
    right_info = right.socket_path.stat()
    if (left_info.st_dev, left_info.st_ino) == (right_info.st_dev, right_info.st_ino):
        raise AcceptanceFailure("instance sockets resolve to the same endpoint")


def read_line(connection):
    data = bytearray()
    while True:
        chunk = connection.recv(65536)
        if not chunk:
            raise AcceptanceFailure("host-control endpoint closed before a complete response")
        newline = chunk.find(b"\n")
        data.extend(chunk if newline < 0 else chunk[:newline])
        if len(data) > MAXIMUM_MESSAGE_BYTES:
            raise AcceptanceFailure("host-control response exceeds 2 MiB")
        if newline >= 0:
            break
    try:
        response = json.loads(data)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AcceptanceFailure(f"invalid host-control response: {error}") from error
    if not isinstance(response, dict):
        raise AcceptanceFailure("host-control response must be a JSON object")
    return response


def request(endpoint: Endpoint, payload, evidence: Evidence, timeout):
    encoded = json.dumps(payload, separators=(",", ":")).encode() + b"\n"
    if len(encoded) > MAXIMUM_MESSAGE_BYTES:
        raise AcceptanceFailure("host-control request exceeds 2 MiB")
    try:
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(timeout)
            connection.connect(str(endpoint.socket_path))
            connection.sendall(encoded)
            response = read_line(connection)
    except (OSError, socket.timeout) as error:
        raise AcceptanceFailure(f"{endpoint.name} host-control request failed: {error}") from error
    evidence.record(endpoint, payload, response)
    return response


def require_ok(endpoint: Endpoint, command, response):
    if response.get("ok") is not True:
        raise AcceptanceFailure(
            f"{endpoint.name} {command} failed: {response.get('error', response)!r}"
        )


def preflight(endpoint: Endpoint, evidence: Evidence, timeout):
    response = request(endpoint, {"t": "capabilities"}, evidence, timeout)
    require_ok(endpoint, "capabilities", response)
    if response.get("guest_connected") is not True:
        raise AcceptanceFailure(f"{endpoint.name} guest is not connected")
    commands = response.get("commands")
    required = ("file_get", "file_put", "shell")
    if not isinstance(commands, dict) or any(commands.get(name) is not True for name in required):
        raise AcceptanceFailure(f"{endpoint.name} does not expose required commands: {required}")


def marker(run_id, endpoint):
    return f"vphone-f2:{run_id}:{endpoint.name}".encode()


def decode_file(endpoint, response):
    require_ok(endpoint, "file_get", response)
    try:
        data = base64.b64decode(response["data"], validate=True)
    except (KeyError, TypeError, ValueError) as error:
        raise AcceptanceFailure(f"{endpoint.name} file_get returned invalid data") from error
    if response.get("size") != len(data):
        raise AcceptanceFailure(f"{endpoint.name} file_get size does not match payload")
    return data


def cleanup(endpoint: Endpoint, guest_path, evidence: Evidence, timeout):
    response = request(
        endpoint,
        {"t": "shell", "cmd": f"rm -f -- {shlex.quote(guest_path)}", "screen": False},
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
        if args.scenario == "file-isolation":
            left = endpoint(args.left_name, args.left_socket)
            right = endpoint(args.right_name, args.right_socket)
            validate_distinct(left, right)
            details = file_isolation(left, right, args.guest_path, evidence, args.timeout)
            summary = {
                "result": "pass", "scenario": args.scenario,
                "instances": [left.name, right.name], **details,
            }
            message = f"{left.name}, {right.name}"
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
