#!/usr/bin/env python3
"""Shared evidence helpers for the F3 performance baseline tools.

The module holds the evidence primitives that scripts/f1_runtime_acceptance.py
already used (utc_now, sha256_file, redact, redact_argv, git_state, host_info)
plus the output primitives that the F3 scripts require: an output directory that
must not exist, a flushing JSONL writer, an atomic JSON writer and the host
record defined in research/f3_performance_baseline_plan_2026-09-18.md §2.1.

Every external command runs through run_command(), which never raises: a failed
command returns an "error" string so that a long run is not aborted by a single
read-only command. host_record() takes an optional runner so that callers can
inject their own command executor.

Standard library only (plan §9 decision 9: no NumPy, no third-party packages).
"""

import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import time


ROOT = Path(__file__).resolve().parents[1]
SENSITIVE_KEY = re.compile(r"pass(word|wd)?|token|secret|credential|authorization|cookie|api[_-]?key",
                           re.IGNORECASE)
BASE64_KEYS = ("data", "data_b64", "image")

SYSCTL = "/usr/sbin/sysctl"
SW_VERS = "/usr/bin/sw_vers"
PMSET = "/usr/bin/pmset"
DF = "/bin/df"
PS = "/bin/ps"
STAT = "/usr/bin/stat"
VM_STAT = "/usr/bin/vm_stat"
FOOTPRINT = "/usr/bin/footprint"
MEMORY_PRESSURE = "/usr/bin/memory_pressure"

DATA_VOLUME = "/System/Volumes/Data"
HOST_SYSCTL_KEYS = ("hw.model", "hw.memsize", "hw.ncpu",
                    "hw.perflevel0.physicalcpu", "hw.perflevel1.physicalcpu")
DEFAULT_COMMAND_TIMEOUT = 15.0


# MARK: - Evidence helpers

def utc_now():
    return datetime.now(timezone.utc).isoformat()


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def redact(value):
    """Remove credentials and replace inline base64 payloads with length and digest."""
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            if isinstance(key, str) and SENSITIVE_KEY.search(key):
                result[key] = "<redacted>"
            elif key in BASE64_KEYS and isinstance(item, str):
                try:
                    decoded = base64.b64decode(item, validate=True)
                    result[key] = {"omitted_base64_bytes": len(decoded),
                                   "sha256": hashlib.sha256(decoded).hexdigest()}
                except ValueError:
                    result[key] = {"omitted_text_chars": len(item)}
            else:
                result[key] = redact(item)
        return result
    if isinstance(value, list):
        return [redact(item) for item in value]
    return value


def redact_argv(argv):
    result = []
    hide_next = False
    for item in argv:
        if hide_next:
            result.append("<redacted>")
            hide_next = False
            continue
        flag = item.split("=", 1)[0]
        if item.startswith("--") and SENSITIVE_KEY.search(flag):
            if "=" in item:
                result.append(f"{flag}=<redacted>")
            else:
                result.append(item)
                hide_next = True
            continue
        result.append(item)
    return result


def git_state():
    try:
        commit = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], capture_output=True,
                                text=True, timeout=10).stdout.strip() or None
        porcelain = subprocess.run(["git", "-C", str(ROOT), "status", "--porcelain"],
                                   capture_output=True, text=True, timeout=10)
        clean = porcelain.returncode == 0 and porcelain.stdout.strip() == ""
        return commit, clean if porcelain.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None, None


def host_info():
    memory = None
    try:
        output = subprocess.run([SYSCTL, "-n", "hw.memsize"], capture_output=True,
                                text=True, timeout=5).stdout.strip()
        memory = round(int(output) / (1 << 30), 1) if output else None
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return {"macos": platform.mac_ver()[0] or None, "machine": platform.machine(),
            "cpu": os.cpu_count(), "memory_gib": memory}


# MARK: - Output primitives

def create_output_directory(path):
    """Create a new evidence directory. The path must not exist (plan §5)."""
    directory = Path(path).expanduser()
    if directory.exists() or directory.is_symlink():
        raise ValueError(f"output directory already exists: {directory}")
    directory.mkdir(parents=True)
    return directory.resolve()


class JsonlWriter:
    """Append-only JSONL writer; one compact record per line, flushed immediately."""

    def __init__(self, path):
        self.path = Path(path)
        self.count = 0
        self._stream = self.path.open("a", encoding="utf-8")

    def write(self, record):
        line = json.dumps(record, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        self._stream.write(line + "\n")
        self._stream.flush()
        self.count += 1
        return self.count

    def close(self):
        if self._stream is not None and not self._stream.closed:
            self._stream.flush()
            self._stream.close()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close()
        return False


def write_json(path, payload):
    """Write payload as indented JSON through a temporary file and os.replace."""
    path = Path(path)
    temporary = path.with_name(f"{path.name}.tmp-{os.getpid()}")
    try:
        with temporary.open("w", encoding="utf-8") as stream:
            json.dump(payload, stream, indent=2, ensure_ascii=False, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()
    return path


# MARK: - Command execution

def run_command(argv, timeout=DEFAULT_COMMAND_TIMEOUT):
    """Run a read-only command. Never raises; failures come back as an error string."""
    argv = [str(item) for item in argv]
    started = time.monotonic()
    try:
        completed = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return {"argv": argv, "duration_s": round(time.monotonic() - started, 6),
                "error": f"timeout after {timeout}s"}
    except (OSError, subprocess.SubprocessError) as error:
        return {"argv": argv, "duration_s": round(time.monotonic() - started, 6),
                "error": f"{type(error).__name__}: {error}"}
    result = {"argv": argv, "duration_s": round(time.monotonic() - started, 6),
              "returncode": completed.returncode, "stdout": completed.stdout,
              "stderr": completed.stderr}
    if completed.returncode != 0:
        result["error"] = f"exit {completed.returncode}: {completed.stderr.strip()[:200]}"
    return result


# MARK: - Output parsing

def parse_key_values(text, separator=":"):
    """Parse 'name: value' output such as sysctl (without -n) and sw_vers."""
    values = {}
    for line in (text or "").splitlines():
        if separator not in line:
            continue
        name, value = line.split(separator, 1)
        name = name.strip()
        if name:
            values[name] = value.strip()
    return values


def parse_swapusage(text):
    """Parse 'vm.swapusage: total = 7168.00M  used = 6037.00M  free = 1131.00M'."""
    record = {}
    for name, value in re.findall(r"(total|used|free)\s*=\s*([0-9.]+)M", text or ""):
        record[f"{name}_mib"] = float(value)
    return record


def parse_loadavg(text):
    """Parse 'vm.loadavg: { 2.54 2.07 1.51 }', also when other sysctl lines are present."""
    braces = re.search(r"\{([^}]*)\}", text or "")
    source = braces.group(1) if braces else (text or "")
    numbers = re.findall(r"[0-9]+(?:\.[0-9]+)?", source)
    if len(numbers) < 3:
        return {}
    return {"load_1m": float(numbers[0]), "load_5m": float(numbers[1]),
            "load_15m": float(numbers[2])}


def parse_df(text, mount=None):
    """Parse 'df -k' output into per-mount 1024-block counts."""
    rows = []
    for line in (text or "").splitlines()[1:]:
        fields = line.split()
        if len(fields) < 9:
            continue
        try:
            rows.append({"filesystem": fields[0], "total_kib": int(fields[1]),
                         "used_kib": int(fields[2]), "available_kib": int(fields[3]),
                         "capacity": fields[4], "mount": fields[-1]})
        except ValueError:
            continue
    if mount is None:
        return rows
    for row in rows:
        if row["mount"] == mount:
            return row
    return None


def parse_pmset_settings(text):
    """Parse the indented 'name<space>value' lines of 'pmset -g'."""
    settings = {}
    for line in (text or "").splitlines():
        if not line[:1].isspace():
            continue
        stripped = line.strip()
        if not stripped:
            continue
        parts = re.split(r"\s{2,}|\t+", stripped, maxsplit=1)
        if len(parts) == 2:
            name, value = parts
        else:
            name, _, value = stripped.rpartition(" ")
        if name.strip():
            settings[name.strip()] = value.strip()
    return settings


def parse_battery(text):
    """Extract the power source and charge percentage from 'pmset -g batt'."""
    record = {}
    source = re.search(r"drawing from '([^']+)'", text or "")
    if source:
        record["power_source"] = source.group(1)
    percent = re.search(r"(\d+)%", text or "")
    if percent:
        record["percent"] = int(percent.group(1))
    state = re.search(r"\d+%;\s*([^;]+);", text or "")
    if state:
        record["state"] = state.group(1).strip()
    return record


def command_entry(result, parser=None):
    """Turn a run_command result into an evidence entry with an optional parse."""
    entry = {"argv": result.get("argv"), "error": result.get("error")}
    stdout = result.get("stdout")
    if stdout is not None:
        entry["raw"] = stdout
    if parser is not None and stdout:
        try:
            entry["values"] = parser(stdout)
        except (ValueError, TypeError, IndexError) as error:
            entry["parse_error"] = f"{type(error).__name__}: {error}"
    return entry


def host_record(runner=None):
    """Host record required by plan §2.1; every item records its own failure."""
    run = runner or run_command
    record = {"collected_at": utc_now(), "platform": host_info(),
              "data_volume_mount": DATA_VOLUME}
    record["sysctl"] = command_entry(run([SYSCTL, *HOST_SYSCTL_KEYS]), parse_key_values)
    record["sw_vers"] = command_entry(run([SW_VERS]), parse_key_values)
    record["battery"] = command_entry(run([PMSET, "-g", "batt"]), parse_battery)
    record["power_settings"] = command_entry(run([PMSET, "-g"]), parse_pmset_settings)
    record["data_volume"] = command_entry(run([DF, "-k", DATA_VOLUME]),
                                           lambda text: parse_df(text, DATA_VOLUME) or {})
    record["swap"] = command_entry(run([SYSCTL, "vm.swapusage"]), parse_swapusage)
    return record
