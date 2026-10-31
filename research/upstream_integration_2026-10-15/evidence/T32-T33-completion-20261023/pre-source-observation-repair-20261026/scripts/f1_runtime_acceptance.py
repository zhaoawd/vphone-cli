#!/usr/bin/env python3
"""Run F1 single-instance runtime acceptance steps through one host-control socket.

The script never starts, stops or reconfigures a VM. It sends host-control
requests to the given socket and writes evidence only below --out. Step IDs,
criteria and statuses follow research/f1_e2e_matrix_plan_2026-09-17.md §3/§5.
"""

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shlex
import sys
import time
import uuid

from f3_common import (
    git_state,
    host_info,
    redact,
    redact_argv,
    sha256_file,
    utc_now,
)
from host_control_client import (
    AcceptanceFailure,
    HostControlTransportError,
    decode_file,
    endpoint as resolve_endpoint,
    request as host_request,
    running_app,
    valid_pid,
)


SCHEMA_VERSION = 1
STATUSES = ("passed", "failed", "partial", "blocked", "not_applicable", "not_run")
VARIANTS = ("less", "regular", "dev", "jb", "exp")
STEP_TITLES = {
    "preflight": "capabilities preflight",
    "S4": "second boot marker and boottime",
    "S5": "GUI input",
    "S6": "file put/get/list/rename/delete",
    "S7": "application lifecycle",
    "S8": "DDI",
    "S9": "location protocol layer",
    "S10": "camera",
    "S11": "Frida client",
    "S12": "EXP identity/graphics/compute",
}
STEP_ORDER = tuple(STEP_TITLES)
EXP_INJECTED_FILES = (
    "/var/jb/usr/lib/libvcamcaptured.dylib",
    "/var/jb/Library/MobileSubstrate/DynamicLibraries/libcamfix.dylib",
)
SYSTEM_VERSION_PLIST = "/System/Library/CoreServices/SystemVersion.plist"
LOCATION_OWNER = "vphone-f1-acceptance"
TOOL_PATHS = {
    "sysctl": ("/usr/sbin/sysctl", "/var/jb/usr/sbin/sysctl"),
    "ls": ("/bin/ls", "/var/jb/bin/ls", "/var/jb/usr/bin/ls"),
    "mv": ("/bin/mv", "/var/jb/bin/mv", "/var/jb/usr/bin/mv"),
    "rm": ("/bin/rm", "/var/jb/bin/rm", "/var/jb/usr/bin/rm"),
}


# MARK: - Evidence helpers (utc_now, sha256_file, redact, redact_argv,
# git_state, host_info live in scripts/f3_common.py)


class StepFailed(Exception):
    def __init__(self, stage, reason, classification=None):
        super().__init__(reason)
        self.stage = stage
        self.classification = classification


class StepBlocked(Exception):
    def __init__(self, stage, reason):
        super().__init__(reason)
        self.stage = stage


class StepNotApplicable(Exception):
    pass


class StepRecorder:
    def __init__(self, path):
        self.path = path

    def record(self, endpoint, request, response):
        entry = {
            "time": utc_now(),
            "instance": endpoint.name,
            "socket": str(endpoint.socket_path),
            "request": redact(request),
            "response": redact(response),
        }
        with self.path.open("a") as stream:
            stream.write(json.dumps(entry, sort_keys=True) + "\n")

    def record_error(self, endpoint, request, error):
        entry = {
            "time": utc_now(),
            "instance": endpoint.name,
            "socket": str(endpoint.socket_path),
            "request": redact(request),
            "error": str(error),
            "timed_out": getattr(error, "timed_out", False),
        }
        with self.path.open("a") as stream:
            stream.write(json.dumps(entry, sort_keys=True) + "\n")


class Step:
    def __init__(self, run, step_id):
        self.run = run
        self.id = step_id
        self.directory = run.output / "steps" / step_id
        self.directory.mkdir(parents=True)
        self.recorder = StepRecorder(self.directory / "requests.jsonl")
        self.started_at = utc_now()
        self.commands = []
        self.checks = []
        self.observed = {}
        self.evidence = []
        self.manual = []
        self.criteria = ""
        self.expectation = "present"
        self.stage = "setup"
        self.cleanups = []
        self.override = None

    # Requests -------------------------------------------------------------
    def call(self, stage, payload):
        self.stage = stage
        self.commands.append(redact(payload))
        try:
            return host_request(self.run.endpoint, payload, self.recorder, self.run.timeout)
        except AcceptanceFailure as error:
            self.recorder.record_error(self.run.endpoint, payload, error)
            raise

    def ok(self, stage, payload):
        response = self.call(stage, payload)
        if response.get("ok") is not True:
            error = str(response.get("error", response))
            if "not connected" in error:
                raise StepBlocked(stage, f"{payload['t']}: {error}")
            raise StepFailed(stage, f"{payload['t']} returned ok=false: {error}",
                             classify_error(payload["t"], error))
        return response

    # Results --------------------------------------------------------------
    def check(self, name, status, detail, optional=False, **extra):
        assert status in STATUSES, status
        entry = {"name": name, "status": status, "detail": detail}
        if optional:
            entry["optional"] = True
        entry.update(extra)
        self.checks.append(entry)
        return entry

    def add_evidence(self, path):
        path = Path(path)
        if path.is_file():
            self.evidence.append({"path": str(path.relative_to(self.run.output)),
                                  "sha256": sha256_file(path)})

    # Capabilities ---------------------------------------------------------
    def has(self, *names):
        commands = (self.run.capabilities or {}).get("commands")
        return isinstance(commands, dict) and all(commands.get(name) is True for name in names)

    def require(self, names, capability):
        capabilities = self.run.capabilities
        if capabilities is None:
            raise StepBlocked("capabilities", f"preflight did not return capabilities: {self.run.preflight_error}")
        commands = capabilities.get("commands") if isinstance(capabilities.get("commands"), dict) else {}
        missing = [name for name in names if commands.get(name) is not True]
        if not missing:
            return
        guest_caps = capabilities.get("guest_capabilities")
        if (capabilities.get("guest_connected") is True and capability
                and isinstance(guest_caps, list) and capability not in guest_caps):
            raise StepNotApplicable(
                f"guest does not declare capability {capability!r}; unavailable commands: {missing}")
        raise StepBlocked("capabilities", f"host-control commands unavailable: {missing}")


def classify_error(command, error):
    """Stable labels for known guest failure texts so the matrix can separate them."""
    if command == "app_launch" and "uiopen unavailable" in error:
        return "capability_declared_but_uiopen_missing"
    return None


def launch_not_declared(run):
    """Reason string when an apps_v2 guest omits app_launch, else None.

    apps_v2 guests declare app_launch only when uiopen is executable; guests without
    apps_v2 predate the split and their `apps` capability still implies app_launch.
    """
    capabilities = run.capabilities or {}
    guest_caps = capabilities.get("guest_capabilities")
    if (capabilities.get("guest_connected") is True and isinstance(guest_caps, list)
            and "apps_v2" in guest_caps and "app_launch" not in guest_caps):
        return "guest declares apps_v2 without app_launch (uiopen not executable on guest)"
    return None


def screen_note(run):
    available = (run.capabilities or {}).get("screen_available")
    if available is False:
        return "screen_available=false (no VM window; e.g. headless launch)"
    return f"screen_available={available!r}"


def aggregate(checks):
    considered = [check["status"] for check in checks
                  if check["status"] != "not_applicable"
                  and not (check.get("optional") and check["status"] == "not_run")]
    if not checks:
        return "not_run"
    if "failed" in considered:
        return "failed"
    if not considered:
        return "not_applicable"
    if all(status == "passed" for status in considered):
        return "passed"
    if "passed" in considered or "partial" in considered:
        return "partial"
    if "blocked" in considered:
        return "blocked"
    return "not_run"


# MARK: - Guest helpers

def guest_tool(tool, *arguments):
    quoted = " ".join(shlex.quote(str(argument)) for argument in arguments)
    parts = [f"if [ -x {path} ]; then exec {path} {quoted}; fi" for path in TOOL_PATHS[tool]]
    parts.append(f"echo 'vphone-f1: {tool} not found' >&2; exit 127")
    return "; ".join(parts)


def shell(step, stage, command):
    response = step.ok(stage, {"t": "shell", "cmd": command, "screen": False,
                               "timeout_ms": int(step.run.timeout * 1000)})
    if response.get("timed_out") is True:
        raise StepBlocked(stage, "guest shell command timed out")
    return response


def tool_missing(response):
    return response.get("code") == 127


def file_absent(step, stage, path, save_name=None):
    """True when file_get reports ENOENT/ENOTDIR, False when the file exists."""
    payload = {"t": "file_get", "path": path}
    if save_name:
        payload["save"] = str(step.directory / save_name)
    response = step.call(stage, payload)
    if response.get("ok") is True:
        if save_name:
            step.add_evidence(step.directory / save_name)
        return False
    error = str(response.get("error", ""))
    if "No such file or directory" in error or "Not a directory" in error:
        return True
    if "not connected" in error:
        raise StepBlocked(stage, f"file_get: {error}")
    raise StepBlocked(stage, f"file_get error does not identify file absence: {error}")


def read_sysctl(step, stage, name):
    """Return ("present", value), ("absent", stderr) or ("unavailable", reason)."""
    response = shell(step, stage, guest_tool("sysctl", "-n", name))
    stdout = str(response.get("stdout", "")).strip()
    stderr = str(response.get("stderr", "")).strip()
    if tool_missing(response):
        return "unavailable", f"sysctl not found on guest: {stderr}"
    if "unknown oid" in stderr or "No such file or directory" in stderr:
        return "absent", stderr
    if response.get("code") == 0 and stdout:
        return "present", stdout
    return "unavailable", f"unclassified sysctl result code={response.get('code')!r} stderr={stderr!r}"


def read_boottime(step, stage):
    if not step.has("shell"):
        return None, "shell command unavailable; kern.boottime has no file-interface source"
    kind, value = read_sysctl(step, stage, "kern.boottime")
    if kind != "present":
        return None, value
    match = re.search(r"sec\s*=\s*(\d+),\s*usec\s*=\s*(\d+)", value)
    if not match:
        return None, f"kern.boottime output not parseable: {value!r}"
    return {"sec": int(match.group(1)), "usec": int(match.group(2)), "raw": value}, None


# MARK: - Steps

def step_preflight(run, step):
    step.criteria = ("capabilities returns ok=true, guest_connected=true, boot_mode=normal and a "
                     "commands object; capability declarations are recorded and do not count as "
                     "functional passes")
    if run.endpoint is None:
        raise StepBlocked("socket", run.preflight_error)
    response = step.call("capabilities", {"t": "capabilities"})
    step.observed = {
        "protocol_version": response.get("protocol_version"),
        "boot_mode": response.get("boot_mode"),
        "guest_connected": response.get("guest_connected"),
        "guest_capabilities": response.get("guest_capabilities"),
        "screen_available": response.get("screen_available"),
        "commands_available": sorted(name for name, value in (response.get("commands") or {}).items()
                                     if value is True) if isinstance(response.get("commands"), dict) else None,
        "commands_unavailable": sorted(name for name, value in (response.get("commands") or {}).items()
                                       if value is not True) if isinstance(response.get("commands"), dict) else None,
        "limits": response.get("limits"),
    }
    if response.get("ok") is not True:
        run.preflight_error = f"capabilities returned ok=false: {response.get('error')!r}"
        raise StepFailed("capabilities", run.preflight_error)
    if not isinstance(response.get("commands"), dict):
        run.preflight_error = "capabilities response has no commands object"
        raise StepFailed("capabilities", run.preflight_error)
    run.capabilities = response
    step.check("capabilities_response", "passed", "capabilities returned a commands object")
    if response.get("boot_mode") != "normal":
        step.check("boot_mode", "failed", f"boot_mode={response.get('boot_mode')!r}")
    if response.get("guest_connected") is not True:
        step.check("guest_connected", "failed", "guest_connected is not true")
    else:
        step.check("guest_connected", "passed", "guest_connected=true")


RUNTIME_RECORD = ".vphone-runtime.json"
HOST_RESTART_NOTE = ("host process restart evidence from <bundle>/.vphone-runtime.json; "
                     "not equivalent to guest kernel boottime")


def read_runtime_record(run):
    """Read-only snapshot of the VM bundle runtime record (pid/startedAt of the host process)."""
    if not run.args.bundle:
        return None, "no --bundle given"
    path = Path(run.args.bundle).expanduser().resolve() / RUNTIME_RECORD
    try:
        raw = path.read_bytes()
        record = json.loads(raw)
    except (OSError, ValueError) as error:
        return None, f"cannot read {path}: {error}"
    if not isinstance(record, dict):
        return None, f"{path} is not a JSON object"
    pid, started = record.get("pid"), record.get("startedAt")
    if not valid_pid(pid) or not isinstance(started, str) or not started:
        return None, f"{path} lacks pid/startedAt"
    return {"path": str(path), "sha256": hashlib.sha256(raw).hexdigest(), "pid": pid,
            "started_at": started, "instance_id": record.get("instanceID"),
            "operation": record.get("operation"), "bundle_path": record.get("bundlePath"),
            "note": HOST_RESTART_NOTE}, None


def step_s4(run, step):
    step.criteria = ("write phase stores a marker under /var/mobile/Library and records restart baselines; "
                     "verify phase after a second boot reads the marker back byte-identically and "
                     "observes a restart: kern.boottime changed (preferred, needs shell), otherwise "
                     "--bundle runtime record pid and startedAt both changed (host process restart "
                     "evidence, not guest kernel boottime)")
    step.manual = ["vm stop and vm launch between --second-boot-phase write and verify"]
    phase = run.args.second_boot_phase
    if not phase:
        step.override = ("not_run", "requires --second-boot-phase write|verify")
        return
    step.observed["phase"] = phase
    step.require(("file_put", "file_get"), "file")
    if phase == "write":
        marker = f"vphone-f1:{uuid.uuid4().hex}:{run.args.combo}:{run.args.variant}\n".encode()
        path = run.args.marker_path or f"/var/mobile/Library/f1-{run.run_id}.txt"
        response = step.ok("marker_put", {"t": "file_put", "path": path,
                                          "data_b64": base64.b64encode(marker).decode(), "perm": "644"})
        if response.get("size") != len(marker):
            raise StepFailed("marker_put", "file_put size does not match marker")
        observed = decode_file(run.endpoint, step.ok("marker_get", {"t": "file_get", "path": path}))
        if observed != marker:
            step.check("marker_write", "failed", "first-boot readback differs from written marker")
        else:
            step.check("marker_write", "passed", "first-boot readback matches marker")
        boottime, boottime_reason = read_boottime(step, "boottime")
        runtime, runtime_reason = read_runtime_record(run)
        if boottime is None and runtime is None:
            step.check("restart_baseline_recorded", "blocked",
                       f"kern.boottime: {boottime_reason}; runtime record: {runtime_reason}")
        else:
            sources = [name for name, value in (("kern.boottime", boottime),
                                                ("host_runtime_record", runtime)) if value]
            step.check("restart_baseline_recorded", "passed", f"recorded {', '.join(sources)}")
        state = {
            "schema_version": SCHEMA_VERSION, "run_id": run.run_id, "combo": run.args.combo,
            "variant": run.args.variant, "marker_path": path,
            "marker_b64": base64.b64encode(marker).decode(),
            "marker_sha256": hashlib.sha256(marker).hexdigest(),
            "boottime": boottime, "boottime_unavailable": boottime_reason,
            "host_runtime": runtime, "host_runtime_unavailable": runtime_reason,
            "written_at": utc_now(),
        }
        state_path = step.directory / "s4_state.json"
        state_path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
        step.add_evidence(state_path)
        step.observed.update({"marker_path": path, "marker_sha256": state["marker_sha256"],
                              "boottime": boottime, "boottime_unavailable": boottime_reason,
                              "host_runtime": runtime, "host_runtime_unavailable": runtime_reason,
                              "state_file": str(state_path.relative_to(run.output))})
        step.check("second_boot_verify", "not_run",
                   "run again after the second boot with --second-boot-phase verify --s4-state "
                   f"{state_path}")
        return

    if not run.args.s4_state:
        raise StepBlocked("state", "verify phase requires --s4-state from the write phase")
    try:
        state = json.loads(Path(run.args.s4_state).read_text())
        marker = base64.b64decode(state["marker_b64"], validate=True)
        path = state["marker_path"]
    except (OSError, ValueError, KeyError, TypeError) as error:
        raise StepBlocked("state", f"cannot read S4 state: {error}") from error
    if state.get("combo") != run.args.combo or state.get("variant") != run.args.variant:
        raise StepFailed("state", "S4 state belongs to a different combo or variant")
    step.observed.update({"write_run_id": state.get("run_id"), "marker_path": path,
                          "marker_sha256": state.get("marker_sha256"),
                          "first_boottime": state.get("boottime"),
                          "first_host_runtime": state.get("host_runtime")})
    response = step.call("marker_get", {"t": "file_get", "path": path})
    if response.get("ok") is not True:
        error = str(response.get("error", ""))
        if "not connected" in error:
            raise StepBlocked("marker_get", error)
        step.check("marker_readback", "failed", f"marker not readable after second boot: {error}")
    else:
        observed = decode_file(run.endpoint, response)
        step.observed["readback_sha256"] = hashlib.sha256(observed).hexdigest()
        if observed == marker:
            step.check("marker_readback", "passed", "marker bytes identical after second boot")
        else:
            step.check("marker_readback", "failed", "marker bytes differ after second boot")

    boottime, boottime_reason = read_boottime(step, "boottime")
    step.observed["second_boottime"] = boottime
    first_boot = state.get("boottime")
    boot_result = None
    if boottime is not None and isinstance(first_boot, dict):
        changed = (first_boot.get("sec"), first_boot.get("usec")) != (boottime["sec"], boottime["usec"])
        boot_result = ("passed", "kern.boottime changed between boots") if changed else \
            ("failed", "kern.boottime unchanged; no guest reboot observed")
        step.observed["boottime_result"] = boot_result[0]
    elif boottime is not None:
        boottime_reason = "write phase did not record kern.boottime"

    runtime, runtime_reason = read_runtime_record(run)
    step.observed["second_host_runtime"] = runtime
    first_runtime = state.get("host_runtime")
    host_result = None
    if runtime is not None and isinstance(first_runtime, dict):
        pid_changed = first_runtime.get("pid") != runtime["pid"]
        started_changed = first_runtime.get("started_at") != runtime["started_at"]
        host_result = ("passed", "runtime record pid and startedAt both changed") \
            if pid_changed and started_changed else \
            ("failed", f"runtime record not restarted (pid_changed={pid_changed}, "
                       f"started_at_changed={started_changed})")
        step.observed["host_runtime_result"] = host_result[0]
    elif runtime is not None:
        runtime_reason = "write phase did not record the runtime record"
    step.observed["host_runtime_note"] = HOST_RESTART_NOTE

    if boot_result is not None:
        step.check("restart_evidence", boot_result[0], boot_result[1], source="kern.boottime")
    elif host_result is not None:
        step.check("restart_evidence", host_result[0], f"{host_result[1]}; {HOST_RESTART_NOTE}",
                   source="host_runtime_record")
    else:
        step.check("restart_evidence", "blocked",
                   f"kern.boottime: {boottime_reason}; runtime record: {runtime_reason}")
    if step.has("shell"):
        cleanup = shell(step, "marker_cleanup", guest_tool("rm", "-f", "--", path))
        step.observed["marker_cleanup_code"] = cleanup.get("code")


def step_s6(run, step):
    step.criteria = ("file_put/file_get readback digest matches; listing contains the file; after rename "
                     "the new path matches and the old path is absent; after delete file_get reports "
                     "absence. The host socket has no file_list/file_rename/file_delete commands, so "
                     "list/rename/delete use guest shell tools")
    step.require(("file_put", "file_get"), "file")
    name = f"vphone-f1-{uuid.uuid4().hex}"
    source = f"/tmp/{name}.txt"
    target = f"/tmp/{name}-renamed.txt"
    data = f"vphone-f1-s6:{run.run_id}:{uuid.uuid4().hex}\n".encode()
    digest = hashlib.sha256(data).hexdigest()
    step.observed.update({"source_path": source, "renamed_path": target, "sha256": digest})
    response = step.ok("put", {"t": "file_put", "path": source,
                               "data_b64": base64.b64encode(data).decode(), "perm": "600"})
    if step.has("shell"):
        step.cleanups.append(("cleanup", lambda: shell(step, "cleanup",
                                                       guest_tool("rm", "-f", "--", source, target))))
    if response.get("size") != len(data):
        raise StepFailed("put", "file_put size does not match payload")
    observed = decode_file(run.endpoint, step.ok("get", {"t": "file_get", "path": source}))
    if hashlib.sha256(observed).hexdigest() != digest:
        raise StepFailed("get", "file_get digest differs from file_put payload")
    step.check("put_get", "passed", "readback sha256 matches")
    if not step.has("shell"):
        reason = ("host control exposes no file_list/file_rename/file_delete and shell is unavailable")
        for check in ("list", "rename", "delete"):
            step.check(check, "blocked", reason)
        return
    step.observed["list_rename_delete_method"] = "shell"
    listing = shell(step, "list", guest_tool("ls", "-1", "/tmp"))
    if tool_missing(listing):
        step.check("list", "blocked", "ls not found on guest")
    elif listing.get("code") == 0 and f"{name}.txt" in str(listing.get("stdout", "")).splitlines():
        step.check("list", "passed", "directory listing contains the file")
    else:
        step.check("list", "failed", f"listing code={listing.get('code')!r} does not contain the file")
    moved = shell(step, "rename", guest_tool("mv", "-f", "--", source, target))
    if tool_missing(moved):
        step.check("rename", "blocked", "mv not found on guest")
        step.check("delete", "blocked", "rename did not run")
        return
    if moved.get("code") != 0:
        raise StepFailed("rename", f"mv exited with {moved.get('code')!r}: {moved.get('stderr')!r}")
    renamed = decode_file(run.endpoint, step.ok("get_renamed", {"t": "file_get", "path": target}))
    old_absent = file_absent(step, "get_old", source)
    if hashlib.sha256(renamed).hexdigest() == digest and old_absent:
        step.check("rename", "passed", "renamed path matches and old path is absent")
    else:
        step.check("rename", "failed", "renamed digest differs or old path still exists")
    removed = shell(step, "delete", guest_tool("rm", "-f", "--", target))
    if tool_missing(removed):
        step.check("delete", "blocked", "rm not found on guest")
        return
    if removed.get("code") != 0:
        raise StepFailed("delete", f"rm exited with {removed.get('code')!r}")
    if file_absent(step, "get_deleted", target):
        step.check("delete", "passed", "file_get reports absence after delete")
    else:
        step.check("delete", "failed", "file still readable after delete")


def launch_and_verify(run, step, bundle_id, stage):
    response = step.ok(f"{stage}_launch", {"t": "app_launch", "bundle_id": bundle_id, "screen": False})
    pid = response.get("pid")
    step.cleanups.append((f"{stage}_terminate", lambda: step.call(
        f"{stage}_cleanup", {"t": "app_terminate", "bundle_id": bundle_id, "screen": False})))
    if not valid_pid(pid):
        raise StepFailed(f"{stage}_launch", "app_launch returned invalid pid")
    step.stage = f"{stage}_running"
    step.commands.append({"t": "app_list", "filter": "running"})
    running = running_app(run.endpoint, bundle_id, step.recorder, run.timeout)
    if running is None:
        raise StepFailed(f"{stage}_running", "launched application missing from running app_list")
    if running["pid"] != pid:
        raise StepFailed(f"{stage}_running", f"running pid {running['pid']} differs from launch pid {pid}")
    return pid


def terminate_and_verify(run, step, bundle_id, stage):
    step.ok(f"{stage}_terminate", {"t": "app_terminate", "bundle_id": bundle_id, "screen": False})
    step.cleanups = [item for item in step.cleanups if item[0] != f"{stage}_terminate"]
    step.stage = f"{stage}_gone"
    step.commands.append({"t": "app_list", "filter": "running"})
    return running_app(run.endpoint, bundle_id, step.recorder, run.timeout) is None


def step_s7(run, step):
    step.criteria = ("app_launch PID appears in running app_list; screenshot shows the application "
                     "(manual review); after app_terminate the PID is gone; jb/exp additionally "
                     "install a test IPA and launch it")
    step.require(("app_terminate", "app_list"), "apps")
    launch_reason = launch_not_declared(run)
    if launch_reason is None:
        step.require(("app_launch",), "apps")
    bundle_id = run.args.bundle_id
    step.observed["bundle_id"] = bundle_id
    listing = step.ok("initial_list", {"t": "app_list", "filter": "running"})
    apps = listing.get("apps") if isinstance(listing.get("apps"), list) else []
    step.observed["initial_running_apps"] = {
        "count": len(apps), "empty": not apps,
        "bundle_ids": sorted(str(app.get("bundle_id")) for app in apps if isinstance(app, dict)),
    }
    step.stage = "initial"
    step.commands.append({"t": "app_list", "filter": "running"})
    initial = running_app(run.endpoint, bundle_id, step.recorder, run.timeout)
    step.observed["initial"] = initial
    if launch_reason is not None:
        step.observed["app_launch_declared"] = False
        for name in ("launch_pid", "screenshot_shows_app", "terminate_pid_gone"):
            step.check(name, "not_applicable", launch_reason)
        if run.args.variant in ("jb", "exp"):
            step.check("ipa_install", "not_applicable", f"installed package cannot be launched: {launch_reason}")
        else:
            step.check("ipa_install", "not_applicable", "plan limits ipa_install to jb/exp")
        return
    if initial is not None:
        step.ok("pre_terminate", {"t": "app_terminate", "bundle_id": bundle_id, "screen": False})
        step.commands.append({"t": "app_list", "filter": "running"})
        if running_app(run.endpoint, bundle_id, step.recorder, run.timeout) is not None:
            raise StepBlocked("pre_terminate", "target application was running and did not terminate")
    pid = launch_and_verify(run, step, bundle_id, "app")
    step.observed["pid"] = pid
    step.check("launch_pid", "passed", f"pid {pid} present in running app_list")
    if step.has("screenshot"):
        shot = step.directory / "S7_launched.png"
        response = step.call("screenshot", {"t": "screenshot", "path": str(shot), "screen": False})
        step.add_evidence(shot)
        detail = "manual review required: screenshot shows the application"
        if response.get("ok") is not True:
            detail = f"screenshot failed: {response.get('error')!r}"
        step.check("screenshot_shows_app", "not_run", detail)
    else:
        step.check("screenshot_shows_app", "blocked",
                   f"screenshot command unavailable; {screen_note(run)}; requires GUI launch")
    if step.has("app_foreground"):
        response = step.call("app_foreground", {"t": "app_foreground"})
        step.observed["app_foreground"] = redact(response)
    if terminate_and_verify(run, step, bundle_id, "app"):
        step.check("terminate_pid_gone", "passed", "application absent from running app_list")
    else:
        step.check("terminate_pid_gone", "failed", "application still running after app_terminate")

    if run.args.variant not in ("jb", "exp"):
        step.check("ipa_install", "not_applicable", "plan limits ipa_install to jb/exp")
        return
    if not run.args.ipa:
        step.check("ipa_install", "not_run", "no --ipa test package provided")
        return
    if not step.has("ipa_install", "file_put"):
        step.check("ipa_install", "blocked", "ipa_install or file_put unavailable")
        return
    host_ipa = Path(run.args.ipa).expanduser().resolve(strict=True)
    guest_ipa = f"/tmp/vphone-f1-{uuid.uuid4().hex}.ipa"
    step.observed["ipa"] = {"host_path": str(host_ipa), "sha256": sha256_file(host_ipa),
                            "guest_path": guest_ipa}
    step.ok("ipa_put", {"t": "file_put", "path": guest_ipa, "load": str(host_ipa), "perm": "644"})
    if step.has("shell"):
        step.cleanups.append(("ipa_cleanup", lambda: shell(step, "ipa_cleanup",
                                                           guest_tool("rm", "-f", "--", guest_ipa))))
    response = step.ok("ipa_install", {"t": "ipa_install", "path": guest_ipa})
    installed = response.get("bundle_id") or run.args.ipa_bundle_id
    step.observed["ipa"]["installed_bundle_id"] = response.get("bundle_id")
    if run.args.ipa_bundle_id and response.get("bundle_id") not in (None, run.args.ipa_bundle_id):
        raise StepFailed("ipa_install", "installed bundle_id differs from --ipa-bundle-id")
    if not installed:
        raise StepFailed("ipa_install", "ipa_install returned no bundle_id and --ipa-bundle-id is unset")
    ipa_pid = launch_and_verify(run, step, installed, "ipa")
    gone = terminate_and_verify(run, step, installed, "ipa")
    step.check("ipa_install", "passed" if gone else "failed",
               f"installed {installed} launched with pid {ipa_pid}"
               + ("" if gone else " but did not terminate"))


def location_matches(snapshot, generation, latitude, longitude):
    applied = snapshot.get("applied") if isinstance(snapshot.get("applied"), dict) else {}
    fix = applied.get("last_fix") if isinstance(applied.get("last_fix"), dict) else {}
    return (snapshot.get("state") == "running" and snapshot.get("generation") == generation
            and isinstance(fix.get("latitude"), (int, float))
            and abs(fix["latitude"] - latitude) < 1e-6
            and isinstance(fix.get("longitude"), (int, float))
            and abs(fix["longitude"] - longitude) < 1e-6
            and isinstance(applied.get("last_delivery_sequence"), int)
            and applied["last_delivery_sequence"] > 0
            and bool(applied.get("last_ack_at")))


def step_s9(run, step):
    step.criteria = ("protocol layer: location_source_set returns a generation, location_source_status "
                     "reaches running with the same generation, applied fix and guest ack, and "
                     "location_source_stop returns off; application-layer CoreLocation reading is "
                     "required for passed and has no probe, so the maximum result is partial")
    step.manual = ["first location authorization prompt", "application-layer reading probe (not implemented)"]
    step.require(("location_source_set", "location_source_status", "location_source_stop"),
                 "location_owned")
    latitude, longitude = run.args.latitude, run.args.longitude
    initial = step.ok("initial_status", {"t": "location_source_status"})
    step.observed["initial"] = {"state": initial.get("state"), "generation": initial.get("generation"),
                                "desired": initial.get("desired")}
    if initial.get("state") not in (None, "off") or initial.get("generation") is not None:
        owner = (initial.get("desired") or {}).get("owner")
        raise StepBlocked("initial_status", f"location source already active (owner={owner!r}); not replaced")
    response = step.ok("set", {
        "t": "location_source_set", "mode": "fixed", "coordinate_system": "wgs84",
        "owner": LOCATION_OWNER, "lat": latitude, "lon": longitude,
        # Fixed sources require producer_sequence 0 and timestamp > 0 (Unix seconds or ISO-8601);
        # VPhoneSystemLocationController.preflightFixedSource / validateFix.
        "producer_sequence": 0, "timestamp": time.time(),
        "heartbeat_s": 1.0, "replace": False, "persist": False,
    })
    generation = response.get("generation")
    if not isinstance(generation, str) or not generation:
        raise StepFailed("set", "location_source_set returned no generation")
    step.observed["generation"] = generation
    step.cleanups.append(("location_stop", lambda: step.call(
        "cleanup", {"t": "location_source_stop", "generation": generation})))
    deadline = time.monotonic() + run.args.location_wait
    snapshot = response
    while not location_matches(snapshot, generation, latitude, longitude):
        if snapshot.get("generation") not in (None, generation):
            raise StepFailed("await_running", "location generation replaced by another source")
        if time.monotonic() >= deadline:
            raise StepFailed("await_running",
                             f"status did not reach running with applied fix and ack within "
                             f"{run.args.location_wait:g}s (state={snapshot.get('state')!r})")
        time.sleep(0.2)
        snapshot = step.ok("await_running", {"t": "location_source_status"})
    step.observed["running_status"] = redact(snapshot)
    step.check("protocol_set_status", "passed", "running with matching generation, fix and ack")
    stopped = step.ok("stop", {"t": "location_source_stop", "generation": generation})
    step.cleanups = [item for item in step.cleanups if item[0] != "location_stop"]
    final = step.ok("final_status", {"t": "location_source_status"})
    step.observed["final"] = {"state": final.get("state"), "generation": final.get("generation")}
    if (stopped.get("state") == "off" and stopped.get("generation") is None
            and final.get("state") == "off" and final.get("generation") is None):
        step.check("protocol_stop", "passed", "stop returned off with null generation")
    else:
        step.check("protocol_stop", "failed", "source not off after location_source_stop")
    step.check("app_layer_reading", "not_run",
               "no guest application probe reads CoreLocation (plan §3 S9)")


def valid_receipt(receipt, generation, presentation_id):
    return (isinstance(receipt, dict) and receipt.get("generation") == generation
            and receipt.get("presentation_id") == presentation_id)


def step_s10(run, step):
    if run.args.variant != "exp":
        return step_s10_negative(run, step)
    step.criteria = ("exp: camera_present image returns a copy receipt; camera_status with the same "
                     "presentation_id returns streaming and the same receipt; camera_stop stops. QR "
                     "text and camera view need external probe/screenshot, so the maximum result is "
                     "partial")
    step.manual = ["camera permission prompt", "camera_qr_probe or system camera screenshot"]
    step.require(("camera_status", "camera_stop"), "vcam_receipt_v3")
    if not step.has("camera_present"):
        step.observed["screen_available"] = (run.capabilities or {}).get("screen_available")
        raise StepBlocked("capabilities",
                          "camera_present unavailable; requires GUI launch "
                          f"({screen_note(run)}). Host code enables camera_present only when the "
                          "camera vsock is connected and the guest declares vcam_receipt_v3")
    if not run.args.camera_image:
        step.check("copy_receipt", "not_run", "no --camera-image provided")
        step.check("qr_recognition", "not_run", "external QR probe required")
        return
    step.require(("app_terminate", "app_list"), "apps")
    launch_reason = launch_not_declared(run)
    if launch_reason is not None:
        raise StepNotApplicable(f"camera consumer cannot be launched: {launch_reason}")
    step.require(("app_launch",), "apps")
    image = Path(run.args.camera_image).expanduser().resolve(strict=True)
    generation = f"f1-{uuid.uuid4().hex}"
    consumer = run.args.camera_consumer_bundle_id
    step.observed.update({"image": str(image), "image_sha256": sha256_file(image),
                          "generation": generation, "consumer_bundle_id": consumer})
    initial = step.ok("initial_status", {"t": "camera_status", "generation": generation})
    if initial.get("streaming") is True:
        raise StepBlocked("initial_status", "camera source already streaming; not replaced")
    step.observed["consumer_pid"] = launch_and_verify(run, step, consumer, "consumer")
    response = step.call("present", {"t": "camera_present", "source": "image", "path": str(image),
                                     "generation": generation, "role": "qr", "fps": 8})
    presentation_id = response.get("presentation_id")
    if response.get("streaming") is True or response.get("ok") is True:
        step.cleanups.append(("camera_stop", lambda: step.call(
            "cleanup", {"t": "camera_stop", "generation": generation, "policy": "keep_last"})))
    step.observed["present"] = redact(response)
    if response.get("ok") is not True:
        raise StepFailed("present", f"camera_present returned ok=false: {response.get('error')!r}")
    if not isinstance(presentation_id, str) or not presentation_id:
        raise StepFailed("present", "camera_present omitted presentation_id")
    if not valid_receipt(response.get("transport_receipt"), generation, presentation_id):
        raise StepFailed("present", "camera_present receipt does not match generation/presentation_id")
    status = step.ok("status", {"t": "camera_status", "generation": generation,
                                "presentation_id": presentation_id})
    if not (status.get("streaming") is True and status.get("generation") == generation
            and status.get("presentation_id") == presentation_id
            and status.get("matches_requested") is True
            and valid_receipt(status.get("transport_receipt"), generation, presentation_id)):
        raise StepFailed("status", "camera_status lost presentation identity or receipt")
    stopped = step.ok("stop", {"t": "camera_stop", "generation": generation,
                               "presentation_id": presentation_id, "policy": "keep_last"})
    step.cleanups = [item for item in step.cleanups if item[0] != "camera_stop"]
    if stopped.get("streaming") is not False:
        raise StepFailed("stop", "camera_stop did not report streaming=false")
    after = step.ok("after_stop", {"t": "camera_status", "generation": generation})
    if after.get("streaming") is not False:
        raise StepFailed("after_stop", "camera source still streaming after stop")
    step.observed["presentation_id"] = presentation_id
    step.check("copy_receipt", "passed", "same presentation_id copy receipt, status and stop consistent")
    if not terminate_and_verify(run, step, consumer, "consumer"):
        raise StepFailed("consumer_gone", "camera consumer still running after terminate")
    step.check("qr_recognition", "not_run", "QR text requires research/probes/camera_qr_probe (external)")
    step.check("camera_view_screenshot", "not_run", "manual screenshot review required")


def step_s10_negative(run, step):
    step.expectation = "absent"
    step.criteria = (f"{run.args.variant}: EXP camera injection files are absent (file_get ENOENT) and "
                     "no request yields a valid copy receipt; counts as a negative record only")
    step.require(("file_get",), "file")
    for index, path in enumerate(EXP_INJECTED_FILES):
        if file_absent(step, f"inject_file_{index}", path, save_name=f"unexpected_{Path(path).name}"):
            step.check(f"absent:{path}", "passed", "file_get reports absence")
        else:
            step.check(f"absent:{path}", "failed", "EXP injection file exists on non-EXP variant")
    generation = f"f1-neg-{uuid.uuid4().hex}"
    if step.has("camera_status"):
        status = step.call("status", {"t": "camera_status", "generation": generation})
        step.observed["camera_status"] = redact(status)
        if isinstance(status.get("transport_receipt"), dict):
            step.check("status_without_receipt", "failed", "camera_status returned a transport receipt")
        else:
            step.check("status_without_receipt", "passed", "no transport receipt")
    else:
        step.check("status_without_receipt", "not_run", "camera_status unavailable", optional=True)
    if not run.args.camera_image:
        step.check("present_without_receipt", "not_run", "no --camera-image provided", optional=True)
        return
    image = Path(run.args.camera_image).expanduser().resolve(strict=True)
    response = step.call("present", {"t": "camera_present", "source": "image", "path": str(image),
                                     "generation": generation, "role": "qr", "fps": 8})
    step.observed["camera_present"] = redact(response)
    if response.get("streaming") is True or response.get("ok") is True:
        step.cleanups.append(("camera_stop", lambda: step.call(
            "cleanup", {"t": "camera_stop", "generation": generation, "policy": "keep_last"})))
    if valid_receipt(response.get("transport_receipt"), generation, response.get("presentation_id")):
        step.check("present_without_receipt", "failed", "non-EXP camera_present returned a valid receipt")
    else:
        step.check("present_without_receipt", "passed",
                   f"no valid receipt (ok={response.get('ok')!r}, error={response.get('error')!r})")


def step_s12(run, step):
    exp = run.args.variant == "exp"
    step.expectation = "present" if exp else "absent"
    step.criteria = ("exp: kern.hv_vmm_present absent and kern.Xv_vmm_present=1, DT identity rewritten, "
                     "graphics and compute probes pass; non-exp: kern.hv_vmm_present present, no "
                     "kern.Xv_vmm_present, DT identity original, no EXP injection files")
    if exp:
        step.manual = ["VZ window graphics review", "Metal compute probe (not implemented)"]
    if step.has("shell"):
        hv = read_sysctl(step, "hv_vmm_present", "kern.hv_vmm_present")
        xv = read_sysctl(step, "Xv_vmm_present", "kern.Xv_vmm_present")
        step.observed["kern.hv_vmm_present"] = {"result": hv[0], "value": hv[1]}
        step.observed["kern.Xv_vmm_present"] = {"result": xv[0], "value": xv[1]}
        if "unavailable" in (hv[0], xv[0]):
            step.check("hv_vmm_sysctl", "blocked", f"sysctl unavailable: {hv[1] if hv[0] == 'unavailable' else xv[1]}")
        elif exp:
            good = hv[0] == "absent" and xv == ("present", "1")
            step.check("hv_vmm_sysctl", "passed" if good else "failed",
                       f"hv={hv[0]}, Xv={xv[0]}:{xv[1] if xv[0] == 'present' else ''}")
        else:
            good = hv[0] == "present" and xv[0] == "absent"
            step.check("hv_vmm_sysctl", "passed" if good else "failed", f"hv={hv[0]}, Xv={xv[0]}")
        machine = read_sysctl(step, "hw_machine", "hw.machine")
        step.observed["hw.machine"] = {"result": machine[0], "value": machine[1]}
        expected = "iPhone17,3" if exp else "iPhone99,11"
        if machine[0] != "present":
            step.check("dt_model_via_hw_machine", "blocked", f"hw.machine unavailable: {machine[1]}")
        else:
            step.check("dt_model_via_hw_machine", "passed" if machine[1] == expected else "failed",
                       f"hw.machine={machine[1]!r}, expected {expected!r}", expected=expected)
    else:
        step.check("hv_vmm_sysctl", "blocked", "shell command unavailable")
        step.check("dt_model_via_hw_machine", "blocked", "shell command unavailable")
    step.check("dt_target_type_compatible", "blocked",
               "no guest interface reads DeviceTree target-type/compatible directly")
    if step.has("file_get"):
        if not exp:
            for index, path in enumerate(EXP_INJECTED_FILES):
                absent = file_absent(step, f"inject_file_{index}", path,
                                     save_name=f"unexpected_{Path(path).name}")
                step.check(f"absent:{path}", "passed" if absent else "failed",
                           "file_get reports absence" if absent else "EXP injection file exists")
        response = step.call("system_version", {"t": "file_get", "path": SYSTEM_VERSION_PLIST})
        version = None
        if response.get("ok") is True:
            try:
                version = plistlib.loads(decode_file(run.endpoint, response))
                step.observed["system_version"] = {key: version.get(key) for key in
                                                   ("ProductVersion", "ProductBuildVersion")}
            except (plistlib.InvalidFileException, ValueError, AcceptanceFailure) as error:
                step.observed["system_version_error"] = str(error)
        if run.args.spoof_build:
            if version is None:
                step.check("spoof_build", "blocked", "SystemVersion.plist not readable")
            else:
                build = version.get("ProductBuildVersion")
                step.check("spoof_build", "passed" if build == run.args.spoof_build else "failed",
                           f"ProductBuildVersion={build!r}, expected {run.args.spoof_build!r}")
        else:
            step.check("spoof_build", "not_applicable", "no --spoof-build option")
    else:
        if not exp:
            step.check("injection_files_absent", "blocked", "file_get unavailable")
        step.check("spoof_build", "not_applicable" if not run.args.spoof_build else "blocked",
                   "file_get unavailable")
    step.check("watchdogd_state", "not_run", "plan gives no criterion; not evaluated", optional=True)
    if exp:
        step.check("graphics", "blocked", "requires VZ window review and AppleParavirtGPU evidence")
        step.check("compute", "blocked", "Metal compute probe does not exist")


def manual_step(reason, manual):
    def run_step(run, step):
        step.manual = manual
        step.override = ("not_run", reason)
    return run_step


def step_s11(run, step):
    if run.args.variant not in ("jb", "exp") or not run.args.frida:
        step.manual = []
        step.override = ("not_applicable", "plan applies S11 only to jb/exp --frida combinations")
        return
    step.manual = ["host Frida client with matching frida-server version", "attach/hook/Stalker session"]
    step.override = ("not_run", "Frida client instrumentation is not automated by this script; "
                                "required fields: client_version, server_version, attach_target, "
                                "script_sha256, messages")


STEP_FUNCTIONS = {
    "preflight": step_preflight,
    "S4": step_s4,
    "S5": manual_step("GUI input is not judged automatically; requires parameterized a3_input_matrix "
                      "and screenshot review (screenshot/tap/swipe need screen_available=true)",
                      ["VZ window mouse/keyboard spot check", "screenshot pair review"]),
    "S6": step_s6,
    "S7": step_s7,
    "S8": manual_step("DDI requires xcrun devicectl ddiServices and guest trust/developer mode",
                      ["trust host", "enable developer mode"]),
    "S9": step_s9,
    "S10": step_s10,
    "S11": step_s11,
    "S12": step_s12,
}


# MARK: - Run

class Run:
    def __init__(self, args, output):
        self.args = args
        self.output = output
        self.timeout = args.timeout
        self.run_id = args.run_id or (
            f"f1-{args.combo}-{args.variant}-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
            f"-{uuid.uuid4().hex[:6]}")
        self.capabilities = None
        self.preflight_error = "preflight not run"
        try:
            self.endpoint = resolve_endpoint(args.vm_name or "vm", args.socket)
        except (AcceptanceFailure, OSError) as error:
            self.endpoint = None
            self.preflight_error = f"host-control socket unusable: {error}"


def execute_step(run, step_id, selected):
    step = Step(run, step_id)
    status, reason, failure = None, None, None
    if step_id not in selected:
        status, reason = "not_run", "step not selected by --steps"
    elif step_id != "preflight" and run.endpoint is None and step_id not in ("S5", "S8", "S11"):
        status, reason = "blocked", run.preflight_error
        failure = {"stage": "socket", "reason": run.preflight_error, "timed_out": False}
    else:
        try:
            STEP_FUNCTIONS[step_id](run, step)
        except StepFailed as error:
            status, failure = "failed", {"stage": error.stage, "reason": str(error), "timed_out": False}
            if error.classification:
                failure["classification"] = error.classification
        except StepBlocked as error:
            status, failure = "blocked", {"stage": error.stage, "reason": str(error), "timed_out": False}
        except StepNotApplicable as error:
            status, reason = "not_applicable", str(error)
        except HostControlTransportError as error:
            status = "blocked"
            failure = {"stage": step.stage, "reason": str(error), "timed_out": error.timed_out}
        except AcceptanceFailure as error:
            status, failure = "failed", {"stage": step.stage, "reason": str(error), "timed_out": False}
        except OSError as error:
            status, failure = "blocked", {"stage": step.stage, "reason": f"host I/O: {error}",
                                          "timed_out": False}
        cleanup_errors = []
        for label, action in reversed(step.cleanups):
            try:
                action()
            except (AcceptanceFailure, StepFailed, StepBlocked) as error:
                cleanup_errors.append(f"{label}: {error}")
        if cleanup_errors:
            step.observed["cleanup_errors"] = cleanup_errors
            if status is None or status in ("passed", "partial"):
                status = "failed"
                failure = {"stage": "cleanup", "reason": "; ".join(cleanup_errors), "timed_out": False}
        if step_id == "preflight" and status in ("failed", "blocked") and failure:
            run.preflight_error = failure["reason"]
    if status is None:
        if step.override:
            status, reason = step.override
        else:
            status = aggregate(step.checks)
            pending = [f"{check['name']}={check['status']}: {check['detail']}" for check in step.checks
                       if check["status"] not in ("passed", "not_applicable")
                       and not (check.get("optional") and check["status"] == "not_run")]
            reason = "; ".join(pending) or None
    step.add_evidence(step.recorder.path)
    if failure and step.recorder.path.is_file():
        lines = len(step.recorder.path.read_text().splitlines())
        failure["log"] = {"path": str(step.recorder.path.relative_to(run.output)), "line": lines}
    record = {
        "id": step_id,
        "title": STEP_TITLES[step_id],
        "status": status,
        "started_at": step.started_at,
        "finished_at": utc_now(),
        "commands": step.commands,
        "exit_code": None,
        "criteria": step.criteria,
        "expectation": step.expectation,
        "observed": step.observed,
        "checks": step.checks,
        "evidence": step.evidence,
        "manual": step.manual,
        "failure": failure,
        "reason": reason,
        "reused_evidence": None,
    }
    record_path = step.directory / "step.json"
    record_path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
    record["record"] = str(record_path.relative_to(run.output))
    return record


def parse_steps(value):
    if value == "all":
        return set(STEP_ORDER)
    names = [item.strip() for item in value.split(",") if item.strip()]
    unknown = [name for name in names if name not in STEP_TITLES]
    if not names or unknown:
        raise argparse.ArgumentTypeError(
            f"unknown steps {unknown}; choose from {', '.join(STEP_ORDER)} or all")
    return set(names) | {"preflight"}


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--socket", type=Path, required=True, help="<vm>/vphone.sock")
    parser.add_argument("--variant", choices=VARIANTS, required=True)
    parser.add_argument("--combo", required=True, help="combination ID, e.g. P, L, N")
    parser.add_argument("--out", type=Path, required=True, help="new evidence directory (must not exist)")
    parser.add_argument("--steps", type=parse_steps, default=parse_steps("all"),
                        help=f"comma list of {','.join(STEP_ORDER)} or all (preflight always runs)")
    parser.add_argument("--second-boot-phase", choices=("write", "verify"))
    parser.add_argument("--s4-state", type=Path, help="s4_state.json written by the write phase")
    parser.add_argument("--marker-path", help="guest marker path for S4 write (default /var/mobile/Library/f1-<run>.txt)")
    parser.add_argument("--vm-name")
    parser.add_argument("--bundle", type=Path,
                        help="VM bundle directory; S4 reads <bundle>/.vphone-runtime.json (read-only)")
    parser.add_argument("--launch-mode", choices=("gui", "headless"),
                        help="how the operator launched the VM (recorded, not verified)")
    parser.add_argument("--run-id")
    parser.add_argument("--timeout", type=float, default=20, help="per-request timeout seconds (0, 120]")
    parser.add_argument("--bundle-id", default="com.apple.Preferences")
    parser.add_argument("--ipa", type=Path, help="host test IPA for jb/exp ipa_install")
    parser.add_argument("--ipa-bundle-id")
    parser.add_argument("--latitude", type=float, default=31.2304)
    parser.add_argument("--longitude", type=float, default=121.4737)
    parser.add_argument("--location-wait", type=float, default=15)
    parser.add_argument("--camera-image", type=Path, help="host image (QR) for S10")
    parser.add_argument("--camera-consumer-bundle-id", default="com.apple.camera")
    parser.add_argument("--device", default="iPhone17,3")
    parser.add_argument("--ios-version")
    parser.add_argument("--ios-build")
    parser.add_argument("--ios-ipsw-sha256")
    parser.add_argument("--cloudos-version")
    parser.add_argument("--cloudos-build")
    parser.add_argument("--cloudos-ipsw-sha256")
    parser.add_argument("--frida", action="store_true", help="combination was created with --frida")
    parser.add_argument("--spoof-build", help="combination was created with -b <build>")
    parser.add_argument("--vphone-cli", type=Path, help="vphone-cli executable to hash")
    args = parser.parse_args(argv)
    if not 0 < args.timeout <= 120:
        parser.error("--timeout must be in (0, 120]")
    if args.location_wait <= 0:
        parser.error("--location-wait must be positive")
    if not args.combo or any(character in "\r\n\0/" for character in args.combo):
        parser.error("--combo must be a nonempty single-line string without '/'")
    return args


def main(argv=None):
    raw_argv = list(sys.argv[1:] if argv is None else argv)
    args = parse_args(raw_argv)
    output = args.out.expanduser().resolve()
    if output.exists():
        print(f"output already exists: {output}", file=sys.stderr)
        return 2
    output.mkdir(parents=True)
    run = Run(args, output)
    started_at = utc_now()
    steps = [execute_step(run, step_id, args.steps) for step_id in STEP_ORDER]
    commit, clean = git_state()
    vphone_sha = None
    if args.vphone_cli:
        try:
            vphone_sha = sha256_file(args.vphone_cli.expanduser())
        except OSError:
            vphone_sha = None
    summary = {
        "schema_version": SCHEMA_VERSION,
        "run_id": run.run_id,
        "script": "scripts/f1_runtime_acceptance.py",
        "started_at": started_at,
        "finished_at": utc_now(),
        "invocation": {"argv": redact_argv(raw_argv), "steps": sorted(args.steps, key=STEP_ORDER.index),
                       "second_boot_phase": args.second_boot_phase},
        "host": host_info(),
        "tool": {"git_commit": commit, "worktree_clean": clean,
                 "vphone_cli_sha256": vphone_sha, "vphoned_sha256": None},
        "combination": {
            "combo_id": args.combo,
            "device": args.device,
            "ios": {"version": args.ios_version, "build": args.ios_build,
                    "ipsw_sha256": args.ios_ipsw_sha256},
            "cloudos": {"version": args.cloudos_version, "build": args.cloudos_build,
                        "ipsw_sha256": args.cloudos_ipsw_sha256},
            "variant": args.variant,
            "options": {"frida": args.frida, "spoof_build": args.spoof_build},
        },
        "vm": {"name": args.vm_name, "socket": str(args.socket),
               "bundle": str(args.bundle) if args.bundle else None},
        "launch": {"declared_mode": args.launch_mode,
                   "screen_available": (run.capabilities or {}).get("screen_available"),
                   "boot_mode": (run.capabilities or {}).get("boot_mode")},
        "steps": steps,
        "disk": [],
    }
    (output / "run.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    for step in steps:
        print(f"{step['id']:<9} {step['status']:<14} {step.get('reason') or ''}".rstrip())
    print(f"run.json: {output / 'run.json'}")
    return 1 if any(step["status"] == "failed" for step in steps) else 0


if __name__ == "__main__":
    sys.exit(main())
