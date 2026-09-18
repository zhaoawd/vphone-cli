#!/usr/bin/env python3
"""Drive the F3 performance and long-run baseline experiments.

Subcommands follow research/f3_performance_baseline_plan_2026-09-18.md §5:
`latency` (§3.1), `recovery-boot` and `recovery-daemon` (§3.2), `soak` (E4),
`idle` (E5a/E5b), `camera` (§3.5) and `summarize` (§3.6 plus the report tables).

Safety rules implemented here and covered by tests/test_f3_benchmark.py:
sockets that resolve inside `vm-2607` are refused, the output directory must not
exist, every guest write stays under /var/mobile/Library/f3-bench/, and no VM is
started or stopped unless `recovery-boot` is given --allow-vm-lifecycle.
"""

import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
import plistlib
import posixpath
import random
import shlex
import signal
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

from host_control_client import (
    AcceptanceFailure,
    HostControlTransportError,
    camera_status as host_camera_status,
    endpoint as resolve_endpoint,
    request as host_request,
    require_ok,
)
import f3_common
import f3_stats


SCHEMA_VERSION = 1
ROOT = Path(__file__).resolve().parents[1]
GUEST_ROOT = "/var/mobile/Library/f3-bench/"
BLOCKED_BUNDLE_NAMES = ("vm-2607",)
# §2.1 time since cold boot: the bundle's diagnostic runtime record written by the
# lock holder (VPhoneCore/VPhoneVMRuntimeState.swift). Read-only, and it can be
# absent or stale.
RUNTIME_RECORD = ".vphone-runtime.json"
# `operation` values a running VM holds (VPhoneVMOperation.vmLifetime).
VM_LIFETIME_OPERATIONS = ("boot", "dfu")
ERROR_PREFIX_BYTES = 200
LOCATION_OWNER = "vphone-f3-bench"
WARMUP_SAMPLES = 10
DEFAULT_MAX_CONSECUTIVE_FAILURES = 20
# §3.1 手势节流：客户机注入器一次只执行一个手势，手势执行期间到达的请求以
# code=gesture_busy 被拒绝，因此 tap/swipe 类之间需要最小间隔（见 10.10）。
DEFAULT_SWIPE_MS = 300
# tap 注入占用注入器 80 毫秒（10.10），加 20 毫秒余量。
DEFAULT_TAP_SPACING_MS = 100
# swipe 间隔由本次运行发送的 ms 时长加余量得出，不单独写死。
GESTURE_SPACING_MARGIN_MS = 50
# §3.6: the first 10 minutes after launch are warm-up and are dropped from the series.
RESOURCE_WARMUP_SECONDS = 600.0
# §3.6: moving block bootstrap with a 5 minute block.
BLOCK_SECONDS = 300.0
# §3.5: only windows of at least 60 s are used for the transport loss estimate.
CAMERA_MIN_WINDOW_SECONDS = 60.0
# §3.2 cold boot poll intervals.
SOCKET_POLL_SECONDS = 0.1
CAPABILITY_POLL_SECONDS = 0.25
# §3.7: guest vcam log sampled every --guest-log-interval seconds (read-only stat).
DEFAULT_GUEST_LOG = "/var/jb/var/mobile/Library/vphone-vcam.log"
DEFAULT_GUEST_LOG_INTERVAL = 600.0
GUEST_STAT_PATHS = ("/usr/bin/stat", "/var/jb/usr/bin/stat", "/bin/stat", "/var/jb/bin/stat")
# jb/exp guest command used by recovery-daemon when --kill-command is not given.
DEFAULT_KILL_COMMAND = (
    "if [ -x /var/jb/usr/bin/killall ]; then exec /var/jb/usr/bin/killall -9 vphoned; fi; "
    "if [ -x /usr/bin/killall ]; then exec /usr/bin/killall -9 vphoned; fi; "
    "echo 'vphone-f3: killall not found' >&2; exit 127"
)
# Accepted host-sampler field names (scripts/f3_host_sampler.py writes host_samples.jsonl).
CPU_TIME_KEYS = ("cpu_seconds", "cpu_time_s", "cpu_time_seconds", "cpu_time", "time_s")
FOOTPRINT_KEYS = ("footprint_bytes", "footprint")
RSS_KEYS = ("rss_bytes", "rss")
BLOCK_KEYS = ("st_blocks", "blocks")
SIZE_KEYS = ("size_bytes", "st_size")
LABEL_KEYS = ("label", "role", "target", "name")
AVAILABLE_KEYS = ("available_bytes", "avail_bytes", "free_bytes")
# §3.3, amended after 10.6 and 10.9: the §3.6 growth rule is applied to the
# vphone-cli process, the disk files and the log files. The Virtualization XPC
# processes are sampled unchanged but reported as background covariates, because
# their footprint stays exactly at the guest memory allocation and their RSS is
# dominated by large steps. `df` and `host` series are whole-host background by
# §3.4. The Virtualization processes are recognised by the sampler's own
# `source="vz"` field (its executable-name scan), not by the operator's label.
COVARIATE_KINDS = ("df", "host")
VZ_SAMPLE_SOURCE = "vz"


class BenchmarkError(AcceptanceFailure):
    """Argument or safety violation; reported before any request is sent."""


class TooManyFailures(AcceptanceFailure):
    pass


# MARK: - Safety checks

def check_socket_path(path):
    """Resolve a host-control socket path and refuse the autophone instance."""
    candidate = Path(path).expanduser().resolve()
    blocked = [part for part in candidate.parts if part in BLOCKED_BUNDLE_NAMES]
    if blocked:
        raise BenchmarkError(
            f"refusing a socket inside {blocked[0]}: {candidate}; F3 must not drive the "
            "autophone instance")
    return candidate


def check_guest_directory(value):
    """Return a normalized guest directory that stays under GUEST_ROOT."""
    if not value or "\0" in value:
        raise BenchmarkError("guest directory must be a nonempty path without NUL")
    normalized = posixpath.normpath(value)
    if not normalized.endswith("/"):
        normalized += "/"
    root = posixpath.normpath(GUEST_ROOT) + "/"
    if normalized != root and not normalized.startswith(root):
        raise BenchmarkError(f"guest writes must stay under {GUEST_ROOT}: {value}")
    return normalized


def check_guest_log_path(value):
    """Validate a guest log path. This is a read-only `stat`, so GUEST_ROOT does not apply."""
    if not isinstance(value, str) or not value.strip() or "\0" in value:
        raise BenchmarkError("guest log paths must be nonempty strings without NUL")
    return value


def guest_file(directory, name):
    path = posixpath.normpath(posixpath.join(directory, name))
    root = posixpath.normpath(directory) + "/"
    if not path.startswith(root) or "\0" in path:
        raise BenchmarkError(f"guest file escapes {directory}: {name}")
    return path


def error_prefix(text):
    return str(text).encode("utf-8", "replace")[:ERROR_PREFIX_BYTES].decode("utf-8", "replace")


# MARK: - Run context

class NullRecorder:
    """host_control_client requires a recorder; samples are written by Run.perform."""

    def record(self, endpoint, request, response):
        return None


class Run:
    def __init__(self, args, experiment, output, endpoint=None):
        self.args = args
        self.experiment = experiment
        self.output = output
        self.endpoint = endpoint
        self.timeout = getattr(args, "timeout", 30.0)
        self.seed = getattr(args, "seed", 0)
        self.recorder = NullRecorder()
        self.started_at = f3_common.utc_now()
        self.run_id = f"f3-{experiment}-{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}-{uuid.uuid4().hex[:6]}"
        self.lock = threading.Lock()
        (output / "samples").mkdir(parents=True, exist_ok=True)
        self.samples = f3_common.JsonlWriter(output / "samples" / f"{experiment}.jsonl")
        self.extra_writers = []
        self.sequence = 0
        self.request_count = 0
        self.failures_by_code = {}
        self.consecutive_failures = 0
        self.max_consecutive_failures = getattr(args, "max_consecutive_failures",
                                                DEFAULT_MAX_CONSECUTIVE_FAILURES)
        self.stop_signal = None
        self.aborted = None
        self.skipped = {}
        self.capabilities = None
        self.details = {}
        self.guest_directory = check_guest_directory(getattr(args, "guest_dir", GUEST_ROOT))
        self.payloads = output / "payloads"
        self.seeded = {}

    # Signals ---------------------------------------------------------------
    def install_signal_handlers(self):
        def handler(number, frame):
            self.stop_signal = signal.Signals(number).name
        for number in (signal.SIGINT, signal.SIGTERM):
            signal.signal(number, handler)

    @property
    def should_stop(self):
        return self.stop_signal is not None

    def sleep(self, seconds):
        """Sleep in slices so a signal stops the experiment within 100 ms."""
        deadline = time.monotonic() + max(0.0, seconds)
        while not self.should_stop:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return True
            time.sleep(min(0.1, remaining))
        return False

    # Requests --------------------------------------------------------------
    def perform(self, label, payload, params, phase="measure", verify=None, writer=None):
        """Send one request, write one sample line and return (response, ok)."""
        paced_start = take_paced_start()
        timing = {}
        response = None
        code = None
        error = None
        size = 0
        try:
            response = host_request(self.endpoint, payload, self.recorder, self.timeout,
                                    timing=timing)
            # Length of the response re-encoded as compact JSON, not the exact wire length.
            size = len(json.dumps(response, separators=(",", ":")).encode())
            ok = response.get("ok") is True
            if not ok:
                code = str(response.get("code") or "error")
                error = error_prefix(response.get("error", ""))
            elif verify is not None:
                problem = verify(response)
                if problem:
                    ok, code, error = False, "verify_failed", error_prefix(problem)
        except HostControlTransportError as failure:
            ok = False
            code = "transport_timeout" if failure.timed_out else "transport_error"
            error = error_prefix(failure)
        except AcceptanceFailure as failure:
            ok = False
            code = "protocol_error"
            error = error_prefix(failure)
        with self.lock:
            self.sequence += 1
            sequence = self.sequence
        record = {
            "experiment": self.experiment,
            "phase": phase,
            "seq": sequence,
            "class": label,
            "command": payload.get("t"),
            "params": params,
            "ok": ok,
            "code": code,
            "error": error,
            "response_bytes": size,
            "started_utc": timing.get("t_wall_utc"),
            # Gesture pacing: the injector start this request was reserved for,
            # on the t_start_ns clock; None when no gate paced the request.
            "t_paced_ns": paced_start,
            "t_start_ns": timing.get("t_start_ns"),
            "t_connect_ns": timing.get("t_connect_ns"),
            "t_send_ns": timing.get("t_send_ns"),
            "t_total_ns": timing.get("t_total_ns"),
        }
        self.write_sample(record, writer=writer)
        self.note_result(ok, code, phase)
        return response, ok

    def write_sample(self, record, writer=None):
        with self.lock:
            (writer or self.samples).write(record)

    def note_result(self, ok, code, phase):
        with self.lock:
            self.request_count += 1
            if ok:
                self.consecutive_failures = 0
                return
            self.failures_by_code[code] = self.failures_by_code.get(code, 0) + 1
            # Warm-up, recovery polling and guest log reads expect failures; they do not
            # trip the abort threshold.
            if phase in ("warmup", "recovery", "guest_log"):
                return
            self.consecutive_failures += 1
            exceeded = self.consecutive_failures > self.max_consecutive_failures
        if exceeded:
            raise TooManyFailures(
                f"{self.consecutive_failures} consecutive failed requests "
                f"(--max-consecutive-failures {self.max_consecutive_failures}); last code {code!r}")

    # Output ----------------------------------------------------------------
    def close(self):
        self.samples.close()
        for writer in self.extra_writers:
            writer.close()

    def writer(self, name):
        writer = f3_common.JsonlWriter(self.output / name)
        self.extra_writers.append(writer)
        return writer

    def write_run_json(self, parameters, raw_argv):
        payload = {
            "schema_version": SCHEMA_VERSION,
            "script": "scripts/f3_benchmark.py",
            "experiment": self.experiment,
            "run_id": self.run_id,
            "started_at": self.started_at,
            "finished_at": f3_common.utc_now(),
            "note": getattr(self.args, "note", None),
            "seed": self.seed,
            "invocation": {"argv": f3_common.redact_argv(raw_argv)},
            "git": dict(zip(("commit", "worktree_clean"), f3_common.git_state())),
            "host": f3_common.host_record(),
            "vm": vm_record(self.args, self.endpoint, self.started_at),
            "artifacts": artifact_digests(self.args),
            "capabilities": self.capabilities,
            "parameters": parameters,
            "counts": {
                "requests": self.request_count,
                "failures_by_code": self.failures_by_code,
                "skipped": self.skipped,
            },
            "details": self.details,
            "interrupted": self.stop_signal,
            "aborted": self.aborted,
        }
        f3_common.write_json(self.output / "run.json", payload)
        return payload


def vm_record(args, endpoint, run_started_at=None):
    bundle = getattr(args, "bundle", None)
    record = {
        "name": getattr(args, "name", None),
        "socket": str(endpoint.socket_path) if endpoint else None,
        "bundle": str(bundle) if bundle else None,
        "config": None,
    }
    if bundle:
        try:
            config = plistlib.loads((Path(bundle) / "config.plist").read_bytes())
            record["config"] = {key: config.get(key) for key in ("cpuCount", "memorySize")}
        except (OSError, ValueError, plistlib.InvalidFileException) as error:
            record["config_error"] = str(error)
    record["boot"] = boot_record(bundle, run_started_at)
    return record


def pid_alive(pid):
    """True/False for a live host pid, None when liveness cannot be decided."""
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return None
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # The process exists and belongs to another user.
        return True
    except OSError:
        return None
    return True


def boot_record(bundle, run_started_at):
    """§2.1 fixed item: when the VM under test was started and its age at the run start.

    Evidence 10.11: whether a measurement window contains the post-boot allocation step
    decides the `Disk.img` verdict, so the time since cold boot has to be recorded with
    every run. The source is the bundle's `.vphone-runtime.json` diagnostic record
    (host process start, not guest kernel boot time). It is read read-only, and every
    failure is recorded instead of raised: a missing bundle, a missing or unparseable
    file, and a record whose pid no longer exists all leave the run intact.
    """
    record = {"source": None, "started_at": None, "uptime_at_run_start_s": None,
              "pid": None, "pid_alive": None, "operation": None, "instance_id": None,
              "is_boot_operation": None, "stale": None, "unavailable": None,
              "note": ("host process start time from <bundle>/.vphone-runtime.json; "
                       "not the guest kernel boot time")}
    if not bundle:
        record["unavailable"] = "no --bundle given"
        return record
    path = Path(bundle).expanduser() / RUNTIME_RECORD
    record["source"] = str(path)
    try:
        payload = json.loads(path.read_bytes())
    except (OSError, ValueError) as error:
        record["unavailable"] = f"cannot read {path}: {error}"
        return record
    if not isinstance(payload, dict):
        record["unavailable"] = f"{path} is not a JSON object"
        return record
    pid = payload.get("pid")
    record["pid"] = pid if isinstance(pid, int) and not isinstance(pid, bool) else None
    record["operation"] = payload.get("operation")
    record["instance_id"] = payload.get("instanceID")
    record["is_boot_operation"] = (record["operation"] in VM_LIFETIME_OPERATIONS
                                   if isinstance(record["operation"], str) else None)
    started = payload.get("startedAt")
    record["started_at"] = started if isinstance(started, str) and started else None
    record["pid_alive"] = pid_alive(record["pid"])
    reasons = []
    if record["pid"] is None:
        reasons.append("the record has no usable pid")
    elif record["pid_alive"] is False:
        reasons.append(f"pid {record['pid']} no longer exists, the record is stale")
    if record["started_at"] is None:
        reasons.append("the record has no startedAt")
    if record["is_boot_operation"] is False:
        reasons.append(f"operation={record['operation']!r} is not a VM lifetime operation")
    record["stale"] = record["pid_alive"] is False
    started_epoch = parse_utc_epoch(record["started_at"])
    run_epoch = parse_utc_epoch(run_started_at)
    if started_epoch is None:
        if record["started_at"] is not None:
            reasons.append(f"startedAt={record['started_at']!r} is not an ISO timestamp")
    elif run_epoch is None:
        reasons.append("the run start time is not an ISO timestamp")
    else:
        record["uptime_at_run_start_s"] = run_epoch - started_epoch
    record["unavailable"] = "; ".join(reasons) or None
    return record


def artifact_digests(args):
    digests = {}
    for option, key in (("vphone_cli", "vphone_cli_sha256"), ("vphoned", "vphoned_sha256")):
        path = getattr(args, option, None)
        if not path:
            continue
        try:
            digests[key] = f3_common.sha256_file(Path(path).expanduser())
        except OSError as error:
            digests[key] = f"unavailable: {error}"
    return digests


def read_capabilities(run):
    """One uncounted capabilities request used for command selection."""
    response, ok = run.perform("capabilities", {"t": "capabilities"}, {}, phase="setup")
    if not ok:
        raise BenchmarkError("capabilities request failed; cannot select command classes")
    run.capabilities = {
        "guest_connected": response.get("guest_connected"),
        "guest_capabilities": response.get("guest_capabilities"),
        "screen_available": response.get("screen_available"),
        "boot_mode": response.get("boot_mode"),
        "limits": response.get("limits"),
        "commands_available": sorted(name for name, value in (response.get("commands") or {}).items()
                                     if value is True),
    }
    return response


def command_available(capabilities, name):
    commands = capabilities.get("commands")
    return isinstance(commands, dict) and commands.get(name) is True


# MARK: - Guest log size (§3.7)

def guest_stat_command(path):
    quoted = shlex.quote(path)
    parts = [f"if [ -x {tool} ]; then exec {tool} -f %z -- {quoted}; fi" for tool in GUEST_STAT_PATHS]
    parts.append("echo 'vphone-f3: stat not found' >&2; exit 127")
    return "; ".join(parts)


class GuestLogSampler:
    """Read the size of guest log files with `shell stat -f %z` (plan §3.7).

    This is a read path, not a write path: the guest log lives outside GUEST_ROOT and
    never goes through guest_file(). A failed reading is recorded and the experiment
    continues; these failures do not count towards --max-consecutive-failures.
    """

    def __init__(self, run):
        self.run = run
        self.paths = list(getattr(run.args, "guest_log", None) or [])
        self.interval = float(getattr(run.args, "guest_log_interval", DEFAULT_GUEST_LOG_INTERVAL))
        self.writer = None
        self.due = None
        self.enabled = bool(self.paths)
        self.count = 0

    def start(self, capabilities):
        if not self.enabled:
            return
        if not command_available(capabilities, "shell"):
            self.enabled = False
            self.run.skipped["guest_log"] = (
                "shell command unavailable; guest log size not sampled "
                f"({self.paths})")
            return
        self.writer = self.run.writer("samples/guest_log.jsonl")
        self.due = time.monotonic()
        self.run.details["guest_log_paths"] = self.paths
        self.run.details["guest_log_interval_s"] = self.interval

    def maybe_sample(self):
        if not self.enabled or self.due is None or time.monotonic() < self.due:
            return
        self.due = time.monotonic() + self.interval
        for path in self.paths:
            self.sample(path)

    def sample(self, path):
        response, ok = self.run.perform(
            "shell:guest_log", {"t": "shell", "cmd": guest_stat_command(path), "screen": False},
            {"path": path, "purpose": "guest log size"}, phase="guest_log")
        size, code, error = None, None, None
        if not isinstance(response, dict):
            code, error = "request_failed", "host-control request failed"
        elif not ok:
            code = str(response.get("code") or "error")
            error = error_prefix(response.get("error", ""))
        else:
            exit_code = response.get("code")
            stdout = str(response.get("stdout", "")).strip()
            if exit_code not in (0, None):
                code = f"exit_{exit_code}"
                error = error_prefix(response.get("stderr", ""))
            elif stdout.isdigit():
                size = int(stdout)
            else:
                code = "invalid_size"
                error = error_prefix(stdout or "empty stat output")
        record = {"t_wall": f3_common.utc_now(), "t_mono": round(time.monotonic(), 6),
                  "path": path, "size_bytes": size, "ok": size is not None,
                  "code": code, "error": error}
        self.run.write_sample(record, writer=self.writer)
        self.count += 1
        return record


# MARK: - Latency (§3.1)

# The injector reservation the current thread is waiting on. CommandClass.wait_turn
# writes it and the request it paces reads it once (Run.perform, field t_paced_ns);
# the schedule runs wait_turn and the request on the same thread.
PACED_START = threading.local()


def take_paced_start():
    """Return and clear this thread's injector reservation, or None when ungated."""
    start = getattr(PACED_START, "value", None)
    PACED_START.value = None
    return start


class InjectorGate:
    """Minimum spacing shared by the command classes that inject a gesture.

    The guest injector runs one gesture at a time and rejects a request that
    arrives while a gesture is still running (code gesture_busy). Each class
    reserves the injector for its own spacing, measured from the start of one
    reservation to the start of the next; the wait is returned to the caller so
    it happens outside the §3.1 latency measurement.

    The clock is `time.perf_counter_ns()`, the same clock the sample records'
    `t_start_ns` comes from, so a record can carry the reserved start it was
    paced to (`t_paced_ns`). The request itself starts at or after that point:
    how much later depends on host scheduling and is not paced by the gate.
    """

    def __init__(self, clock=time.perf_counter_ns):
        self.clock = clock
        self.lock = threading.Lock()
        self.due = 0

    def reserve(self, spacing):
        """Reserve the injector for `spacing` seconds.

        Returns `(delay, start_ns)`: the wait in seconds before the caller may
        start its request, and the reserved start on the gate clock. Successive
        reservations are at least the earlier one's spacing apart by
        construction, whatever the caller's own scheduling does.
        """
        spacing_ns = round(spacing * 1_000_000_000)
        with self.lock:
            now = self.clock()
            start = max(now, self.due)
            self.due = start + spacing_ns
            return (start - now) / 1_000_000_000, start


class CommandClass:
    """One latency command class: a label, a sample count and an execute callable."""

    def __init__(self, label, samples, execute, *, commands=(), capability=None,
                 needs_screen=False, gate=None, spacing=0.0):
        self.label = label
        self.samples = samples
        self.execute = execute
        self.commands = tuple(commands)
        self.capability = capability
        self.needs_screen = needs_screen
        self.gate = gate
        self.spacing = spacing

    def wait_turn(self, run):
        """Hold the next request until the shared gate is free; never inside a measurement."""
        if self.gate is None or self.spacing <= 0:
            PACED_START.value = None
            return not run.should_stop
        delay, start_ns = self.gate.reserve(self.spacing)
        PACED_START.value = start_ns
        return run.sleep(delay)

    def skip_reason(self, capabilities):
        missing = [name for name in self.commands if not command_available(capabilities, name)]
        if missing:
            guest = capabilities.get("guest_capabilities")
            if (self.capability and isinstance(guest, list) and self.capability not in guest):
                return f"guest does not declare capability {self.capability!r}; commands {missing}"
            return f"host-control commands unavailable: {missing}"
        if self.needs_screen and capabilities.get("screen_available") is not True:
            return "screen_available is not true; GUI launch required"
        return None


def payload_bytes(seed, size):
    return random.Random((seed << 20) ^ size).randbytes(size)


def seed_guest_file(run, size, worker):
    """Write the fixed pseudo-random payload once per (worker, size) and return path+digest."""
    name = f"w{worker}-{size}.bin"
    path = guest_file(run.guest_directory, name)
    with run.lock:
        seeded = run.seeded.get(path)
    if seeded:
        return path, seeded
    data = payload_bytes(run.seed, size)
    digest = hashlib.sha256(data).hexdigest()
    run.perform("file_put:seed",
                {"t": "file_put", "path": path, "data_b64": base64.b64encode(data).decode(),
                 "perm": "600"},
                {"path": path, "bytes": size, "sha256": digest, "mode": "inline"},
                phase="setup")
    with run.lock:
        run.seeded[path] = digest
    return path, digest


def host_payload_file(run, size):
    """Host-side file for file_put --load; created once under <out>/payloads."""
    run.payloads.mkdir(parents=True, exist_ok=True)
    path = run.payloads / f"load-{size}.bin"
    if not path.is_file() or path.stat().st_size != size:
        path.write_bytes(payload_bytes(run.seed, size))
    return path


def decoded_digest(response):
    try:
        return hashlib.sha256(base64.b64decode(response["data"], validate=True)).hexdigest()
    except (KeyError, TypeError, ValueError):
        return None


def resolve_gesture_spacing(args):
    """Resolve the effective tap/swipe spacing in seconds.

    The swipe value follows the `ms` duration this run sends, so changing
    --swipe-ms keeps the spacing above the gesture. The resolved value is
    written back into args so run.json's parameters record it.
    """
    if getattr(args, "swipe_spacing_ms", None) is None:
        args.swipe_spacing_ms = args.swipe_ms + GESTURE_SPACING_MARGIN_MS
    return args.tap_spacing_ms / 1000.0, args.swipe_spacing_ms / 1000.0


def latency_classes(run, counts):
    """Build the §3.1 command classes for this run."""
    args = run.args
    classes = []
    # tap and swipe share one injector, so they share one gate.
    injector = InjectorGate()
    tap_spacing, swipe_spacing = resolve_gesture_spacing(args)

    def add(label, samples, execute, **options):
        classes.append(CommandClass(label, counts.get(label, samples), execute, **options))

    def simple(label, payload_factory, params_factory=None, **options):
        def execute(index, worker):
            payload = payload_factory(index, worker)
            params = params_factory(payload) if params_factory else {
                key: value for key, value in payload.items() if key != "t"}
            run.perform(label, payload, params, phase=phase_of(index))
        add(label, options.pop("samples"), execute, **options)

    def phase_of(index):
        return "warmup" if index < 0 else "measure"

    simple("capabilities", lambda index, worker: {"t": "capabilities"}, samples=500,
           commands=("capabilities",))
    simple("location_source_status", lambda index, worker: {"t": "location_source_status"},
           samples=500, commands=("location_source_status",), capability="location_owned")
    for filter_name, count in (("running", 200), ("all", 200)):
        simple(f"app_list:{filter_name}",
               lambda index, worker, filter_name=filter_name: {"t": "app_list", "filter": filter_name},
               samples=count, commands=("app_list",), capability="apps")

    for size, label_suffix, count in ((1024, "1k", 200), (65536, "64k", 200), (1048576, "1m", 200)):
        def put_inline(index, worker, size=size, label_suffix=label_suffix):
            path, digest = seed_guest_file(run, size, worker)
            data = payload_bytes(run.seed, size)
            run.perform(f"file_put:{label_suffix}",
                        {"t": "file_put", "path": path,
                         "data_b64": base64.b64encode(data).decode(), "perm": "600"},
                        {"path": path, "bytes": size, "sha256": digest, "mode": "inline"},
                        phase=phase_of(index),
                        verify=lambda response, size=size: (
                            None if response.get("size") == size
                            else f"file_put size {response.get('size')!r} != {size}"))
        add(f"file_put:{label_suffix}", count, put_inline,
            commands=("file_put",), capability="file")

        def get_inline(index, worker, size=size, label_suffix=label_suffix):
            path, digest = seed_guest_file(run, size, worker)
            run.perform(f"file_get:{label_suffix}", {"t": "file_get", "path": path},
                        {"path": path, "bytes": size, "sha256": digest, "mode": "inline"},
                        phase=phase_of(index),
                        verify=lambda response, digest=digest: (
                            None if decoded_digest(response) == digest
                            else "file_get digest differs from the written payload"))
        add(f"file_get:{label_suffix}", count, get_inline,
            commands=("file_get",), capability="file")

    for size, label_suffix in ((16 * 1024 * 1024, "load16m"), (64 * 1024 * 1024, "load64m")):
        def put_load(index, worker, size=size, label_suffix=label_suffix):
            source = host_payload_file(run, size)
            path = guest_file(run.guest_directory, f"w{worker}-{label_suffix}.bin")
            run.perform(f"file_put:{label_suffix}",
                        {"t": "file_put", "path": path, "load": str(source), "perm": "600"},
                        {"path": path, "bytes": size, "mode": "load", "host_path": str(source)},
                        phase=phase_of(index))
        add(f"file_put:{label_suffix}", 30, put_load, commands=("file_put",), capability="file")

    for size, label_suffix in ((16 * 1024 * 1024, "save16m"), (64 * 1024 * 1024, "save64m")):
        def get_save(index, worker, size=size, label_suffix=label_suffix):
            source = host_payload_file(run, size)
            guest = guest_file(run.guest_directory, f"w{worker}-{label_suffix}.bin")
            with run.lock:
                known = run.seeded.get(guest)
            if not known:
                run.perform("file_put:seed",
                            {"t": "file_put", "path": guest, "load": str(source), "perm": "600"},
                            {"path": guest, "bytes": size, "mode": "load"}, phase="setup")
                with run.lock:
                    run.seeded[guest] = "load"
            target = run.payloads / f"{label_suffix}-w{worker}.bin"
            run.perform(f"file_get:{label_suffix}",
                        {"t": "file_get", "path": guest, "save": str(target)},
                        {"path": guest, "bytes": size, "mode": "save", "host_path": str(target)},
                        phase=phase_of(index))
        add(f"file_get:{label_suffix}", 30, get_save, commands=("file_get",), capability="file")

    def location_pair(index, worker):
        phase = phase_of(index)
        response, ok = run.perform(
            "location_source_set", location_set_payload(args), location_params(args), phase=phase)
        if not ok or not isinstance(response, dict):
            return
        generation = response.get("generation")
        if not generation:
            return
        run.perform("location_source_stop",
                    {"t": "location_source_stop", "generation": generation},
                    {"generation": generation}, phase=phase)
    add("location_source_pair", 100, location_pair,
        commands=("location_source_set", "location_source_stop"), capability="location_owned")

    def screenshot(index, worker, color):
        run.payloads.mkdir(parents=True, exist_ok=True)
        target = run.payloads / f"shot-w{worker}{'-color' if color else ''}.png"
        payload = {"t": "screenshot", "path": str(target), "screen": False}
        if color:
            payload["color"] = True
        run.perform(f"screenshot:{'color' if color else 'gray'}", payload,
                    {"color": color, "host_path": str(target)}, phase=phase_of(index))
    add("screenshot:gray", 200, lambda index, worker: screenshot(index, worker, False),
        commands=("screenshot",), needs_screen=True)
    add("screenshot:color", 200, lambda index, worker: screenshot(index, worker, True),
        commands=("screenshot",), needs_screen=True)

    def tap(index, worker, screen, delay=None):
        payload = {"t": "tap", "x": args.tap_x, "y": args.tap_y, "screen": screen}
        if delay is not None:
            payload["delay"] = delay
        run.perform(f"tap:{'screen' if screen else 'noscreen'}", payload,
                    {"x": args.tap_x, "y": args.tap_y, "screen": screen, "delay": delay},
                    phase=phase_of(index))
    add("tap:noscreen", 200, lambda index, worker: tap(index, worker, False),
        commands=("tap",), needs_screen=True, gate=injector, spacing=tap_spacing)
    add("tap:screen", 100, lambda index, worker: tap(index, worker, True, delay=0),
        commands=("tap",), needs_screen=True, gate=injector, spacing=tap_spacing)

    def swipe(index, worker):
        up = index % 2 == 0
        start_y, end_y = (args.swipe_y1, args.swipe_y2) if up else (args.swipe_y2, args.swipe_y1)
        payload = {"t": "swipe", "x1": args.swipe_x, "y1": start_y, "x2": args.swipe_x,
                   "y2": end_y, "ms": args.swipe_ms, "screen": False}
        run.perform("swipe:noscreen", payload,
                    {"x": args.swipe_x, "y1": start_y, "y2": end_y, "ms": args.swipe_ms,
                     "screen": False},
                    phase=phase_of(index))
    add("swipe:noscreen", 200, swipe, commands=("swipe",), needs_screen=True,
        gate=injector, spacing=swipe_spacing)

    simple("shell", lambda index, worker: {"t": "shell", "cmd": "true", "screen": False},
           samples=200, commands=("shell",), capability="shell")

    def app_pair(index, worker):
        phase = phase_of(index)
        run.perform("app_launch", {"t": "app_launch", "bundle_id": args.bundle_id, "screen": False},
                    {"bundle_id": args.bundle_id}, phase=phase)
        run.perform("app_terminate",
                    {"t": "app_terminate", "bundle_id": args.bundle_id, "screen": False},
                    {"bundle_id": args.bundle_id}, phase=phase)
    add("app_lifecycle", 30, app_pair,
        commands=("app_launch", "app_terminate"), capability="apps")

    return classes


def location_set_payload(args):
    # F1 S9 template: fixed source, wgs84, producer_sequence 0 and timestamp > 0.
    return {"t": "location_source_set", "mode": "fixed", "coordinate_system": "wgs84",
            "owner": LOCATION_OWNER, "lat": args.latitude, "lon": args.longitude,
            "producer_sequence": 0, "timestamp": time.time(),
            "heartbeat_s": args.heartbeat, "replace": False, "persist": False}


def location_params(args):
    return {"mode": "fixed", "lat": args.latitude, "lon": args.longitude,
            "heartbeat_s": args.heartbeat, "persist": False}


def latency_schedule(classes, seed, warmup):
    """Warm-up per class, then interleaved rounds shuffled with the fixed seed."""
    schedule = []
    for item in classes:
        schedule.extend((item, -(index + 1), "warmup") for index in range(warmup))
    generator = random.Random(seed)
    remaining = {item.label: item.samples for item in classes}
    index = {item.label: 0 for item in classes}
    while any(remaining[item.label] > 0 for item in classes):
        active = [item for item in classes if remaining[item.label] > 0]
        order = list(active)
        generator.shuffle(order)
        for item in order:
            schedule.append((item, index[item.label], "measure"))
            index[item.label] += 1
            remaining[item.label] -= 1
    return schedule


def run_latency(run, raw_argv):
    classes = latency_classes(run, {})
    if run.args.list_commands:
        run.details["command_classes"] = {item.label: item.samples for item in classes}
        for item in classes:
            print(f"{item.label}\t{item.samples}")
        return
    capabilities = read_capabilities(run)
    selected = None
    if run.args.commands:
        selected = [name.strip() for name in run.args.commands.split(",") if name.strip()]
    known = {item.label for item in classes}
    if selected:
        unknown = [name for name in selected if name not in known]
        if unknown:
            raise BenchmarkError(f"unknown command classes {unknown}; choose from {sorted(known)}")
        classes = [item for item in classes if item.label in selected]
    if run.args.samples is not None:
        for item in classes:
            item.samples = run.args.samples
    usable = []
    for item in classes:
        reason = item.skip_reason(capabilities)
        if reason:
            run.skipped[item.label] = reason
        else:
            usable.append(item)
    if not usable:
        raise BenchmarkError(f"no command class is available on this instance: {run.skipped}")
    schedule = latency_schedule(usable, run.seed, run.args.warmup)
    run.details["classes"] = {item.label: item.samples for item in usable}
    run.details["scheduled_requests"] = len(schedule)
    execute_schedule(run, schedule)
    if run.args.cleanup_guest_files:
        cleanup_guest_files(run)


def execute_schedule(run, schedule):
    concurrency = max(1, run.args.concurrency)
    if concurrency == 1:
        for item, index, _ in schedule:
            if not item.wait_turn(run):
                return
            item.execute(index, 0)
        return
    cursor = {"position": 0}
    position_lock = threading.Lock()
    failure = {}

    def worker(number):
        while not run.should_stop:
            with position_lock:
                position = cursor["position"]
                if position >= len(schedule):
                    return
                cursor["position"] = position + 1
            item, index, _ = schedule[position]
            if not item.wait_turn(run):
                return
            try:
                item.execute(index, number)
            except AcceptanceFailure as error:
                failure.setdefault("error", error)
                return

    threads = [threading.Thread(target=worker, args=(number,), daemon=True)
               for number in range(concurrency)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    if "error" in failure:
        raise failure["error"]


def cleanup_guest_files(run):
    """Delete the benchmark directory on the guest (plan §9 decision 6 authorizes it)."""
    directory = run.guest_directory.rstrip("/")
    command = (f"if [ -x /bin/rm ]; then exec /bin/rm -rf -- {shlex.quote(directory)}; fi; "
               f"if [ -x /var/jb/bin/rm ]; then exec /var/jb/bin/rm -rf -- {shlex.quote(directory)}; fi; "
               "echo 'vphone-f3: rm not found' >&2; exit 127")
    run.perform("cleanup", {"t": "shell", "cmd": command, "screen": False},
                {"directory": directory}, phase="cleanup")


# MARK: - Recovery (§3.2)

def parse_lstart(text):
    """`ps -o lstart` local time, e.g. 'Tue Sep 16 21:29:05 2026', as epoch seconds."""
    try:
        return datetime.strptime(text.strip(), "%a %b %d %H:%M:%S %Y").timestamp()
    except (ValueError, TypeError):
        return None


def vz_process_pids():
    """Best-effort {pid: start epoch} of com.apple.Virtualization.VirtualMachine processes."""
    try:
        result = subprocess.run(["/bin/ps", "-axo", "pid=,lstart=,command="],
                                capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return None
    processes = {}
    for line in result.stdout.splitlines():
        if "com.apple.Virtualization.VirtualMachine" not in line:
            continue
        parts = line.split(None, 1)
        if len(parts) != 2 or not parts[0].isdigit():
            continue
        processes[int(parts[0])] = parse_lstart(parts[1].split("/")[0])
    return processes


def wait_for(run, predicate, deadline, interval):
    """Poll until predicate() is true; return the monotonic time or None on timeout/stop."""
    while time.monotonic() < deadline and not run.should_stop:
        if predicate():
            return time.monotonic()
        if not run.sleep(interval):
            return None
    return None


def probe_capabilities(run, phase):
    response, ok = run.perform("capabilities", {"t": "capabilities"}, {}, phase=phase)
    return response if ok else None


def run_recovery_boot(run, raw_argv):
    args = run.args
    launch = shlex.split(args.launch_command)
    stop = shlex.split(args.stop_command) if args.stop_command else None
    if not launch:
        raise BenchmarkError("--launch-command must contain an executable")
    socket_path = Path(args.sock).expanduser()
    expected = [name.strip() for name in (args.expect_capabilities or "").split(",") if name.strip()]
    writer = run.writer("samples/recovery_boot.jsonl")
    results = []
    for index in range(1, args.count + 1):
        if run.should_stop:
            break
        log_path = run.output / f"boot-{index}.log"
        record = {"iteration": index, "started_utc": f3_common.utc_now(),
                  "launch_command": launch, "log": log_path.name,
                  "vz_pids_before": None, "vz_pids_after": None}
        before = vz_process_pids()
        record["vz_pids_before"] = sorted(before) if before is not None else None
        with log_path.open("wb") as log:
            t0 = time.monotonic()
            record["spawn_epoch"] = time.time()
            process = subprocess.Popen(launch, stdout=log, stderr=subprocess.STDOUT, cwd=str(ROOT))
        deadline = t0 + args.boot_timeout
        t_sock = wait_for(run, lambda: socket_path.exists(), deadline, SOCKET_POLL_SECONDS)
        record["t_sock_s"] = None if t_sock is None else t_sock - t0
        t_guest = t_caps = t_screen = None
        if t_sock is not None:
            try:
                run.endpoint = resolve_endpoint(args.name, socket_path)
            except (AcceptanceFailure, OSError) as error:
                record["endpoint_error"] = str(error)
            if run.endpoint is not None:
                state = {}

                def connected():
                    response = probe_capabilities(run, "recovery")
                    state["last"] = response
                    return bool(response and response.get("guest_connected") is True)

                t_guest = wait_for(run, connected, deadline, CAPABILITY_POLL_SECONDS)
                if t_guest is not None:
                    def declared():
                        response = probe_capabilities(run, "recovery")
                        state["last"] = response
                        guest = (response or {}).get("guest_capabilities")
                        if not isinstance(guest, list) or not guest:
                            return False
                        return all(name in guest for name in expected)

                    t_caps = time.monotonic() if declared() else wait_for(
                        run, declared, deadline, CAPABILITY_POLL_SECONDS)
                    last = state.get("last") or {}
                    if last.get("screen_available") is True and not args.no_screen:
                        target = run.output / f"boot-{index}.png"

                        def shot():
                            _, ok = run.perform("screenshot",
                                                {"t": "screenshot", "path": str(target),
                                                 "screen": False},
                                                {"host_path": str(target)}, phase="recovery")
                            return ok

                        t_screen = wait_for(run, shot, deadline, CAPABILITY_POLL_SECONDS)
        record.update({
            "t_guest_s": None if t_guest is None else t_guest - t0,
            "t_caps_s": None if t_caps is None else t_caps - t0,
            "t_screen_s": None if t_screen is None else t_screen - t0,
            "expected_capabilities": expected,
            "timeout_s": args.boot_timeout,
            "ok": t_guest is not None,
            "finished_utc": f3_common.utc_now(),
        })
        after = vz_process_pids()
        record["vz_pids_after"] = sorted(after) if after is not None else None
        if before is not None and after is not None:
            record["vz_lstart"] = {str(pid): after[pid] for pid in set(after) - set(before)}
        run.write_sample(record, writer=writer)
        results.append(record)
        if stop:
            try:
                subprocess.run(stop, cwd=str(ROOT), capture_output=True, text=True,
                               timeout=args.boot_timeout)
            except (OSError, subprocess.SubprocessError) as error:
                record["stop_error"] = str(error)
        process.poll()
        run.endpoint = None
        if index < args.count:
            run.sleep(args.gap)
    run.details["iterations"] = results
    run.details["failed"] = sum(1 for item in results if not item["ok"])


def run_recovery_daemon(run, raw_argv):
    args = run.args
    read_capabilities(run)
    path, digest = seed_guest_file(run, 1024, 0)
    writer = run.writer("samples/recovery_daemon.jsonl")
    results = []
    for index in range(1, args.samples + 1):
        if run.should_stop:
            break
        record = {"iteration": index, "started_utc": f3_common.utc_now(),
                  "kill_command": args.kill_command}
        t_kill = time.monotonic()
        run.perform("shell:kill", {"t": "shell", "cmd": args.kill_command, "screen": False},
                    {"purpose": "terminate vphoned"}, phase="recovery")
        deadline = t_kill + args.restart_timeout
        t_down = wait_for(run, lambda: (probe_capabilities(run, "recovery") or {}).get(
            "guest_connected") is False, deadline, CAPABILITY_POLL_SECONDS)
        t_up = wait_for(run, lambda: (probe_capabilities(run, "recovery") or {}).get(
            "guest_connected") is True, deadline, CAPABILITY_POLL_SECONDS) if t_down else None

        def readable():
            _, ok = run.perform("file_get:probe", {"t": "file_get", "path": path},
                                {"path": path, "sha256": digest}, phase="recovery")
            return ok

        t_ok = wait_for(run, readable, deadline, CAPABILITY_POLL_SECONDS) if t_up else None
        record.update({
            "t_down_s": None if t_down is None else t_down - t_kill,
            "t_up_s": None if t_up is None else t_up - t_kill,
            "t_ok_s": None if t_ok is None else t_ok - t_kill,
            "t_up_minus_down_s": None if (t_up is None or t_down is None) else t_up - t_down,
            "timeout_s": args.restart_timeout,
            "ok": t_ok is not None,
            "finished_utc": f3_common.utc_now(),
        })
        run.write_sample(record, writer=writer)
        results.append(record)
        if index < args.samples:
            run.sleep(args.gap)
    run.details["iterations"] = results
    run.details["failed"] = sum(1 for item in results if not item["ok"])


# MARK: - Soak and idle (E4, E5)

def run_soak(run, raw_argv):
    args = run.args
    capabilities = read_capabilities(run)
    size = 64 * 1024
    path, digest = seed_guest_file(run, size, 0)
    screen = command_available(capabilities, "screenshot") and \
        capabilities.get("screen_available") is True
    if not screen:
        run.skipped["screenshot"] = "screenshot unavailable or screen_available is not true"
    logs = GuestLogSampler(run)
    logs.start(capabilities)
    run.payloads.mkdir(parents=True, exist_ok=True)
    target = run.payloads / "soak.png"
    start = time.monotonic()
    load_deadline = start + args.minutes * 60
    tail_deadline = load_deadline + args.tail_minutes * 60
    next_location = start
    cycles = 0
    while time.monotonic() < load_deadline and not run.should_stop:
        cycle_start = time.monotonic()
        run.perform("capabilities", {"t": "capabilities"}, {}, phase="measure")
        run.perform("location_source_status", {"t": "location_source_status"}, {}, phase="measure")
        run.perform("app_list:running", {"t": "app_list", "filter": "running"},
                    {"filter": "running"}, phase="measure")
        data = payload_bytes(run.seed, size)
        run.perform("file_put:64k",
                    {"t": "file_put", "path": path, "data_b64": base64.b64encode(data).decode(),
                     "perm": "600"},
                    {"path": path, "bytes": size, "sha256": digest, "mode": "inline"},
                    phase="measure")
        run.perform("file_get:64k", {"t": "file_get", "path": path},
                    {"path": path, "bytes": size, "sha256": digest, "mode": "inline"},
                    phase="measure",
                    verify=lambda response: (None if decoded_digest(response) == digest
                                             else "file_get digest differs from the written payload"))
        if screen:
            run.perform("screenshot:gray",
                        {"t": "screenshot", "path": str(target), "screen": False},
                        {"host_path": str(target)}, phase="measure")
        if time.monotonic() >= next_location:
            next_location = time.monotonic() + args.location_interval
            response, ok = run.perform("location_source_set", location_set_payload(args),
                                       location_params(args), phase="measure")
            generation = (response or {}).get("generation") if ok else None
            if generation:
                run.perform("location_source_stop",
                            {"t": "location_source_stop", "generation": generation},
                            {"generation": generation}, phase="measure")
        logs.maybe_sample()
        cycles += 1
        run.sleep(max(0.0, args.interval - (time.monotonic() - cycle_start)))
    run.details["cycles"] = cycles
    run.details["load_seconds"] = time.monotonic() - start
    tail = 0
    while time.monotonic() < tail_deadline and not run.should_stop:
        run.perform("capabilities", {"t": "capabilities"}, {}, phase="tail")
        logs.maybe_sample()
        tail += 1
        run.sleep(args.tail_interval)
    run.details["tail_probes"] = tail
    run.details["guest_log_samples"] = logs.count


def run_idle(run, raw_argv):
    args = run.args
    capabilities = read_capabilities(run)
    logs = GuestLogSampler(run)
    logs.start(capabilities)
    generation = None
    if args.location_source:
        response, ok = run.perform("location_source_set", location_set_payload(args),
                                   location_params(args), phase="setup")
        generation = (response or {}).get("generation") if ok else None
        run.details["location_generation"] = generation
        if not generation:
            raise BenchmarkError("--location-source requested but location_source_set returned no generation")
    deadline = time.monotonic() + args.minutes * 60
    probes = 0
    try:
        while time.monotonic() < deadline and not run.should_stop:
            run.perform("capabilities", {"t": "capabilities"}, {}, phase="measure")
            logs.maybe_sample()
            probes += 1
            run.sleep(args.interval)
    finally:
        if generation:
            run.perform("location_source_stop",
                        {"t": "location_source_stop", "generation": generation},
                        {"generation": generation}, phase="cleanup")
    run.details["probes"] = probes
    run.details["guest_log_samples"] = logs.count


# MARK: - Camera (§3.5)

def camera_sample(record):
    """Normalize one camera_status sample; returns None when it cannot be used in a pair."""
    if not isinstance(record, dict) or record.get("ok") is not True:
        return None
    receipt = record.get("transport_receipt")
    if not isinstance(receipt, dict):
        return None
    sched = record.get("host_scheduled_frame_index")
    if sched is None:
        sched = record.get("host_published_frame_index")
    values = {
        "h_ns": record.get("h_resp_ns"),
        "sched": sched,
        "pub": receipt.get("vphoned_published_frame_index"),
        "obs": receipt.get("libvcam_observed_frame_index"),
        "pub_at_ns": receipt.get("vphoned_published_at_ns"),
        "obs_at_ns": receipt.get("libvcam_observed_at_ns"),
    }
    if any(not isinstance(value, (int, float)) or isinstance(value, bool)
           for value in values.values()):
        return None
    values.update({
        "generation": record.get("generation"),
        "presentation_id": record.get("presentation_id"),
        "streaming": record.get("streaming") is True,
        "seq": record.get("seq"),
    })
    return values


def usable_pair(previous, current):
    """§3.5 pair filter: same identity, streaming, and non-decreasing pub and sched."""
    if previous is None or current is None:
        return False
    if previous["generation"] != current["generation"]:
        return False
    if previous["presentation_id"] != current["presentation_id"]:
        return False
    if not (previous["streaming"] and current["streaming"]):
        return False
    if current["pub"] < previous["pub"] or current["sched"] < previous["sched"]:
        return False
    return current["h_ns"] > previous["h_ns"]


def camera_segments(samples):
    """Split normalized samples into maximal runs of consecutive usable pairs."""
    segments = []
    current = []
    previous = None
    for sample in samples:
        if previous is not None and usable_pair(previous, sample):
            if not current:
                current = [previous]
            current.append(sample)
        else:
            if len(current) > 1:
                segments.append(current)
            current = []
        previous = sample
    if len(current) > 1:
        segments.append(current)
    return segments


def camera_metrics(records, min_window_seconds=CAMERA_MIN_WINDOW_SECONDS):
    """Compute the §3.5 metrics from raw camera_samples.jsonl records."""
    normalized = [camera_sample(record) for record in records]
    usable = [sample for sample in normalized if sample is not None]
    segments = camera_segments(usable)
    rates_sched, rates_pub, losses, backlog, lag, delays, skips = [], [], [], [], [], [], []
    for segment in segments:
        base = segment[0]["sched"] - segment[0]["pub"]
        for previous, current in zip(segment, segment[1:]):
            span = (current["h_ns"] - previous["h_ns"]) / 1e9
            if span > 0:
                rates_sched.append((current["sched"] - previous["sched"]) / span)
            publish_span = (current["pub_at_ns"] - previous["pub_at_ns"]) / 1e9
            if publish_span > 0:
                rates_pub.append((current["pub"] - previous["pub"]) / publish_span)
        for sample in segment:
            backlog.append(sample["sched"] - sample["pub"] - base)
            lag.append(sample["pub"] - sample["obs"])
            if sample["obs"] == sample["pub"]:
                delays.append((sample["obs_at_ns"] - sample["pub_at_ns"]) / 1e6)
        window = (segment[-1]["h_ns"] - segment[0]["h_ns"]) / 1e9
        scheduled = segment[-1]["sched"] - segment[0]["sched"]
        published = segment[-1]["pub"] - segment[0]["pub"]
        if window >= min_window_seconds and scheduled > 0:
            losses.append({"window_s": window, "scheduled": scheduled, "published": published,
                           "loss": 1 - published / scheduled})
            # §3.5: upper bound only; 2 s sampling sees a subset of the observed frame numbers.
            distinct = len({sample["obs"] for sample in segment})
            if published > 0:
                skips.append(1 - distinct / published)
    receipts = sum(1 for sample in normalized if sample is not None)
    total = len(records)
    return {
        "samples": total,
        "usable_samples": len(usable),
        "receipt_availability": (receipts / total) if total else None,
        "samples_without_receipt": total - receipts,
        "segments": len(segments),
        "r_sched_mean": mean(rates_sched),
        "r_sched_p50": f3_stats.quantile(sorted(rates_sched), 0.5) if rates_sched else None,
        "r_pub_mean": mean(rates_pub),
        "r_pub_p50": f3_stats.quantile(sorted(rates_pub), 0.5) if rates_pub else None,
        "transport_loss_windows": losses,
        "transport_loss_mean": mean([item["loss"] for item in losses]),
        "backlog_min": min(backlog) if backlog else None,
        "backlog_max": max(backlog) if backlog else None,
        "backlog_last": backlog[-1] if backlog else None,
        "lag_frames_mean": mean(lag),
        "lag_frames_max": max(lag) if lag else None,
        "publish_to_copy_ms": {
            "count": len(delays),
            "fraction_of_usable": (len(delays) / len(usable)) if usable else None,
            "p50": f3_stats.quantile(sorted(delays), 0.5) if delays else None,
            "max": max(delays) if delays else None,
        },
        "consumer_skip_upper_bound": mean(skips),
    }


def mean(values):
    return sum(values) / len(values) if values else None


def run_camera(run, raw_argv):
    args = run.args
    capabilities = read_capabilities(run)
    for name in ("camera_present", "camera_status", "camera_stop"):
        if not command_available(capabilities, name):
            raise BenchmarkError(f"{name} unavailable; camera experiments need a GUI launch on exp")
    logs = GuestLogSampler(run)
    logs.start(capabilities)
    image = Path(args.image).expanduser().resolve(strict=True)
    generation = f"f3-{uuid.uuid4().hex}"
    initial = host_camera_status(run.endpoint, generation, run.recorder, run.timeout)
    if initial.get("streaming") is True:
        raise BenchmarkError("a camera source is already streaming; not replaced")
    if args.launch_consumer:
        run.perform("app_launch",
                    {"t": "app_launch", "bundle_id": args.consumer_bundle_id, "screen": False},
                    {"bundle_id": args.consumer_bundle_id}, phase="setup")
    writer = run.writer("camera_samples.jsonl")
    presentation_id = None
    deadline = time.monotonic() + args.receipt_wait
    response = None
    while time.monotonic() < deadline and not run.should_stop:
        response, ok = run.perform(
            "camera_present",
            {"t": "camera_present", "source": "image", "path": str(image),
             "generation": generation, "role": args.role, "fps": args.fps},
            {"generation": generation, "fps": args.fps, "role": args.role,
             "host_path": str(image), "sha256": f3_common.sha256_file(image)},
            phase="setup")
        if ok:
            presentation_id = response.get("presentation_id")
            receipt = response.get("transport_receipt")
            if presentation_id and isinstance(receipt, dict) \
                    and receipt.get("presentation_id") == presentation_id:
                break
            presentation_id = None
        run.sleep(1.0)
    if not presentation_id:
        require_ok(run.endpoint, "camera_present", response or {})
        raise BenchmarkError(
            f"no two-level transport receipt within {args.receipt_wait:g}s; camera run not started")
    run.details.update({"generation": generation, "presentation_id": presentation_id,
                        "fps": args.fps, "image": str(image)})
    deadline = time.monotonic() + args.minutes * 60
    sequence = 0
    try:
        while time.monotonic() < deadline and not run.should_stop:
            cycle = time.monotonic()
            timing = {}
            payload = {"t": "camera_status", "generation": generation,
                       "presentation_id": presentation_id}
            record = {"seq": sequence, "generation": generation,
                      "presentation_id": presentation_id}
            try:
                response = host_request(run.endpoint, payload, run.recorder, run.timeout,
                                        timing=timing)
                record.update({
                    "ok": response.get("ok") is True,
                    "streaming": response.get("streaming"),
                    "matches_requested": response.get("matches_requested"),
                    "generation": response.get("generation", generation),
                    "presentation_id": response.get("presentation_id", presentation_id),
                    "host_scheduled_frame_index": response.get("host_scheduled_frame_index"),
                    "host_published_frame_index": response.get("host_published_frame_index"),
                    "transport_receipt": response.get("transport_receipt"),
                    "error": (None if response.get("ok") is True
                              else error_prefix(response.get("error", ""))),
                    "code": response.get("code"),
                })
                sample_ok = record["ok"]
            except AcceptanceFailure as failure:
                record.update({"ok": False, "error": error_prefix(failure),
                               "code": "transport_error", "transport_receipt": None})
                sample_ok = False
            record.update({
                "t_wall_utc": timing.get("t_wall_utc"),
                "h_req_ns": timing.get("t_start_ns"),
                "h_resp_ns": (timing.get("t_start_ns", 0) or 0) + (timing.get("t_total_ns", 0) or 0),
                "t_total_ns": timing.get("t_total_ns"),
            })
            run.write_sample(record, writer=writer)
            run.note_result(sample_ok, record.get("code") or "error", "measure")
            logs.maybe_sample()
            sequence += 1
            run.sleep(max(0.0, args.interval - (time.monotonic() - cycle)))
    finally:
        run.perform("camera_stop",
                    {"t": "camera_stop", "generation": generation,
                     "presentation_id": presentation_id, "policy": "keep_last"},
                    {"generation": generation}, phase="cleanup")
        if args.launch_consumer:
            run.perform("app_terminate",
                        {"t": "app_terminate", "bundle_id": args.consumer_bundle_id,
                         "screen": False},
                        {"bundle_id": args.consumer_bundle_id}, phase="cleanup")
    run.details["camera_samples"] = sequence
    run.details["guest_log_samples"] = logs.count


# MARK: - Summarize (§3.6)

def read_jsonl(path):
    records = []
    if not Path(path).is_file():
        return records
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return records


def load_run_directory(directory):
    directory = Path(directory)
    run_path = directory / "run.json"
    if not run_path.is_file():
        raise BenchmarkError(f"{directory} has no run.json")
    samples = {}
    for path in sorted((directory / "samples").glob("*.jsonl")):
        samples[path.stem] = read_jsonl(path)
    return {
        "path": str(directory),
        "run": json.loads(run_path.read_text()),
        "samples": samples,
        "host_samples": read_jsonl(directory / "host_samples.jsonl"),
        "camera_samples": read_jsonl(directory / "camera_samples.jsonl"),
    }


def latency_tables(samples, seed, resamples):
    """Per-class latency summary in milliseconds plus failure counts by code."""
    values = {}
    failures = {}
    for records in samples.values():
        for record in records:
            if record.get("phase") != "measure" or not record.get("class"):
                continue
            label = record["class"]
            if record.get("ok") is True and record.get("t_total_ns") is not None:
                values.setdefault(label, []).append(record["t_total_ns"] / 1e6)
            elif record.get("ok") is False:
                code = record.get("code") or "error"
                failures.setdefault(label, {})
                failures[label][code] = failures[label].get(code, 0) + 1
    summaries = {}
    for label, series in sorted(values.items()):
        summaries[label] = f3_stats.latency_summary(series, seed=seed, resamples=resamples)
    for label in failures:
        summaries.setdefault(label, {"count": 0})
    return {"unit": "ms", "classes": dict(sorted(summaries.items())),
            "failures_by_code": failures}


def recovery_tables(samples):
    """Median/min/max for each recovery interval."""
    tables = {}
    for name, records in samples.items():
        if not name.startswith("recovery"):
            continue
        fields = [key for key in ("t_sock_s", "t_guest_s", "t_caps_s", "t_screen_s",
                                  "t_down_s", "t_up_s", "t_ok_s", "t_up_minus_down_s")
                  if any(record.get(key) is not None for record in records)]
        table = {"samples": len(records),
                 "failed": sum(1 for record in records if record.get("ok") is False)}
        for field in fields:
            series = sorted(record[field] for record in records if record.get(field) is not None)
            table[field] = {
                "count": len(series),
                "median": f3_stats.quantile(series, 0.5) if series else None,
                "min": series[0] if series else None,
                "max": series[-1] if series else None,
                "values": series,
            }
        tables[name] = table
    return tables


def first_key(record, keys):
    for key in keys:
        if key in record and isinstance(record[key], (int, float)) and not isinstance(record[key], bool):
            return record[key]
    return None


def series_points(records, times, keys):
    """(time, value) pairs for the records that carry one of `keys`; sparse fields are kept."""
    return [(time_point, value)
            for time_point, record in zip(times, records)
            for value in [first_key(record, keys)] if value is not None]


def sample_label(record):
    for key in LABEL_KEYS:
        value = record.get(key)
        if isinstance(value, str) and value:
            return value
    pid = record.get("pid")
    return f"pid-{pid}" if pid is not None else "unknown"


# MARK: - Analysis window (§3.6)

def parse_utc_epoch(text):
    """Seconds since the epoch for an ISO UTC timestamp; None when it cannot be parsed."""
    if not isinstance(text, str) or not text:
        return None
    try:
        moment = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    if moment.tzinfo is None:
        moment = moment.replace(tzinfo=timezone.utc)
    return moment.timestamp()


def format_utc_epoch(epoch):
    return None if epoch is None else datetime.fromtimestamp(epoch, timezone.utc).isoformat()


def record_mono(record):
    value = record.get("t_mono") if isinstance(record, dict) else None
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return float(value)
    return None


def analysis_window(run_json, warmup_seconds=RESOURCE_WARMUP_SECONDS):
    """§3.6 slope window: always drop the warm-up, and drop the tail when a load phase exists.

    `details.load_seconds` is written by the soak experiment only. Latency, idle and camera
    runs have no load phase, so their window keeps every sample after the warm-up.
    """
    details = run_json.get("details") or {}
    load_seconds = details.get("load_seconds")
    started_at = run_json.get("started_at")
    window = {
        "warmup_seconds": warmup_seconds,
        "started_at": started_at,
        "load_seconds": None,
        "load_ends_at": None,
        "deadline_epoch": None,
        "tail_excluded": False,
        "reason": "run.json 无 details.load_seconds：该运行没有负载阶段，仅排除预热窗口。",
    }
    if not isinstance(load_seconds, (int, float)) or isinstance(load_seconds, bool):
        return window
    window["load_seconds"] = float(load_seconds)
    started = parse_utc_epoch(started_at)
    if started is None:
        window["reason"] = ("run.json 记录了 details.load_seconds，但 started_at 无法解析，"
                            "负载结束时刻未确定，尾段未排除。")
        return window
    deadline = started + float(load_seconds)
    window.update({
        "deadline_epoch": deadline,
        "load_ends_at": format_utc_epoch(deadline),
        "tail_excluded": True,
        "reason": ("负载阶段在 started_at + details.load_seconds 处结束；其后的空载尾段"
                   "不属于负载阶段，已排除在斜率估计之外，因此斜率只覆盖负载阶段。"),
    })
    return window


def monotonic_deadline(records, deadline_epoch):
    """Map a wall-clock deadline onto one sampler's own monotonic clock.

    Host samples and guest log samples are written by different processes, so each series is
    mapped with its own `t_wall`/`t_mono` pairs. The median offset is used so a single skewed
    record cannot move the boundary.
    """
    offsets = []
    for record in records:
        mono = record_mono(record)
        epoch = parse_utc_epoch(record.get("t_wall") if isinstance(record, dict) else None)
        if mono is not None and epoch is not None:
            offsets.append(mono - epoch)
    if not offsets:
        return None
    offsets.sort()
    middle = len(offsets) // 2
    offset = (offsets[middle] if len(offsets) % 2
              else (offsets[middle - 1] + offsets[middle]) / 2)
    return deadline_epoch + offset


def windowed_records(records, window):
    """Apply `window` to one sampler's records.

    Returns (kept_records, applied) where `applied` carries both bounds of the window in wall
    time and how many tail samples were dropped. The warm-up bound is reported here but is
    applied by resource_series / guest_log_series, which need the untrimmed series start.
    """
    applied = {"start": None, "end": None, "kept": len(records), "dropped": 0, "note": None}
    timed = [record for record in records if record_mono(record) is not None]
    if not timed:
        return records, applied
    first = min(timed, key=record_mono)
    first_epoch = parse_utc_epoch(first.get("t_wall"))
    if first_epoch is not None:
        applied["start"] = format_utc_epoch(first_epoch + window["warmup_seconds"])
    last_epoch = parse_utc_epoch(max(timed, key=record_mono).get("t_wall"))
    applied["end"] = format_utc_epoch(last_epoch)
    deadline_epoch = window.get("deadline_epoch")
    if deadline_epoch is None:
        return records, applied
    cutoff = monotonic_deadline(records, deadline_epoch)
    if cutoff is None:
        applied["note"] = "样本没有可解析的 t_wall，负载结束时刻未能定位，尾段未排除。"
        return records, applied
    kept = [record for record in records
            if record_mono(record) is None or record_mono(record) <= cutoff]
    applied.update({"kept": len(kept), "dropped": len(records) - len(kept),
                    "end": window["load_ends_at"]})
    return kept, applied


def scanned_vz_pids(host_samples):
    """§3.3 fallback: the Virtualization XPC pids the sampler's scans listed.

    `f3_host_sampler` emits a `vz_scan` record on every process tick holding the
    pids whose executable basename is the Virtualization XPC service. Runs made
    before the sampler marked each tracked process carry no `is_vz` field, but
    they do carry these scans, so the set is recoverable from the run directory.

    Returns `(pids, scanned)`; `scanned` is False when no scan succeeded, and the
    empty set then means "unknown", not "none".
    """
    pids = set()
    scanned = False
    for record in host_samples:
        if not isinstance(record, dict) or record.get("kind") != "vz_scan":
            continue
        for key in ("pids", "baseline_pids"):
            listed = record.get(key)
            if isinstance(listed, list):
                scanned = True
                pids.update(pid for pid in listed
                            if isinstance(pid, int) and not isinstance(pid, bool))
    return pids, scanned


def series_role(kind, records, vz_pids=frozenset(), vz_scanned=False):
    """§3.3: `judged` when the §3.6 growth rule applies, `covariate` when the series
    is background, `unknown` when nothing in the run identifies the process.

    Returns `(role, reason)`. Virtualization XPC processes are recognised from
    the sampler's own executable scan - the `is_vz` field it now writes on every
    tracked process, or the `vz_scan` pid lists in older runs - never from the
    operator's label or from how the pid was supplied.
    """
    if kind in COVARIATE_KINDS:
        return "covariate", f"kind={kind} 为宿主背景序列（方案 3.4）"
    if kind != "process":
        return "judged", None
    marked = {record.get("is_vz") for record in records
              if isinstance(record.get("is_vz"), bool)}
    if True in marked:
        return "covariate", "采样器标记 is_vz=true：可执行文件为 Virtualization XPC 服务"
    if marked:
        return "judged", "采样器标记 is_vz=false"
    pids = {record.get("pid") for record in records
            if isinstance(record.get("pid"), int) and not isinstance(record.get("pid"), bool)}
    if not pids:
        return "unknown", "采样记录既无 is_vz 字段也无 pid，无法判断是否为 Virtualization XPC 进程"
    if not vz_scanned:
        return "unknown", ("采样记录无 is_vz 字段，且本次运行没有成功的 vz_scan 记录，"
                           "无法判断是否为 Virtualization XPC 进程")
    if pids & vz_pids:
        return "covariate", "pid 出现在采样器的 vz_scan 列表中（旧版运行的回退依据）"
    return "judged", "pid 未出现在采样器的 vz_scan 列表中（旧版运行的回退依据）"


def resource_series(host_samples, warmup_seconds=RESOURCE_WARMUP_SECONDS):
    """Build (times_hours, values) series from host_samples.jsonl.

    Returns {"series": {...}, "roles": {...}, "unavailable": {...}}; CPU is derived from
    cumulative CPU time differences over wall-clock differences (§3.3), never from `ps %cpu`.
    """
    series = {}
    roles = {}
    role_reasons = {}
    unavailable = {}
    # Computed over every record, including the warm-up: a scan there identifies
    # the process just as well.
    vz_pids, vz_scanned = scanned_vz_pids(host_samples)
    timed = [record for record in host_samples
             if isinstance(record.get("t_mono"), (int, float))
             and not isinstance(record.get("t_mono"), bool)]
    if not timed:
        return {"series": {}, "roles": {}, "role_reasons": {},
                "unavailable": {"all": "host_samples.jsonl has no t_mono records"}}
    start = min(record["t_mono"] for record in timed)
    kept = [record for record in timed if record["t_mono"] - start >= warmup_seconds]
    if not kept:
        return {"series": {}, "roles": {}, "role_reasons": {},
                "unavailable": {"all": f"all host samples fall inside the {warmup_seconds:g}s warm-up"}}
    grouped = {}
    for record in kept:
        grouped.setdefault((record.get("kind"), sample_label(record)), []).append(record)
    for (kind, label), records in sorted(grouped.items(), key=lambda item: str(item[0])):
        records.sort(key=lambda record: record["t_mono"])
        # Times stay in seconds: f3_stats.moving_block_bootstrap_slope_ci takes block_span
        # in the same unit; slopes are converted to "per hour" in slope_record.
        times = [record["t_mono"] - start for record in records]
        built_before = set(series)
        role, role_reason = series_role(kind, records, vz_pids, vz_scanned)
        if kind == "process":
            cpu = series_points(records, times, CPU_TIME_KEYS)
            if len(cpu) > 1:
                # §3.3: cores = delta(cumulative CPU time) / delta(wall clock).
                points = [(cpu[index][0], (cpu[index][1] - cpu[index - 1][1])
                           / (cpu[index][0] - cpu[index - 1][0]))
                          for index in range(1, len(cpu))
                          if cpu[index][0] > cpu[index - 1][0]]
                if points:
                    series[f"process/{label}/cpu_cores"] = ([point[0] for point in points],
                                                            [point[1] for point in points])
            else:
                unavailable[f"process/{label}/cpu_cores"] = \
                    f"fewer than two records carry a cumulative CPU time field {CPU_TIME_KEYS}"
            for keys, name in ((FOOTPRINT_KEYS, "footprint_mib"), (RSS_KEYS, "rss_mib")):
                points = series_points(records, times, keys)
                if len(points) > 1:
                    series[f"process/{label}/{name}"] = (
                        [point[0] for point in points],
                        [point[1] / (1 << 20) for point in points])
                elif keys is FOOTPRINT_KEYS:
                    unavailable[f"process/{label}/footprint_mib"] = \
                        f"fewer than two records carry a footprint field {FOOTPRINT_KEYS}"
        elif kind == "disk":
            direct = series_points(records, times, ("allocated_bytes",))
            points = direct or [(time_point, value * 512)
                                for time_point, value in series_points(records, times, BLOCK_KEYS)]
            if len(points) > 1:
                series[f"disk/{label}/actual_mib"] = ([point[0] for point in points],
                                                      [point[1] / (1 << 20) for point in points])
            else:
                unavailable[f"disk/{label}/actual_mib"] = \
                    f"fewer than two records carry allocated_bytes or {BLOCK_KEYS}"
        elif kind == "file":
            # §3.7: host-side log files sampled by f3_host_sampler --file.
            points = series_points(records, times, SIZE_KEYS)
            if len(points) > 1:
                series[f"file/{label}/size_kib"] = ([point[0] for point in points],
                                                    [point[1] / 1024 for point in points])
            else:
                unavailable[f"file/{label}/size_kib"] = \
                    f"fewer than two records carry a size field {SIZE_KEYS}"
        elif kind == "df":
            points = series_points(records, times, AVAILABLE_KEYS)
            if len(points) > 1:
                series[f"df/{label}/available_mib"] = ([point[0] for point in points],
                                                       [point[1] / (1 << 20) for point in points])
        elif kind == "host":
            for key in ("swapins", "swapouts", "swap_used_bytes", "load_average_1m"):
                points = series_points(records, times, (key,))
                if len(points) > 1:
                    series[f"host/{key}"] = ([point[0] for point in points],
                                             [point[1] for point in points])
        for name in set(series) - built_before:
            roles[name] = role
            role_reasons[name] = role_reason
    return {"series": series, "roles": roles, "role_reasons": role_reasons,
            "unavailable": unavailable}


def guest_log_series(records, warmup_seconds=RESOURCE_WARMUP_SECONDS):
    """Build `guest_log/<basename>/size_kib` series from samples/guest_log.jsonl (§3.7)."""
    series = {}
    roles = {}
    unavailable = {}
    if not records:
        return {"series": {}, "roles": {}, "role_reasons": {}, "unavailable": {}}
    timed = [record for record in records
             if isinstance(record.get("t_mono"), (int, float))
             and not isinstance(record.get("t_mono"), bool)]
    if not timed:
        return {"series": {}, "roles": {}, "role_reasons": {},
                "unavailable": {"guest_log": "guest_log.jsonl has no t_mono records"}}
    start = min(record["t_mono"] for record in timed)
    grouped = {}
    for record in timed:
        grouped.setdefault(posixpath.basename(str(record.get("path") or "unknown")), []).append(record)
    for label, rows in sorted(grouped.items()):
        rows.sort(key=lambda record: record["t_mono"])
        points = [(record["t_mono"] - start, record["size_bytes"] / 1024)
                  for record in rows
                  if record.get("ok") is True
                  and isinstance(record.get("size_bytes"), (int, float))
                  and not isinstance(record.get("size_bytes"), bool)
                  and record["t_mono"] - start >= warmup_seconds]
        name = f"guest_log/{label}/size_kib"
        if len(points) > 1:
            series[name] = ([point[0] for point in points], [point[1] for point in points])
            # §3.3: log files stay inside the set the growth rule is applied to.
            roles[name] = "judged"
        else:
            unavailable[name] = (
                f"only {len(points)} reading(s) with a size outside the "
                f"{warmup_seconds:g}s warm-up among {len(rows)} sample(s)")
    return {"series": series, "roles": roles, "role_reasons": {}, "unavailable": unavailable}


def slope_record(times, values, seed, resamples, confidence,
                 dominance_share=f3_stats.STEP_DOMINANCE_SHARE, role="judged",
                 role_reason=None):
    """Theil-Sen slope, bootstrap interval and step report for one series.

    The slope and the interval bounds are in value unit per hour. The step
    report (§3.6, evidence 10.11) keeps its deltas in the series' own unit and
    its offsets in seconds from the first point of the analysis window.
    """
    slope = f3_stats.theil_sen(times, values) * 3600.0
    interval = f3_stats.moving_block_bootstrap_slope_ci(
        times, values, block_span=BLOCK_SECONDS, seed=seed, resamples=resamples,
        confidence=confidence)
    bounds = interval.get("ci")
    low, high = (bounds[0] * 3600.0, bounds[1] * 3600.0) if bounds else (None, None)
    steps = f3_stats.step_summary(times, values, dominance_share=dominance_share)
    origin = times[0] if times else 0.0
    return {"slope_per_hour": slope, "slope": slope, "ci_low": low, "ci_high": high,
            "ci": [low, high] if bounds else None,
            "ci_reason": interval.get("reason"), "block_count": interval.get("block_count"),
            "count": len(values), "first_value": values[0], "last_value": values[-1],
            "max_value": max(values),
            "span_hours": (times[-1] - times[0]) / 3600.0 if times else None,
            "role": role, "role_reason": role_reason,
            "steps": [{"offset_s": step["time"] - origin,
                       "offset_minutes": (step["time"] - origin) / 60.0,
                       "delta": step["delta"]}
                      for step in steps["steps"]],
            "step_count": steps["step_count"],
            "step_delta_sum": steps["step_delta_sum"],
            "step_aligned_sum": steps["aligned_delta_sum"],
            "net_change": steps["net_change"],
            "step_dominated_share": steps["dominated_share"],
            "step_dominated": steps["step_dominated"],
            "step_criterion": {"mad_multiplier": steps["mad_multiplier"],
                               "dominance_share": steps["dominance_share"],
                               "scale": steps["scale"],
                               "scale_source": steps["scale_source"],
                               "median_difference": steps["median_difference"],
                               "threshold": steps["threshold"]},
            **head_tail_means(times, values)}


def head_tail_means(times, values, window=600.0):
    """§3.6 cross-check: mean over the first and last `window` seconds and their difference."""
    head = [value for time_point, value in zip(times, values) if time_point <= times[0] + window]
    tail = [value for time_point, value in zip(times, values) if time_point >= times[-1] - window]
    head_mean, tail_mean = mean(head), mean(tail)
    return {"head_window_mean": head_mean, "tail_window_mean": tail_mean,
            "head_tail_delta": None if head_mean is None or tail_mean is None
            else tail_mean - head_mean}


def growth_verdicts(per_run):
    """Apply the §3.6 decision rule via f3_stats.growth_verdict, with a recorded fallback."""
    verdicts = {}
    for metric, runs in sorted(per_run.items()):
        try:
            verdict = f3_stats.growth_verdict(runs)
            source = "f3_stats.growth_verdict"
        except (TypeError, KeyError, ValueError, AttributeError, IndexError) as error:
            verdict = local_growth_verdict(runs)
            source = f"local fallback ({type(error).__name__})"
        verdicts[metric] = {"verdict": verdict, "verdict_source": source,
                            "role": metric_role_of_runs(runs), "runs": runs}
    return verdicts


def local_growth_verdict(runs):
    """§3.6: candidate when the CI lower bound > 0; confirmed when two runs agree in sign.

    Runs whose net change is dominated by discrete steps do not support a
    continuous-growth claim and give `step_dominated` instead (10.11).
    """
    positive = [item for item in runs
                if item.get("ci_low") is not None and item["ci_low"] > 0]
    dominated = [item for item in positive if item.get("step_dominated") is True]
    positive = [item for item in positive if item.get("step_dominated") is not True]
    if len(positive) >= 2 and len({item["slope"] > 0 for item in positive}) == 1:
        return "confirmed"
    if positive:
        return "candidate"
    return "step_dominated" if dominated else "not_detected"


def metric_role_of_runs(runs):
    """§3.3 role across the runs of one metric.

    `covariate` only when every run agrees, `unknown` when any run could not
    identify the process, otherwise `judged`.
    """
    roles = {item.get("role", "judged") for item in runs}
    if roles == {"covariate"}:
        return "covariate"
    if "unknown" in roles:
        return "unknown"
    return "judged"


def vz_attribution(record, expected=2, window_seconds=60.0):
    """§3.3 VZ XPC ownership: PID set difference plus lstart inside the spawn window."""
    before = record.get("vz_pids_before")
    after = record.get("vz_pids_after")
    if not isinstance(before, list) or not isinstance(after, list):
        return {"attributed": False, "pids": [],
                "reason": "归属不确定：未记录启动前后的 VZ 进程 PID 集合"}
    new = sorted(set(after) - set(before))
    if len(new) != expected:
        return {"attributed": False, "pids": new,
                "reason": f"归属不确定：新增 VZ 进程 {len(new)} 个，预期 {expected} 个"}
    spawn = record.get("spawn_epoch")
    starts = record.get("vz_lstart") or {}
    unchecked = [pid for pid in new if not isinstance(starts.get(str(pid)), (int, float))]
    if not isinstance(spawn, (int, float)) or unchecked:
        return {"attributed": False, "pids": new,
                "reason": "归属不确定：缺少 spawn 时刻或新增进程的 lstart 数值"}
    late = [pid for pid in new if not 0 <= starts[str(pid)] - spawn <= window_seconds]
    if late:
        return {"attributed": False, "pids": new,
                "reason": f"归属不确定：进程 {late} 的 lstart 不在 spawn 后 {window_seconds:g} 秒内"}
    return {"attributed": True, "pids": new, "reason": None}


def summarize_runs(directories, seed, resamples, confidence, expected_vz,
                   dominance_share=f3_stats.STEP_DOMINANCE_SHARE):
    loaded = [load_run_directory(directory) for directory in directories]
    summary = {
        "schema_version": SCHEMA_VERSION,
        "generated_at": f3_common.utc_now(),
        "seed": seed,
        "resamples": resamples,
        "confidence": confidence,
        "step_detection": {"mad_multiplier": f3_stats.STEP_MAD_MULTIPLIER,
                           "dominance_share": dominance_share},
        "runs": [],
        "growth": {},
    }
    per_metric = {}
    for item in loaded:
        run_json = item["run"]
        window = analysis_window(run_json)
        host_samples, host_applied = windowed_records(item["host_samples"], window)
        guest_log, guest_applied = windowed_records(
            item["samples"].get("guest_log", []), window)
        resources = resource_series(host_samples)
        logs = guest_log_series(guest_log)
        resources["series"].update(logs["series"])
        resources["roles"].update(logs["roles"])
        resources["role_reasons"].update(logs.get("role_reasons") or {})
        resources["unavailable"].update(logs["unavailable"])
        slopes = {}
        for metric, (times, values) in sorted(resources["series"].items()):
            if len(values) < 3:
                resources["unavailable"][metric] = f"only {len(values)} points; no slope estimated"
                continue
            try:
                slopes[metric] = slope_record(
                    times, values, seed, resamples, confidence,
                    dominance_share=dominance_share,
                    role=resources["roles"].get(metric, "judged"),
                    role_reason=resources["role_reasons"].get(metric))
            except ValueError as error:
                resources["unavailable"][metric] = f"slope undefined: {error}"
                continue
            per_metric.setdefault(metric, []).append(slopes[metric])
        entry = {
            "path": item["path"],
            "experiment": run_json.get("experiment"),
            "run_id": run_json.get("run_id"),
            "started_at": run_json.get("started_at"),
            "finished_at": run_json.get("finished_at"),
            "interrupted": run_json.get("interrupted"),
            "aborted": run_json.get("aborted"),
            "counts": run_json.get("counts"),
            "latency": latency_tables(item["samples"], seed, resamples),
            "recovery": recovery_tables(item["samples"]),
            "resources": {
                "slopes": slopes,
                "unavailable": resources["unavailable"],
                "window": {
                    "warmup_seconds": window["warmup_seconds"],
                    "load_seconds": window["load_seconds"],
                    "started_at": window["started_at"],
                    "load_ends_at": window["load_ends_at"],
                    "tail_excluded": window["tail_excluded"],
                    "reason": window["reason"],
                    "sources": {"host_samples": host_applied, "guest_log": guest_applied},
                },
            },
            "camera": camera_metrics(item["camera_samples"]) if item["camera_samples"] else None,
            "vz_attribution": [
                {"iteration": record.get("iteration"), **vz_attribution(record, expected_vz)}
                for record in item["samples"].get("recovery_boot", [])
            ],
        }
        summary["runs"].append(entry)
    summary["growth"] = growth_verdicts(per_metric)
    return summary


def table(headers, rows):
    lines = ["| " + " | ".join(headers) + " |",
             "| " + " | ".join("---" for _ in headers) + " |"]
    for row in rows:
        lines.append("| " + " | ".join("—" if value is None else str(value) for value in row) + " |")
    return "\n".join(lines)


def number(value, digits=3):
    if value is None:
        return None
    return f"{value:.{digits}f}"


def interval_text(pair, digits=3):
    if not isinstance(pair, (list, tuple)) or len(pair) != 2 or pair[0] is None:
        return None
    return f"[{pair[0]:.{digits}f}, {pair[1]:.{digits}f}]"


def role_text(role):
    """§3.3 metric role as it appears in the tables."""
    if role == "covariate":
        return "背景协变量"
    if role == "unknown":
        return "归属未知"
    return "判定对象"


def step_text(values):
    """One cell summarising the §3.6 step detection for one series."""
    count = values.get("step_count") or 0
    if not count:
        return "无"
    share = values.get("step_dominated_share")
    share_text = "净变化为 0" if share is None else f"占净变化 {share * 100:.1f}%"
    mark = "，阶跃主导" if values.get("step_dominated") else ""
    return f"{count} 次，{share_text}{mark}"


def step_lines(resources, detection):
    """The §3.6 step list stated next to the slope table (evidence 10.11)."""
    criterion = detection or {}
    multiplier = criterion.get("mad_multiplier")
    share = criterion.get("dominance_share")
    lines = [("阶跃检测（方案 3.6）：逐点差分中偏离差分中位数超过 "
              f"{multiplier if multiplier is not None else '—'} 倍稳健尺度的点记为阶跃。稳健尺度"
              "优先取差分的离散度（中位数绝对偏差与四分位距除以 1.349 的较大者）；该离散度为 0 时"
              "（差分四分之三以上取同一值，如整 MiB 量化序列）改由移动量给出：序列在最小移动量"
              "构成的格点上且数值远高于该格点时，以该量化步长为尺度，否则以移动量的中位数为尺度，"
              "使量化台阶不被读作离散事件。与净变化同向的阶跃合计占该净变化的比例超过 "
              f"{share if share is not None else '—'} 时判为阶跃主导，该序列的斜率不能读作速率"
              "（依据 10.11）。")]
    detailed = [(metric, values) for metric, values in sorted((resources.get("slopes") or {}).items())
                if values.get("step_count")]
    if not detailed:
        lines.append("本次运行的全部序列均未检出阶跃。")
        return lines
    for metric, values in detailed:
        items = "；".join(f"t+{step['offset_minutes']:.2f} 分 {step['delta']:+.3f}"
                          for step in values.get("steps") or [])
        share = values.get("step_dominated_share")
        share_text = "净变化为 0" if share is None else f"占净变化 {share * 100:.1f}%"
        lines.append(f"- {metric}：{values['step_count']} 次阶跃（{items}），合计 "
                     f"{values.get('step_delta_sum', 0.0):+.3f}，其中与净变化同向 "
                     f"{values.get('step_aligned_sum', 0.0):+.3f}，净变化 "
                     f"{values.get('net_change', 0.0):+.3f}，{share_text}"
                     f"{'，阶跃主导' if values.get('step_dominated') else ''}。")
    return lines


def window_lines(window):
    """The §3.6 analysis window stated next to the slope table."""
    if not window:
        return []
    sources = window.get("sources") or {}
    host = sources.get("host_samples") or {}
    guest = sources.get("guest_log") or {}
    start = host.get("start") or guest.get("start") or "未记录"
    end = window.get("load_ends_at") or host.get("end") or guest.get("end") or "未记录"
    text = (f"分析窗口：{start} 至 {end}；起点为宿主采样起始时刻后 "
            f"{window['warmup_seconds']:g} 秒（预热排除）。{window['reason']}")
    if window.get("tail_excluded"):
        text += (f"本次剔除宿主采样尾段 {host.get('dropped', 0)} 条、"
                 f"客户机日志尾段 {guest.get('dropped', 0)} 条。")
    lines = [text]
    lines.extend(f"{name} 采样：{value['note']}"
                 for name, value in (("宿主", host), ("客户机日志", guest))
                 if value.get("note"))
    return lines


def summary_markdown(summary):
    lines = ["# F3 性能基线汇总", "",
             f"生成时间：{summary['generated_at']}；随机种子：{summary['seed']}；"
             f"重采样次数：{summary['resamples']}；置信水平：{summary['confidence']}。", "",
             "分位数为线性插值；置信区间为 bootstrap 95% 区间。失败样本不参与分位数计算。", ""]
    for entry in summary["runs"]:
        lines.append(f"## 运行 {entry['run_id']}（{entry['experiment']}）")
        lines.append("")
        lines.append(f"目录：`{entry['path']}`；开始：{entry['started_at']}；结束：{entry['finished_at']}。")
        if entry.get("interrupted"):
            lines.append(f"该运行被信号 {entry['interrupted']} 中断，样本不完整。")
        if entry.get("aborted"):
            lines.append(f"该运行提前结束：{entry['aborted']}")
        lines.append("")
        classes = entry["latency"]["classes"]
        if classes:
            lines.append("### 命令延迟（毫秒）")
            lines.append("")
            rows = []
            for label, stats in classes.items():
                rows.append([label, stats.get("count"), number(stats.get("p50")),
                             number(stats.get("p90")), number(stats.get("p99")),
                             interval_text(stats.get("p50_ci")), interval_text(stats.get("p99_ci")),
                             number(stats.get("min")), number(stats.get("max"))])
            lines.append(table(["命令类", "样本数", "p50", "p90", "p99", "p50 区间", "p99 区间",
                                "最小", "最大"], rows))
            lines.append("")
        failures = entry["latency"]["failures_by_code"]
        if failures:
            lines.append("### 失败样本（按 code 计数）")
            lines.append("")
            rows = [[label, code, count]
                    for label, codes in sorted(failures.items())
                    for code, count in sorted(codes.items())]
            lines.append(table(["命令类", "code", "次数"], rows))
            lines.append("")
        for name, recovery in sorted(entry["recovery"].items()):
            lines.append(f"### 恢复区间 {name}（秒）")
            lines.append("")
            rows = [[field, values["count"], number(values["median"]), number(values["min"]),
                     number(values["max"])]
                    for field, values in sorted(recovery.items())
                    if isinstance(values, dict)]
            lines.append(table(["区间", "样本数", "中位数", "最小", "最大"], rows))
            lines.append(f"样本数 {recovery['samples']}，失败 {recovery['failed']}。轮询分辨率误差上界等于轮询间隔。")
            lines.append("")
        slopes = entry["resources"]["slopes"]
        if slopes:
            lines.append("### 资源时间序列斜率（每小时；已排除启动后前 10 分钟）")
            lines.append("")
            rows = [[metric, role_text(values.get("role")), values["count"],
                     number(values["slope_per_hour"]),
                     interval_text(values["ci"]), number(values["first_value"]),
                     number(values["last_value"]), number(values["max_value"]),
                     step_text(values)]
                    for metric, values in sorted(slopes.items())]
            lines.append(table(["指标", "口径", "样本数", "Theil–Sen 斜率", "移动块 bootstrap 区间",
                                "首值", "末值", "最大值", "阶跃"], rows))
            lines.append("斜率单位为指标名后缀对应的单位每小时（footprint_mib 为 MiB、size_kib 为 KiB、"
                         "cpu_cores 为核）；区间为块长 5 分钟的移动块 bootstrap 95% 区间。")
            lines.append("“口径”按方案 3.3：判定对象参与 3.6 增长判定；背景协变量（Virtualization "
                         "XPC 进程、宿主整体与数据卷序列）同样采样与报告，但不做增长判定；"
                         "归属未知表示本次运行的采样记录不足以判断该进程是否为 Virtualization "
                         "XPC 服务，其增长结论不成立。")
            lines.extend(f"- {metric} 口径依据：{values['role_reason']}"
                         for metric, values in sorted(slopes.items())
                         if values.get("role_reason") and values.get("role") != "judged")
            lines.extend(step_lines(entry["resources"], summary.get("step_detection")))
            lines.extend(window_lines(entry["resources"].get("window")))
            lines.append("")
        unavailable = entry["resources"]["unavailable"]
        if unavailable:
            lines.append("未构建的资源序列：")
            lines.extend(f"- {metric}：{reason}" for metric, reason in sorted(unavailable.items()))
            lines.append("")
        if entry["vz_attribution"]:
            lines.append("### VZ XPC 进程归属")
            lines.append("")
            rows = [[item["iteration"], "已归属" if item["attributed"] else "归属不确定",
                     ",".join(str(pid) for pid in item["pids"]) or None, item["reason"]]
                    for item in entry["vz_attribution"]]
            lines.append(table(["轮次", "结果", "新增 PID", "说明"], rows))
            lines.append("")
        if entry["camera"]:
            camera = entry["camera"]
            lines.append("### 相机指标")
            lines.append("")
            rows = [
                ["样本数", camera["samples"]],
                ["可用样本数", camera["usable_samples"]],
                ["回执可用率", number(camera["receipt_availability"])],
                ["宿主安排速率 r_sched（帧/秒，中位数）", number(camera["r_sched_p50"])],
                ["客户机发布速率 r_pub（帧/秒，中位数）", number(camera["r_pub_p50"])],
                ["传输缺失率（窗口均值）", number(camera["transport_loss_mean"])],
                ["积压估计（最大/末值）",
                 f"{camera['backlog_max']}/{camera['backlog_last']}"],
                ["消费滞后帧数（均值/最大）",
                 f"{number(camera['lag_frames_mean'])}/{camera['lag_frames_max']}"],
                ["发布→复制延迟 p50（毫秒）", number(camera["publish_to_copy_ms"]["p50"])],
                ["发布→复制延迟可用样本比例",
                 number(camera["publish_to_copy_ms"]["fraction_of_usable"])],
                ["消费跳帧上界", number(camera["consumer_skip_upper_bound"])],
            ]
            lines.append(table(["指标", "值"], rows))
            lines.append("宿主与客户机没有共同时钟字段，端到端延迟不在本表内（方案 3.5）。")
            lines.append("")
    if summary["growth"]:
        lines.append("## 增长判定（方案 3.6）")
        lines.append("")
        rows = [[metric, role_text(item.get("role")), item["verdict"], len(item["runs"]),
                 "；".join(interval_text(run["ci"]) or "—" for run in item["runs"]),
                 "；".join(step_text(run) for run in item["runs"]),
                 item["verdict_source"]]
                for metric, item in sorted(summary["growth"].items())]
        lines.append(table(["指标", "口径", "判定", "运行数", "各运行区间", "各运行阶跃",
                            "判定来源"], rows))
        lines.append("")
        lines.append("判定取值：confirmed 表示两次独立运行均区间下限 > 0、斜率同号且都未被阶跃主导；"
                     "candidate 表示单次运行满足该条件；step_dominated 表示区间下限 > 0 的运行"
                     "其净变化由离散阶跃主导，区间排除 0 来自窗口内的跳变而不是速率（10.11）；"
                     "not_detected 表示未检出持续增长。")
        lines.append("口径为“背景协变量”的行按方案 3.3 不作为被测对象的增长结论，只作背景记录；"
                     "口径为“归属未知”的行缺少判断进程身份的采样证据，其判定不作结论。")
        lines.append("")
    return "\n".join(lines) + "\n"


def run_summarize(args, raw_argv):
    output = Path(args.out).expanduser().resolve()
    f3_common.create_output_directory(output)
    summary = summarize_runs(args.runs, args.seed, args.resamples, args.confidence,
                             args.expected_vz_processes, args.step_dominance_share)
    summary["invocation"] = {"argv": f3_common.redact_argv(raw_argv)}
    f3_common.write_json(output / "summary.json", summary)
    (output / "summary.md").write_text(summary_markdown(summary))
    print(f"summary.json: {output / 'summary.json'}")
    print(f"summary.md:   {output / 'summary.md'}")
    return 0


# MARK: - CLI

EXPERIMENTS = {
    "latency": run_latency,
    "recovery-boot": run_recovery_boot,
    "recovery-daemon": run_recovery_daemon,
    "soak": run_soak,
    "idle": run_idle,
    "camera": run_camera,
}


def add_common(parser):
    parser.add_argument("--sock", type=Path, required=True, help="<vm>/vphone.sock")
    parser.add_argument("--name", default="vm", help="instance name recorded with every sample")
    parser.add_argument("--out", type=Path, required=True, help="output directory (must not exist)")
    parser.add_argument("--seed", type=int, default=20260918, help="fixed random seed")
    parser.add_argument("--timeout", type=float, default=30.0, help="per-request timeout seconds")
    parser.add_argument("--note", default=None, help="free-form note recorded in run.json")
    parser.add_argument("--bundle", type=Path, help="VM bundle directory; config.plist is recorded")
    parser.add_argument("--vphone-cli", dest="vphone_cli", type=Path,
                        help="vphone-cli executable to hash into run.json")
    parser.add_argument("--vphoned", type=Path, help=".vphoned.signed to hash into run.json")
    parser.add_argument("--guest-dir", default=GUEST_ROOT,
                        help=f"guest directory for benchmark files (must stay under {GUEST_ROOT})")
    parser.add_argument("--max-consecutive-failures", type=int,
                        default=DEFAULT_MAX_CONSECUTIVE_FAILURES,
                        help="abort after this many consecutive failed requests (default 20)")
    parser.add_argument("--guest-log", action="append", dest="guest_log", default=None,
                        help="guest log file whose size is read with shell stat; repeatable "
                             f"(default {DEFAULT_GUEST_LOG})")
    parser.add_argument("--guest-log-interval", type=float, default=DEFAULT_GUEST_LOG_INTERVAL,
                        help="seconds between guest log size readings (default 600)")


def add_location(parser):
    parser.add_argument("--latitude", type=float, default=31.2304)
    parser.add_argument("--longitude", type=float, default=121.4737)
    parser.add_argument("--heartbeat", type=float, default=1.0, help="location heartbeat_s")


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    subparsers = parser.add_subparsers(dest="command", required=True)

    latency = subparsers.add_parser("latency", help="§3.1 command latency distribution")
    add_common(latency)
    add_location(latency)
    latency.add_argument("--commands", help="comma list of command classes (default: all available)")
    latency.add_argument("--samples", type=int, help="override the per-class sample count")
    latency.add_argument("--warmup", type=int, default=WARMUP_SAMPLES,
                         help="warm-up requests per class, excluded from statistics (default 10)")
    latency.add_argument("--concurrency", type=int, default=1)
    latency.add_argument("--bundle-id", default="com.apple.Preferences")
    # The Settings list scrolls during the interleaved swipe rounds, so a tap
    # inside the cards stops being non-interactive and navigates into a
    # subpage. x=33 stays in the left margin outside the cards at every scroll
    # offset (cards start at x=67 on a 1290-wide screen).
    latency.add_argument("--tap-x", type=int, default=33)
    latency.add_argument("--tap-y", type=int, default=1400)
    latency.add_argument("--swipe-x", type=int, default=645)
    latency.add_argument("--swipe-y1", type=int, default=2000)
    latency.add_argument("--swipe-y2", type=int, default=1200)
    latency.add_argument("--swipe-ms", type=int, default=DEFAULT_SWIPE_MS,
                         help=f"swipe duration sent as ms (default {DEFAULT_SWIPE_MS})")
    latency.add_argument("--tap-spacing-ms", type=float, default=DEFAULT_TAP_SPACING_MS,
                         help="minimum milliseconds between two tap injections, measured "
                              f"start to start (default {DEFAULT_TAP_SPACING_MS})")
    latency.add_argument("--swipe-spacing-ms", type=float, default=None,
                         help="minimum milliseconds between two swipe injections, measured "
                              f"start to start (default --swipe-ms + {GESTURE_SPACING_MARGIN_MS})")
    latency.add_argument("--cleanup-guest-files", action="store_true",
                         help=f"delete {GUEST_ROOT} on the guest when the run finishes")
    latency.add_argument("--list-commands", action="store_true",
                         help="print the command classes and exit without sending requests")

    boot = subparsers.add_parser("recovery-boot", help="§3.2 cold boot recovery")
    add_common(boot)
    boot.add_argument("--allow-vm-lifecycle", action="store_true",
                      help="required: this experiment starts and stops the VM")
    boot.add_argument("--launch-command", required=True,
                      help="launch command line, split with shlex and run without a shell")
    boot.add_argument("--stop-command", help="stop command line, split with shlex")
    boot.add_argument("--count", type=int, default=10)
    boot.add_argument("--gap", type=float, default=60.0, help="seconds between iterations")
    boot.add_argument("--boot-timeout", type=float, default=600.0)
    boot.add_argument("--expect-capabilities", default="",
                      help="comma list required for t_caps (default: any nonempty declaration)")
    boot.add_argument("--no-screen", action="store_true", help="skip the t_screen screenshot probe")

    daemon = subparsers.add_parser("recovery-daemon", help="§3.2 vphoned restart recovery (jb/exp)")
    add_common(daemon)
    daemon.add_argument("--kill-command", default=DEFAULT_KILL_COMMAND,
                        help="guest shell command that terminates vphoned")
    daemon.add_argument("--samples", type=int, default=20)
    daemon.add_argument("--gap", type=float, default=5.0)
    daemon.add_argument("--restart-timeout", type=float, default=60.0)

    soak = subparsers.add_parser("soak", help="E4 fixed-rate repeated load")
    add_common(soak)
    add_location(soak)
    soak.add_argument("--minutes", type=float, default=60.0)
    soak.add_argument("--tail-minutes", type=float, default=5.0)
    soak.add_argument("--interval", type=float, default=2.0, help="seconds per load cycle")
    soak.add_argument("--tail-interval", type=float, default=60.0)
    soak.add_argument("--location-interval", type=float, default=600.0)

    idle = subparsers.add_parser("idle", help="E5a/E5b idle observation")
    add_common(idle)
    add_location(idle)
    idle.add_argument("--minutes", type=float, default=60.0)
    idle.add_argument("--interval", type=float, default=60.0)
    idle.add_argument("--location-source", action="store_true",
                      help="E5b: hold a fixed location source for the whole run")

    camera = subparsers.add_parser("camera", help="§3.5 camera rate and loss (exp)")
    add_common(camera)
    camera.add_argument("--image", type=Path, required=True)
    camera.add_argument("--fps", type=int, default=8)
    camera.add_argument("--minutes", type=float, default=30.0)
    camera.add_argument("--interval", type=float, default=2.0)
    camera.add_argument("--role", default="qr")
    camera.add_argument("--receipt-wait", type=float, default=30.0)
    camera.add_argument("--consumer-bundle-id", default="com.apple.camera")
    camera.add_argument("--launch-consumer", action="store_true")

    summarize = subparsers.add_parser("summarize", help="write summary.json and summary.md")
    summarize.add_argument("runs", nargs="+", help="one or more run directories")
    summarize.add_argument("--out", type=Path, required=True, help="output directory (must not exist)")
    summarize.add_argument("--seed", type=int, default=20260918)
    summarize.add_argument("--resamples", type=int, default=2000)
    summarize.add_argument("--confidence", type=float, default=0.95)
    summarize.add_argument("--expected-vz-processes", type=int, default=2)
    summarize.add_argument("--step-dominance-share", type=float,
                           default=f3_stats.STEP_DOMINANCE_SHARE,
                           help="a series is reported as step dominated when the detected "
                                "steps account for more than this share of its net change "
                                f"(default {f3_stats.STEP_DOMINANCE_SHARE}); recorded in "
                                "summary.json")
    return parser.parse_args(argv)


def validate(args):
    if args.command == "summarize":
        if not 0.0 < args.step_dominance_share <= 1.0:
            raise BenchmarkError("--step-dominance-share must lie in (0, 1]")
        return None
    if args.timeout <= 0 or args.timeout > 300:
        raise BenchmarkError("--timeout must be in (0, 300]")
    check_guest_directory(args.guest_dir)
    args.guest_log = [check_guest_log_path(path)
                      for path in (args.guest_log or [DEFAULT_GUEST_LOG])]
    if args.guest_log_interval <= 0:
        raise BenchmarkError("--guest-log-interval must be positive")
    socket_path = check_socket_path(args.sock)
    if args.command == "recovery-boot" and not args.allow_vm_lifecycle:
        raise BenchmarkError(
            "recovery-boot starts and stops the VM; pass --allow-vm-lifecycle to authorize it")
    if args.command == "latency" and args.concurrency < 1:
        raise BenchmarkError("--concurrency must be >= 1")
    return socket_path


def main(argv=None):
    raw_argv = list(sys.argv[1:] if argv is None else argv)
    args = parse_args(raw_argv)
    try:
        validate(args)
    except BenchmarkError as error:
        print(f"f3: {error}", file=sys.stderr)
        return 2
    if args.command == "summarize":
        try:
            return run_summarize(args, raw_argv)
        except (BenchmarkError, OSError, ValueError) as error:
            print(f"f3 summarize: {error}", file=sys.stderr)
            return 2
    output = Path(args.out).expanduser().resolve()
    try:
        f3_common.create_output_directory(output)
    except (OSError, ValueError) as error:
        print(f"f3: output directory unusable: {error}", file=sys.stderr)
        return 2
    endpoint = None
    if args.command != "recovery-boot":
        try:
            endpoint = resolve_endpoint(args.name, args.sock)
        except (AcceptanceFailure, OSError) as error:
            print(f"f3: host-control socket unusable: {error}", file=sys.stderr)
            return 2
    run = Run(args, args.command, output, endpoint)
    run.install_signal_handlers()
    status = 0
    try:
        EXPERIMENTS[args.command](run, raw_argv)
    except TooManyFailures as error:
        run.aborted = str(error)
        status = 1
    except (BenchmarkError, AcceptanceFailure, OSError, subprocess.SubprocessError) as error:
        run.aborted = f"{type(error).__name__}: {error}"
        status = 1
    finally:
        parameters = {key: (str(value) if isinstance(value, Path) else value)
                      for key, value in sorted(vars(args).items())
                      if key not in ("out", "sock", "bundle", "vphone_cli", "vphoned")}
        summary = run.write_run_json(parameters, raw_argv)
        run.close()
    print(f"{args.command}: {run.request_count} requests, "
          f"{sum(run.failures_by_code.values())} failed; run.json: {output / 'run.json'}")
    if run.aborted:
        print(f"aborted: {run.aborted}", file=sys.stderr)
    if summary["interrupted"]:
        return 130
    return status


if __name__ == "__main__":
    sys.exit(main())
