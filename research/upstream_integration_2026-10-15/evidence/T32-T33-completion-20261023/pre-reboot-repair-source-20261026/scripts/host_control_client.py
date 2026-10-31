"""Shared host-control socket client for acceptance scripts.

The host-control socket (`<vm>/vphone.sock`) accepts one newline-terminated JSON
request per connection and returns one newline-terminated JSON object. Callers
provide a recorder with `record(endpoint, request, response)`; it is invoked only
after a complete response is received.

`request` accepts an optional `timing` dict for latency measurements; see its
docstring for the recorded keys.
"""

import base64
from dataclasses import dataclass
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import socket
import stat
import time


MAXIMUM_MESSAGE_BYTES = 2 * 1024 * 1024


class AcceptanceFailure(RuntimeError):
    pass


class HostControlTransportError(AcceptanceFailure):
    """Connection, send or receive failure; `timed_out` marks a socket timeout."""

    def __init__(self, message, timed_out=False):
        super().__init__(message)
        self.timed_out = timed_out


@dataclass(frozen=True)
class Endpoint:
    name: str
    socket_path: Path


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


def request(endpoint: Endpoint, payload, recorder, timeout, *, timing=None):
    """Send one request and return the parsed response.

    When `timing` is a dict it receives `t_wall_utc` (request start, ISO-8601 UTC),
    `t_start_ns` (`time.perf_counter_ns()` taken before the connection is opened),
    and `t_connect_ns`, `t_send_ns`, `t_total_ns` as nanosecond offsets from
    `t_start_ns` measured after `connect()`, after `sendall()` and after the complete
    response line has been read. A failed request keeps the points reached so far and
    still receives `t_total_ns` (time until the failure). Request encoding happens
    before `t_start_ns` and is not measured.
    """
    encoded = json.dumps(payload, separators=(",", ":")).encode() + b"\n"
    if len(encoded) > MAXIMUM_MESSAGE_BYTES:
        raise AcceptanceFailure("host-control request exceeds 2 MiB")
    start = None
    if timing is not None:
        timing["t_wall_utc"] = datetime.now(timezone.utc).isoformat()
        start = time.perf_counter_ns()
        timing["t_start_ns"] = start
    try:
        with socket.socket(socket.AF_UNIX) as connection:
            connection.settimeout(timeout)
            connection.connect(str(endpoint.socket_path))
            if timing is not None:
                timing["t_connect_ns"] = time.perf_counter_ns() - start
            connection.sendall(encoded)
            if timing is not None:
                timing["t_send_ns"] = time.perf_counter_ns() - start
            response = read_line(connection)
    except (OSError, socket.timeout) as error:
        raise HostControlTransportError(
            f"{endpoint.name} host-control request failed: {error}",
            timed_out=isinstance(error, (socket.timeout, TimeoutError)),
        ) from error
    finally:
        if timing is not None:
            timing["t_total_ns"] = time.perf_counter_ns() - start
    recorder.record(endpoint, payload, response)
    return response


def require_ok(endpoint: Endpoint, command, response):
    if response.get("ok") is not True:
        raise AcceptanceFailure(
            f"{endpoint.name} {command} failed: {response.get('error', response)!r}"
        )


def decode_file(endpoint, response):
    require_ok(endpoint, "file_get", response)
    try:
        data = base64.b64decode(response["data"], validate=True)
    except (KeyError, TypeError, ValueError) as error:
        raise AcceptanceFailure(f"{endpoint.name} file_get returned invalid data") from error
    if response.get("size") != len(data):
        raise AcceptanceFailure(f"{endpoint.name} file_get size does not match payload")
    return data


def valid_pid(value):
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def running_app(endpoint: Endpoint, bundle_id, recorder, timeout):
    response = request(
        endpoint, {"t": "app_list", "filter": "running"}, recorder, timeout,
    )
    require_ok(endpoint, "app_list", response)
    apps = response.get("apps")
    if not isinstance(apps, list):
        raise AcceptanceFailure(f"{endpoint.name} app_list returned invalid apps")
    matches = [app for app in apps if isinstance(app, dict) and app.get("bundle_id") == bundle_id]
    if len(matches) > 1:
        raise AcceptanceFailure(f"{endpoint.name} app_list returned duplicate bundle IDs")
    if not matches:
        return None
    pid = matches[0].get("pid")
    if matches[0].get("state") != "running" or not valid_pid(pid):
        raise AcceptanceFailure(f"{endpoint.name} app_list returned invalid running identity")
    return {"bundle_id": bundle_id, "pid": pid, "name": matches[0].get("name", "")}


def camera_status(endpoint, generation, recorder, timeout, presentation_id=None):
    payload = {"t": "camera_status", "generation": generation}
    if presentation_id:
        payload["presentation_id"] = presentation_id
    response = request(endpoint, payload, recorder, timeout)
    require_ok(endpoint, "camera_status", response)
    if not isinstance(response.get("streaming"), bool):
        raise AcceptanceFailure(f"{endpoint.name} camera_status returned invalid streaming state")
    return response
