#!/usr/bin/env python3
"""Read-only host sampler for the F3 performance baseline.

The sampler is a separate process so that it can start before the VM under test
(plan research/f3_performance_baseline_plan_2026-09-18.md §5). It never starts,
stops or configures a VM, never connects to a control socket and never writes
inside a VM bundle: it only runs read-only host commands and appends records to
its own output directory.

What is sampled (plan §3.3, §3.4, §3.7):

- every --interval seconds: `ps -o pid,rss,vsz,time,etime -p <pid>` for every
  tracked PID, and one `com.apple.Virtualization.VirtualMachine` PID scan;
- every --slow-interval seconds: `footprint -p <pid>` per tracked PID, merged
  into that PID's next process record, plus the host-wide `vm_stat`,
  `sysctl vm.swapusage vm.loadavg`, `memory_pressure -Q`, `pmset -g therm` and
  the sampler's own `ps` row;
- every --disk-interval seconds: `stat -f '%z %b'` for Disk.img, nvram.bin and
  SEPStorage of every --bundle;
- every --df-interval seconds: `df -k` for the host data volume;
- every --file-interval seconds: the size of every --file path (plan §3.7: the
  redirected vphone-cli stdout log, whose growth rate §3.6 estimates).

Plan §2.1 asks for `pmset -g therm` every 5 minutes. This sampler folds therm
into the slow host sample instead of giving it its own interval, so the default
--slow-interval of 60 seconds samples it more often than required and therm needs
no record kind of its own.

Output: `<out>/host_samples.jsonl` holds one flat record per measured entity per
tick, each with `kind` (process / host / disk / file / df / vz_scan), `t_wall`
(UTC ISO) and `t_mono` (time.monotonic()). A `process` record covers one PID and
carries `measurement` = "ps" or "ps+footprint"; a `disk` record covers one bundle
file; a `file` record covers one --file path and reports `present=False` while
the file does not exist.
`<out>/sampler.json` holds the parameters, start and end time, host_record(),
the VZ baseline PID set, the tracked PIDs, the per-kind record counts and the
failure counts.

CPU usage is not sampled directly: only the cumulative CPU time from `ps` is
recorded, and a later summary tool divides its difference by the wall-clock
difference. `ps %cpu` is a decayed average and is deliberately not used (§3.3).

VZ XPC attribution (§3.3): with --vz-baseline the PID set present at start is
recorded as the baseline; each scan lists the current PIDs, adds new ones to the
tracked set and records their `ps -o lstart` line. The sampler only records these
facts; the attribution decision belongs to the summary tool.

Testability: every external command goes through the module-global run_command()
(imported from f3_common) and host_record() is called with runner=run_command,
so a test can replace f3_host_sampler.run_command with a stub and drive main()
in process without executing footprint, memory_pressure or any other tool that
may be unavailable or slow.

Standard library only (plan §9 decision 9).
"""

import argparse
from collections import Counter
import os
from pathlib import Path
import re
import signal
import sys
import threading
import time

from f3_common import (
    DATA_VOLUME,
    DF,
    FOOTPRINT,
    MEMORY_PRESSURE,
    PMSET,
    PS,
    STAT,
    SYSCTL,
    VM_STAT,
    JsonlWriter,
    command_entry,
    create_output_directory,
    git_state,
    host_record,
    parse_df,
    parse_loadavg,
    parse_swapusage,
    redact_argv,
    run_command,
    utc_now,
    write_json,
)


SCHEMA_VERSION = 1
SCRIPT_NAME = "scripts/f3_host_sampler.py"
VZ_PROCESS_NAME = "com.apple.Virtualization.VirtualMachine"
BUNDLE_FILES = ("Disk.img", "nvram.bin", "SEPStorage")
PS_PROCESS_FORMAT = "pid,rss,vsz,time,etime"
RAW_PREFIX_CHARS = 400
MAX_SLEEP_SECONDS = 0.25
BYTE_UNITS = {"B": 1, "KB": 1 << 10, "MB": 1 << 20, "GB": 1 << 30, "TB": 1 << 40}


# MARK: - Output parsing

def parse_ps_time(value):
    """Parse a ps TIME/ELAPSED field into seconds.

    Accepted forms: 'SS', 'SS.ss', 'MM:SS.ss', 'HH:MM:SS' and 'DD-HH:MM:SS'.
    """
    text = (value or "").strip()
    if not text:
        raise ValueError("empty ps time field")
    days = 0
    if "-" in text:
        day_text, text = text.split("-", 1)
        days = int(day_text)
    parts = text.split(":")
    if len(parts) > 3:
        raise ValueError(f"unsupported ps time field: {value!r}")
    seconds = 0.0
    for part in parts:
        if not part:
            raise ValueError(f"unsupported ps time field: {value!r}")
        seconds = seconds * 60 + float(part)
    return days * 86400 + seconds


def parse_ps_table(text):
    """Parse `ps -o pid,rss,vsz,time,etime` output into one dict per data row.

    RSS and VSZ are reported in 1024-byte units and converted to bytes.
    """
    lines = [line for line in (text or "").splitlines() if line.strip()]
    if not lines:
        raise ValueError("empty ps output")
    header = lines[0].split()
    if "PID" not in header:
        raise ValueError(f"unexpected ps header: {lines[0]!r}")
    rows = []
    for line in lines[1:]:
        fields = line.split()
        if len(fields) != len(header):
            raise ValueError(f"unexpected ps row: {line!r}")
        columns = dict(zip(header, fields))
        row = {"pid": int(columns["PID"])}
        if "RSS" in columns:
            row["rss_bytes"] = int(columns["RSS"]) * 1024
        if "VSZ" in columns:
            row["vsz_bytes"] = int(columns["VSZ"]) * 1024
        if "TIME" in columns:
            row["cpu_seconds"] = parse_ps_time(columns["TIME"])
        if "ELAPSED" in columns:
            row["elapsed_seconds"] = parse_ps_time(columns["ELAPSED"])
        rows.append(row)
    return rows


def parse_ps_comm(text):
    """Parse `ps -axo pid=,comm=` rows into (pid, command path) pairs."""
    rows = []
    for line in (text or "").splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        pid_text, _, command = stripped.partition(" ")
        try:
            pid = int(pid_text)
        except ValueError:
            continue
        command = command.strip()
        if command:
            rows.append((pid, command))
    return rows


def virtualization_pids(text):
    """PIDs whose executable basename is the Virtualization XPC service."""
    return sorted(pid for pid, command in parse_ps_comm(text)
                  if os.path.basename(command) == VZ_PROCESS_NAME)


def _bytes_from(value, unit):
    multiplier = BYTE_UNITS.get(unit.upper())
    if multiplier is None:
        raise ValueError(f"unknown byte unit: {unit!r}")
    return int(round(float(value) * multiplier))


def parse_footprint(text):
    """Parse `footprint -p <pid>` output into total and peak footprint bytes.

    The 'Auxiliary data' phys_footprint value is the primary source; the header
    'Footprint: <n> <unit>' value is the fallback. Raises ValueError when neither
    is present so that the caller records the error and the raw output prefix.
    """
    record = {}
    total = re.search(r"phys_footprint:\s*([0-9.]+)\s*([KMGT]?B)\b", text or "")
    if total:
        record["footprint_bytes"] = _bytes_from(total.group(1), total.group(2))
    peak = re.search(r"phys_footprint_peak:\s*([0-9.]+)\s*([KMGT]?B)\b", text or "")
    if peak:
        record["peak_bytes"] = _bytes_from(peak.group(1), peak.group(2))
    header = re.search(r"\bFootprint:\s*([0-9.]+)\s*([KMGT]?B)\b", text or "")
    if header:
        record["header_footprint_bytes"] = _bytes_from(header.group(1), header.group(2))
        record.setdefault("footprint_bytes", record["header_footprint_bytes"])
    if "footprint_bytes" not in record:
        raise ValueError("no footprint value in output")
    return record


def parse_vm_stat(text):
    """Parse `vm_stat` output into the page size and the integer counters."""
    lines = (text or "").splitlines()
    if not lines:
        raise ValueError("empty vm_stat output")
    page_size = None
    match = re.search(r"page size of (\d+) bytes", lines[0])
    if match:
        page_size = int(match.group(1))
    counters = {}
    for line in lines[1:]:
        if ":" not in line:
            continue
        name, value = line.split(":", 1)
        value = value.strip().rstrip(".")
        if not value:
            continue
        key = re.sub(r"[^a-z0-9]+", "_", name.strip().lower()).strip("_")
        try:
            counters[key] = int(value)
        except ValueError:
            continue
    if not counters:
        raise ValueError("no vm_stat counters parsed")
    return {"page_size": page_size, "counters": counters}


def parse_stat_size(text):
    """Parse `stat -f '%z %b'` output: logical size and 512-byte block count."""
    fields = (text or "").split()
    if len(fields) < 2:
        raise ValueError(f"unexpected stat output: {text!r}")
    size = int(fields[0])
    blocks = int(fields[1])
    return {"size_bytes": size, "blocks": blocks, "allocated_bytes": blocks * 512}


def stat_file(path):
    """Size of an arbitrary file for plan §3.7.

    Uses os.stat instead of a subprocess so that a file that does not exist yet
    (the boot log before the VM is launched) is reported as present=False rather
    than as a command failure. Any other stat error is recorded in "error".
    """
    try:
        status = os.stat(path)
    except FileNotFoundError:
        return {"present": False}
    except OSError as error:
        return {"present": False, "error": f"{type(error).__name__}: {error}"}
    return {"present": True, "size_bytes": status.st_size, "blocks": status.st_blocks,
            "allocated_bytes": status.st_blocks * 512}


def _parsed_entry(result, parser, raw_key="raw_prefix"):
    """command_entry plus a parser whose failure is recorded, never raised."""
    entry = {"argv": result.get("argv"), "error": result.get("error")}
    stdout = result.get("stdout")
    if result.get("error") is None and stdout is not None:
        try:
            entry.update(parser(stdout))
        except (ValueError, TypeError, IndexError, KeyError) as error:
            entry["parse_error"] = f"{type(error).__name__}: {error}"
            entry[raw_key] = (stdout or "")[:RAW_PREFIX_CHARS]
    return entry


# MARK: - Sampler

class Sampler:
    def __init__(self, args, output, raw_argv):
        self.args = args
        self.output = Path(output)
        self.raw_argv = list(raw_argv)
        self.samples = JsonlWriter(self.output / "host_samples.jsonl")
        self.counts = Counter()
        self.failures = Counter()
        self.skipped = Counter()
        self.stop = threading.Event()
        self.stop_reason = None
        self.signal_name = None
        self.self_pid = os.getpid()
        self.tracked = {}
        self.vz_baseline = None
        self.vz_baseline_entry = None
        self._footprint_due = None
        self.started_at = None
        self.started_mono = None
        self.finished_at = None
        self.finished_mono = None
        for pid in args.pid:
            self.track(pid, source="argument")

    # Tracking ------------------------------------------------------------
    def track(self, pid, source, lstart=None, first_seen=None):
        if pid in self.tracked:
            return self.tracked[pid]
        entry = {
            "pid": pid,
            "label": self.args.label.get(pid, f"{source}:{pid}"),
            "source": source,
            "lstart": lstart,
            "first_seen_wall": (first_seen or {}).get("t_wall"),
            "first_seen_mono": (first_seen or {}).get("t_mono"),
            # §3.3: whether this pid's executable is the Virtualization XPC
            # service, decided by the scan below and not by how the pid reached
            # the sampler (--pid or the scan itself) nor by its label. None
            # until the first successful scan.
            "is_vz": True if source == "vz" else None,
            "gone": False,
        }
        self.tracked[pid] = entry
        return entry

    # Command execution ---------------------------------------------------
    def execute(self, argv, timeout=None, count_errors=True):
        result = run_command(argv, timeout=timeout) if timeout else run_command(argv)
        if count_errors and result.get("error"):
            self.failures[os.path.basename(str(argv[0]))] += 1
        return result

    def emit(self, record):
        self.counts[record["kind"]] += 1
        self.samples.write(record)
        return record

    @staticmethod
    def clock():
        return {"t_wall": utc_now(), "t_mono": round(time.monotonic(), 6)}

    # Samples -------------------------------------------------------------
    def sample_vz(self):
        clock = self.clock()
        record = dict(clock, kind="vz_scan", baseline_enabled=bool(self.args.vz_baseline),
                      baseline_pids=sorted(self.vz_baseline) if self.vz_baseline is not None else None)
        result = self.execute([PS, "-axo", "pid=,comm="])
        if result.get("error"):
            record["error"] = result["error"]
            record["pids"] = None
            return self.emit(record)
        pids = virtualization_pids(result.get("stdout"))
        record["error"] = None
        record["pids"] = pids
        # Mark every tracked pid, however it was supplied. A live pid does not
        # change executable, so the first scan that sees the pid settles the
        # answer; a later absence means the process exited, not that it was
        # something else.
        scanned = set(pids)
        for tracked_pid, entry in self.tracked.items():
            if entry["is_vz"] is None and not entry["gone"]:
                entry["is_vz"] = tracked_pid in scanned
        appeared = []
        for pid in pids:
            if pid in self.tracked:
                continue
            lstart = self.execute([PS, "-o", "lstart=", "-p", str(pid)], count_errors=False)
            entry = self.track(pid, source="vz", lstart=(lstart.get("stdout") or "").strip() or None,
                               first_seen=clock)
            appeared.append({
                "pid": pid,
                "label": entry["label"],
                "lstart": entry["lstart"],
                "lstart_error": lstart.get("error"),
                "in_baseline": bool(self.vz_baseline is not None and pid in self.vz_baseline),
            })
        record["new_pids"] = appeared
        record["absent_tracked_pids"] = sorted(
            pid for pid, entry in self.tracked.items()
            if entry["source"] == "vz" and pid not in pids)
        return self.emit(record)

    def footprint_due(self, now):
        """True when this process tick also carries the slower footprint measurement."""
        if self._footprint_due is None or now < self._footprint_due:
            return False
        self._footprint_due += self.args.slow_interval
        if self._footprint_due <= now:
            self.skipped["footprint"] += 1
            self._footprint_due = now + self.args.slow_interval
        return True

    def add_footprint(self, record, pid):
        """Merge `footprint -p <pid>` into a process record; failures are recorded."""
        result = self.execute([FOOTPRINT, "-p", str(pid)], count_errors=False)
        parsed = _parsed_entry(result, parse_footprint)
        record["measurement"] = "ps+footprint"
        if parsed.get("error"):
            record["footprint_error"] = parsed["error"]
            self.failures["footprint"] += 1
        elif parsed.get("parse_error"):
            record["footprint_parse_error"] = parsed["parse_error"]
            record["footprint_raw_prefix"] = parsed.get("raw_prefix")
            self.failures["footprint"] += 1
        else:
            record["footprint_bytes"] = parsed.get("footprint_bytes")
            record["peak_bytes"] = parsed.get("peak_bytes")

    def sample_processes(self):
        """One flat `process` record per tracked PID.

        Each record carries the `ps` measurement; on the first process tick at or
        after every --slow-interval it also carries the `footprint` measurement,
        so that a footprint value always has a cumulative CPU time beside it.
        """
        clock = self.clock()
        with_footprint = self.footprint_due(time.monotonic())
        for pid in sorted(self.tracked):
            info = self.tracked[pid]
            record = dict(clock, kind="process", measurement="ps", pid=pid,
                          label=info["label"], source=info["source"],
                          is_vz=info["is_vz"])
            if info["gone"]:
                record["present"] = False
                record["gone"] = True
                self.emit(record)
                continue
            result = self.execute([PS, "-o", PS_PROCESS_FORMAT, "-p", str(pid)],
                                  count_errors=False)
            if result.get("error") and result.get("returncode") != 1:
                record["present"] = None
                record["error"] = result["error"]
                self.failures["ps"] += 1
                self.emit(record)
                continue
            try:
                rows = parse_ps_table(result.get("stdout"))
            except (ValueError, KeyError) as error:
                if result.get("returncode") == 1:
                    record["present"] = False
                    info["gone"] = True
                else:
                    record["present"] = None
                    record["parse_error"] = f"{type(error).__name__}: {error}"
                    record["raw_prefix"] = (result.get("stdout") or "")[:RAW_PREFIX_CHARS]
                    self.failures["ps"] += 1
                self.emit(record)
                continue
            if not rows:
                record["present"] = False
                info["gone"] = True
            else:
                record["present"] = True
                record.update(rows[0])
                record["pid"] = pid
                if with_footprint:
                    self.add_footprint(record, pid)
            self.emit(record)

    def sample_host(self):
        clock = self.clock()
        record = dict(clock, kind="host", label="host")
        record["vm_stat"] = _parsed_entry(self.execute([VM_STAT]), parse_vm_stat)
        record["swap_load"] = _parsed_entry(
            self.execute([SYSCTL, "vm.swapusage", "vm.loadavg"]),
            lambda text: {"swap": parse_swapusage(text), "loadavg": parse_loadavg(text)})
        record["memory_pressure"] = command_entry(self.execute([MEMORY_PRESSURE, "-Q"]))
        record["therm"] = command_entry(self.execute([PMSET, "-g", "therm"]))
        record["sampler"] = _parsed_entry(
            self.execute([PS, "-o", PS_PROCESS_FORMAT, "-p", str(self.self_pid)]),
            lambda text: (parse_ps_table(text) or [{}])[0])
        counters = record["vm_stat"].get("counters") or {}
        page_size = record["vm_stat"].get("page_size")
        for name in ("swapins", "swapouts"):
            if name in counters:
                record[name] = counters[name]
        if page_size and "pages_free" in counters:
            record["pages_free_bytes"] = counters["pages_free"] * page_size
        swap = record["swap_load"].get("swap") or {}
        if "used_mib" in swap:
            record["swap_used_bytes"] = int(round(swap["used_mib"] * (1 << 20)))
        loadavg = record["swap_load"].get("loadavg") or {}
        if "load_1m" in loadavg:
            record["load_average_1m"] = loadavg["load_1m"]
        return self.emit(record)

    def sample_disk(self):
        """One flat `disk` record per bundle file (plan §3.4)."""
        clock = self.clock()
        for bundle in self.args.bundle:
            for name in BUNDLE_FILES:
                path = bundle / name
                record = dict(clock, kind="disk", bundle=str(bundle), file=name, path=str(path),
                              label=f"{bundle.name}/{name}")
                record.update(_parsed_entry(
                    self.execute([STAT, "-f", "%z %b", str(path)], count_errors=False),
                    parse_stat_size))
                if record.get("parse_error"):
                    self.failures["stat"] += 1
                self.emit(record)

    def sample_files(self):
        """One flat `file` record per --file path (plan §3.7 log growth)."""
        clock = self.clock()
        for path in self.args.file:
            record = dict(clock, kind="file", path=str(path),
                          label=self.args.file_label.get(str(path), path.name))
            result = stat_file(path)
            if result.get("error"):
                self.failures["stat_file"] += 1
            record.update(result)
            self.emit(record)

    def sample_df(self):
        clock = self.clock()
        record = dict(clock, kind="df", mount=DATA_VOLUME, label=DATA_VOLUME)
        record.update(_parsed_entry(self.execute([DF, "-k", DATA_VOLUME]),
                                    lambda text: parse_df(text, DATA_VOLUME) or {}))
        for key in ("total", "used", "available"):
            value = record.get(f"{key}_kib")
            if isinstance(value, int):
                record[f"{key}_bytes"] = value * 1024
        return self.emit(record)

    # Lifecycle -----------------------------------------------------------
    def install_signal_handlers(self):
        def handler(signum, _frame):
            self.signal_name = signal.Signals(signum).name
            self.stop_reason = "signal"
            self.stop.set()

        for number in (signal.SIGINT, signal.SIGTERM):
            try:
                signal.signal(number, handler)
            except ValueError:
                pass

    def collect_vz_baseline(self):
        if not self.args.vz_baseline:
            return
        result = self.execute([PS, "-axo", "pid=,comm="])
        entry = {"collected_at": utc_now(), "error": result.get("error")}
        if result.get("error"):
            entry["pids"] = None
        else:
            self.vz_baseline = set(virtualization_pids(result.get("stdout")))
            entry["pids"] = sorted(self.vz_baseline)
        self.vz_baseline_entry = entry

    def tasks(self):
        tasks = [("process", self.args.interval, self._process_tick),
                 ("host", self.args.slow_interval, self.sample_host),
                 ("df", self.args.df_interval, self.sample_df)]
        if self.args.bundle:
            tasks.insert(2, ("disk", self.args.disk_interval, self.sample_disk))
        if self.args.file:
            tasks.insert(2, ("file", self.args.file_interval, self.sample_files))
        return tasks

    def _process_tick(self):
        self.sample_vz()
        self.sample_processes()

    def run(self):
        self.install_signal_handlers()
        self.started_at = utc_now()
        self.started_mono = time.monotonic()
        self._footprint_due = self.started_mono
        self.host_start = host_record(runner=run_command)
        self.collect_vz_baseline()
        tasks = self.tasks()
        due = {name: self.started_mono for name, _interval, _action in tasks}
        deadline = None if self.args.duration is None else self.started_mono + self.args.duration
        try:
            while not self.stop.is_set():
                now = time.monotonic()
                if deadline is not None and now >= deadline:
                    self.stop_reason = "duration"
                    break
                for name, interval, action in tasks:
                    if self.stop.is_set():
                        break
                    if now < due[name]:
                        continue
                    action()
                    due[name] += interval
                    if due[name] <= now:
                        self.skipped[name] += 1
                        due[name] = time.monotonic() + interval
                if self.stop.is_set():
                    break
                now = time.monotonic()
                wake = min(due.values())
                if deadline is not None:
                    wake = min(wake, deadline)
                self.stop.wait(max(0.0, min(wake - now, MAX_SLEEP_SECONDS)))
        finally:
            self.finish()
        return 0

    def finish(self):
        if self.stop_reason is None:
            self.stop_reason = "signal" if self.stop.is_set() else "stopped"
        self.finished_mono = time.monotonic()
        self.finished_at = utc_now()
        self.samples.close()
        commit, clean = git_state()
        payload = {
            "schema_version": SCHEMA_VERSION,
            "script": SCRIPT_NAME,
            "invocation": {"argv": redact_argv(self.raw_argv)},
            "parameters": {
                "out": str(self.output),
                "interval": self.args.interval,
                "slow_interval": self.args.slow_interval,
                "disk_interval": self.args.disk_interval,
                "file_interval": self.args.file_interval,
                "df_interval": self.args.df_interval,
                "duration": self.args.duration,
                "pids": list(self.args.pid),
                "labels": {str(pid): name for pid, name in sorted(self.args.label.items())},
                "bundles": [str(path) for path in self.args.bundle],
                "files": [str(path) for path in self.args.file],
                "file_labels": dict(sorted(self.args.file_label.items())),
                "vz_baseline": bool(self.args.vz_baseline),
            },
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "started_mono": round(self.started_mono, 6) if self.started_mono else None,
            "finished_mono": round(self.finished_mono, 6),
            "elapsed_s": (round(self.finished_mono - self.started_mono, 6)
                          if self.started_mono else None),
            "stop_reason": self.stop_reason,
            "signal": self.signal_name,
            "host": getattr(self, "host_start", None),
            "host_end": host_record(runner=run_command),
            "git": {"commit": commit, "worktree_clean": clean},
            "vz_baseline": self.vz_baseline_entry or {"enabled": False},
            "tracked": [self.tracked[pid] for pid in sorted(self.tracked)],
            "samples_file": "host_samples.jsonl",
            "sample_counts": dict(sorted(self.counts.items())),
            "sample_lines": self.samples.count,
            "skipped_ticks": dict(sorted(self.skipped.items())),
            "failures": {"total": sum(self.failures.values()),
                         "by_command": dict(sorted(self.failures.items()))},
        }
        write_json(self.output / "sampler.json", payload)
        return payload


# MARK: - Command line

def positive_float(value):
    try:
        number = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError(str(error)) from error
    if number <= 0:
        raise argparse.ArgumentTypeError("must be greater than 0")
    return number


def positive_int(value):
    try:
        number = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError(str(error)) from error
    if number <= 0:
        raise argparse.ArgumentTypeError("must be greater than 0")
    return number


def parse_label(value):
    pid_text, separator, name = value.partition("=")
    name = name.strip()
    if not separator or not name:
        raise argparse.ArgumentTypeError("expected <pid>=<name>")
    try:
        pid = int(pid_text)
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"invalid pid {pid_text!r}") from error
    return pid, name


def parse_file_label(value):
    path_text, separator, name = value.partition("=")
    name = name.strip()
    if not separator or not name or not path_text:
        raise argparse.ArgumentTypeError("expected <path>=<name>")
    return str(Path(path_text).expanduser()), name


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, required=True,
                        help="new output directory (must not exist)")
    parser.add_argument("--interval", type=positive_float, default=5.0,
                        help="process sampling period in seconds (default 5)")
    parser.add_argument("--slow-interval", type=positive_float, default=60.0,
                        help="footprint/vm_stat/therm sampling period in seconds (default 60)")
    parser.add_argument("--disk-interval", type=positive_float, default=60.0,
                        help="bundle stat sampling period in seconds (default 60)")
    parser.add_argument("--df-interval", type=positive_float, default=300.0,
                        help="df -k sampling period in seconds (default 300)")
    parser.add_argument("--file-interval", type=positive_float, default=60.0,
                        help="file size sampling period in seconds (default 60)")
    parser.add_argument("--duration", type=positive_float,
                        help="stop after this many seconds (default: run until SIGINT/SIGTERM)")
    parser.add_argument("--pid", type=positive_int, action="append", default=[],
                        help="process to sample; repeatable")
    parser.add_argument("--label", type=parse_label, action="append", default=[],
                        help="<pid>=<name> label recorded with the samples; repeatable")
    parser.add_argument("--bundle", type=Path, action="append", default=[],
                        help="VM bundle directory sampled with stat; repeatable, read-only")
    parser.add_argument("--file", type=Path, action="append", default=[],
                        help="file whose size is sampled, e.g. the redirected boot log; "
                             "repeatable, read-only")
    parser.add_argument("--file-label", type=parse_file_label, action="append", default=[],
                        help="<path>=<name> label for a --file path (default: its basename); "
                             "repeatable")
    parser.add_argument("--vz-baseline", action="store_true",
                        help=f"record the {VZ_PROCESS_NAME} PID set present at start")
    args = parser.parse_args(argv)
    args.pid = sorted(dict.fromkeys(args.pid))
    args.label = dict(args.label)
    args.bundle = [path.expanduser() for path in args.bundle]
    args.file = list(dict.fromkeys(path.expanduser() for path in args.file))
    args.file_label = dict(args.file_label)
    return args


def main(argv=None):
    raw_argv = list(sys.argv[1:] if argv is None else argv)
    args = parse_args(raw_argv)
    try:
        output = create_output_directory(args.out)
    except (ValueError, OSError) as error:
        print(f"{error}", file=sys.stderr)
        return 2
    sampler = Sampler(args, output, raw_argv)
    sampler.run()
    print(f"host_samples.jsonl: {output / 'host_samples.jsonl'} ({sampler.samples.count} lines)")
    print(f"sampler.json: {output / 'sampler.json'} (stop_reason={sampler.stop_reason})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
