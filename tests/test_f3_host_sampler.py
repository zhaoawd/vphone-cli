"""Offline tests for scripts/f3_common.py and scripts/f3_host_sampler.py.

No VM is started and no control socket is opened. Testability approach: the
sampler routes every external command through the module-global
f3_host_sampler.run_command, and calls f3_common.host_record(runner=run_command),
so replacing f3_host_sampler.run_command with a stub covers every host command.
No test executes footprint, memory_pressure, pmset, vm_stat or stat. The SIGTERM
test runs a driver in a subprocess that installs the same stub before calling
main(), because a real signal needs a real process.
"""

import contextlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))

import f3_common  # noqa: E402
import f3_host_sampler as sampler  # noqa: E402


PS_ROW = """  PID    RSS      VSZ      TIME ELAPSED
41303 344064 435308096   03:06.12   02:15:33
"""
PS_HEADER_ONLY = "  PID    RSS      VSZ      TIME ELAPSED\n"
PS_COMM = (
    "1 /sbin/launchd\n"
    "41303 /Users/kolar/github/vphone-cli/.build/vphone-cli.app/Contents/MacOS/vphone-cli\n"
    "41311 /System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/"
    "com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/"
    "com.apple.Virtualization.VirtualMachine\n"
)
PS_COMM_EXTRA = PS_COMM + (
    "52000 /System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/"
    "com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/"
    "com.apple.Virtualization.VirtualMachine\n"
)
FOOTPRINT_OUT = """======================================================================
vphone-cli [41303]: 64-bit    Footprint: 337 MB (16384 bytes per page)
======================================================================

  Dirty      Clean  Reclaimable    Regions    Category
 448 KB        0 B          0 B          5    MALLOC_SMALL
    ---        ---          ---        ---    ---
 337 MB     560 KB          0 B        410    TOTAL

Auxiliary data:
    phys_footprint: 337 MB
    phys_footprint_peak: 402 MB
"""
VM_STAT_OUT = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                                   167136.
Pages active:                                1174021.
Pages inactive:                              1162171.
Pages wired down:                             240519.
Swapins:                                     3283251.
Swapouts:                                    3593217.
"""
SWAP_LOAD_OUT = ("vm.swapusage: total = 7168.00M  used = 6037.00M  free = 1131.00M  (encrypted)\n"
                 "vm.loadavg: { 2.54 2.07 1.51 }\n")
DF_OUT = ("Filesystem     1024-blocks      Used Available Capacity iused      ifree %iused  "
          "Mounted on\n"
          "/dev/disk3s5     971298980 727174560 210976484    78% 4316055 2109764840    0%   "
          "/System/Volumes/Data\n")
SYSCTL_HOST_OUT = ("hw.model: Mac17,9\n"
                   "hw.memsize: 51539607552\n"
                   "hw.ncpu: 15\n"
                   "hw.perflevel0.physicalcpu: 5\n"
                   "hw.perflevel1.physicalcpu: 10\n")
SW_VERS_OUT = "ProductName:\tmacOS\nProductVersion:\t26.5\nBuildVersion:\t25F71\n"
BATT_OUT = ("Now drawing from 'AC Power'\n"
            " -InternalBattery-0 (id=123)\t38%; charging; 2:11 remaining present: true\n")
PMSET_OUT = ("System-wide power settings:\n"
             " SleepDisabled\t\t\t0\n"
             "Currently in use:\n"
             " Sleep On Power Button 1\n"
             " displaysleep         120\n"
             " sleep                1 (sleep prevented by powerd, vphone-cli, caffeinate)\n")
THERM_OUT = "Note: No thermal warning level has been recorded\n"
STAT_OUT = "68719476736 42473888\n"


class CommandStub:
    """Stand-in for f3_common.run_command; answers every command the sampler runs."""

    def __init__(self, ps_comm=PS_COMM, footprint_broken=False, dead_pids=()):
        self.ps_comm = [ps_comm] if isinstance(ps_comm, str) else list(ps_comm)
        self.footprint_broken = footprint_broken
        self.dead_pids = {int(pid) for pid in dead_pids}
        self.calls = []

    def _listing(self):
        index = min(len([call for call in self.calls
                         if call[:3] == [f3_common.PS, "-axo", "pid=,comm="]]) - 1,
                    len(self.ps_comm) - 1)
        return self.ps_comm[max(index, 0)]

    def __call__(self, argv, timeout=None):
        argv = [str(item) for item in argv]
        self.calls.append(argv)
        stdout, returncode = self._answer(argv)
        result = {"argv": argv, "duration_s": 0.0, "returncode": returncode,
                  "stdout": stdout, "stderr": ""}
        if returncode != 0:
            result["error"] = f"exit {returncode}: "
        return result

    def _answer(self, argv):
        tool = argv[0]
        if tool == f3_common.PS:
            if argv[1] == "-axo":
                return self._listing(), 0
            pid = int(argv[-1])
            if argv[2] == "lstart=":
                return "Wed Sep 17 21:29:03 2026\n", 0
            if pid in self.dead_pids:
                return PS_HEADER_ONLY, 1
            return PS_ROW.replace("41303", str(pid), 1), 0
        if tool == f3_common.FOOTPRINT:
            return ("unexpected output\n", 0) if self.footprint_broken else (FOOTPRINT_OUT, 0)
        if tool == f3_common.VM_STAT:
            return VM_STAT_OUT, 0
        if tool == f3_common.MEMORY_PRESSURE:
            return "System-wide memory free percentage: 41%\n", 0
        if tool == f3_common.STAT:
            return STAT_OUT, 0
        if tool == f3_common.DF:
            return DF_OUT, 0
        if tool == f3_common.SW_VERS:
            return SW_VERS_OUT, 0
        if tool == f3_common.PMSET:
            if argv[-1] == "therm":
                return THERM_OUT, 0
            if argv[-1] == "batt":
                return BATT_OUT, 0
            return PMSET_OUT, 0
        if tool == f3_common.SYSCTL:
            if "vm.swapusage" in argv and "vm.loadavg" in argv:
                return SWAP_LOAD_OUT, 0
            if "vm.swapusage" in argv:
                return SWAP_LOAD_OUT.splitlines()[0] + "\n", 0
            return SYSCTL_HOST_OUT, 0
        return "", 127


class TemporaryDirectoryCase(unittest.TestCase):
    def setUp(self):
        self._temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self._temporary.cleanup)
        self.directory = Path(self._temporary.name)


# MARK: - Output primitives

class OutputDirectoryTests(TemporaryDirectoryCase):
    def test_creates_directory_with_parents(self):
        created = f3_common.create_output_directory(self.directory / "a/b/out")
        self.assertTrue(created.is_dir())
        self.assertEqual(created, (self.directory / "a/b/out").resolve())

    def test_existing_directory_raises_value_error(self):
        existing = self.directory / "out"
        existing.mkdir()
        with self.assertRaises(ValueError):
            f3_common.create_output_directory(existing)

    def test_existing_file_raises_value_error(self):
        existing = self.directory / "out"
        existing.write_text("x")
        with self.assertRaises(ValueError):
            f3_common.create_output_directory(existing)


class JsonlWriterTests(TemporaryDirectoryCase):
    def test_writes_one_compact_line_per_record_and_flushes(self):
        path = self.directory / "samples.jsonl"
        writer = f3_common.JsonlWriter(path)
        self.addCleanup(writer.close)
        writer.write({"kind": "process", "note": "中文", "pid": 1})
        # Readable before close: every record is flushed immediately.
        first = path.read_text().splitlines()
        self.assertEqual(len(first), 1)
        self.assertEqual(first[0], '{"kind":"process","note":"中文","pid":1}')
        writer.write({"kind": "host"})
        self.assertEqual(writer.count, 2)
        lines = path.read_text().splitlines()
        self.assertEqual([json.loads(line)["kind"] for line in lines], ["process", "host"])

    def test_context_manager_closes_stream(self):
        path = self.directory / "samples.jsonl"
        with f3_common.JsonlWriter(path) as writer:
            writer.write({"kind": "df"})
        self.assertEqual(json.loads(path.read_text())["kind"], "df")
        writer.close()  # close is idempotent


class WriteJsonTests(TemporaryDirectoryCase):
    def test_writes_indented_utf8_json_without_leaving_temporary_files(self):
        path = self.directory / "sampler.json"
        f3_common.write_json(path, {"note": "中文", "n": 1})
        text = path.read_text(encoding="utf-8")
        self.assertIn('"note": "中文"', text)
        self.assertIn('\n  "n": 1', text)
        self.assertEqual(json.loads(text), {"note": "中文", "n": 1})
        self.assertEqual(sorted(item.name for item in self.directory.iterdir()), ["sampler.json"])

    def test_replace_failure_keeps_previous_content_and_removes_temporary(self):
        path = self.directory / "sampler.json"
        f3_common.write_json(path, {"generation": 1})
        with mock.patch("f3_common.os.replace", side_effect=OSError("boom")):
            with self.assertRaises(OSError):
                f3_common.write_json(path, {"generation": 2})
        self.assertEqual(json.loads(path.read_text()), {"generation": 1})
        self.assertEqual(sorted(item.name for item in self.directory.iterdir()), ["sampler.json"])


# MARK: - Parsing

class ParserTests(unittest.TestCase):
    def test_ps_time_accepts_both_documented_formats(self):
        self.assertAlmostEqual(sampler.parse_ps_time("03:06.12"), 186.12)
        self.assertAlmostEqual(sampler.parse_ps_time("02:15:33"), 8133.0)
        self.assertAlmostEqual(sampler.parse_ps_time("0:00.00"), 0.0)
        self.assertAlmostEqual(sampler.parse_ps_time("2-01:00:00"), 176400.0)

    def test_ps_time_rejects_unparsable_values(self):
        for value in ("", "  ", "1:2:3:4", "abc"):
            with self.assertRaises(ValueError):
                sampler.parse_ps_time(value)

    def test_ps_table_converts_kib_columns_to_bytes(self):
        rows = sampler.parse_ps_table(PS_ROW)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["pid"], 41303)
        self.assertEqual(rows[0]["rss_bytes"], 344064 * 1024)
        self.assertEqual(rows[0]["vsz_bytes"], 435308096 * 1024)
        self.assertAlmostEqual(rows[0]["cpu_seconds"], 186.12)
        self.assertAlmostEqual(rows[0]["elapsed_seconds"], 8133.0)

    def test_ps_table_header_only_output_has_no_rows(self):
        self.assertEqual(sampler.parse_ps_table(PS_HEADER_ONLY), [])
        with self.assertRaises(ValueError):
            sampler.parse_ps_table("")

    def test_footprint_prefers_phys_footprint_and_keeps_peak(self):
        parsed = sampler.parse_footprint(FOOTPRINT_OUT)
        self.assertEqual(parsed["footprint_bytes"], 337 * (1 << 20))
        self.assertEqual(parsed["peak_bytes"], 402 * (1 << 20))
        self.assertEqual(parsed["header_footprint_bytes"], 337 * (1 << 20))

    def test_footprint_falls_back_to_header_value(self):
        header_only = "vphone-cli [1]: 64-bit    Footprint: 8341 MB (16384 bytes per page)\n"
        self.assertEqual(sampler.parse_footprint(header_only)["footprint_bytes"],
                         8341 * (1 << 20))

    def test_footprint_without_value_raises_value_error(self):
        with self.assertRaises(ValueError):
            sampler.parse_footprint("footprint: unable to attach to pid 41311\n")

    def test_vm_stat_returns_page_size_and_counters(self):
        parsed = sampler.parse_vm_stat(VM_STAT_OUT)
        self.assertEqual(parsed["page_size"], 16384)
        self.assertEqual(parsed["counters"]["pages_free"], 167136)
        self.assertEqual(parsed["counters"]["pages_wired_down"], 240519)
        self.assertEqual(parsed["counters"]["swapouts"], 3593217)
        with self.assertRaises(ValueError):
            sampler.parse_vm_stat("")

    def test_stat_size_uses_512_byte_blocks(self):
        self.assertEqual(sampler.parse_stat_size(STAT_OUT),
                         {"size_bytes": 68719476736, "blocks": 42473888,
                          "allocated_bytes": 42473888 * 512})
        with self.assertRaises(ValueError):
            sampler.parse_stat_size("68719476736\n")

    def test_virtualization_pids_match_executable_basename(self):
        self.assertEqual(sampler.virtualization_pids(PS_COMM), [41311])
        self.assertEqual(sampler.virtualization_pids(PS_COMM_EXTRA), [41311, 52000])
        self.assertEqual(sampler.virtualization_pids(""), [])

    def test_common_parsers(self):
        self.assertEqual(f3_common.parse_key_values(SYSCTL_HOST_OUT)["hw.model"], "Mac17,9")
        self.assertEqual(f3_common.parse_key_values(SW_VERS_OUT)["BuildVersion"], "25F71")
        self.assertEqual(f3_common.parse_swapusage(SWAP_LOAD_OUT),
                         {"total_mib": 7168.0, "used_mib": 6037.0, "free_mib": 1131.0})
        self.assertEqual(f3_common.parse_loadavg(SWAP_LOAD_OUT),
                         {"load_1m": 2.54, "load_5m": 2.07, "load_15m": 1.51})
        self.assertEqual(f3_common.parse_loadavg("vm.loadavg: { 0.10 0.20 0.30 }")["load_15m"],
                         0.30)
        self.assertEqual(f3_common.parse_loadavg("nothing"), {})
        volume = f3_common.parse_df(DF_OUT, "/System/Volumes/Data")
        self.assertEqual(volume["available_kib"], 210976484)
        self.assertIsNone(f3_common.parse_df(DF_OUT, "/nowhere"))
        settings = f3_common.parse_pmset_settings(PMSET_OUT)
        self.assertEqual(settings["SleepDisabled"], "0")
        self.assertEqual(settings["Sleep On Power Button"], "1")
        self.assertEqual(settings["displaysleep"], "120")
        self.assertEqual(settings["sleep"],
                         "1 (sleep prevented by powerd, vphone-cli, caffeinate)")
        battery = f3_common.parse_battery(BATT_OUT)
        self.assertEqual(battery["power_source"], "AC Power")
        self.assertEqual(battery["percent"], 38)

    def test_host_record_uses_injected_runner_and_records_failures(self):
        record = f3_common.host_record(runner=CommandStub())
        self.assertEqual(record["sysctl"]["values"]["hw.memsize"], "51539607552")
        self.assertEqual(record["sw_vers"]["values"]["ProductVersion"], "26.5")
        self.assertEqual(record["data_volume"]["values"]["available_kib"], 210976484)
        self.assertEqual(record["swap"]["values"]["used_mib"], 6037.0)
        self.assertEqual(record["power_settings"]["values"]["displaysleep"], "120")
        self.assertIsNone(record["battery"]["error"])

        def failing(argv, timeout=None):
            return {"argv": [str(item) for item in argv], "error": "FileNotFoundError: missing"}

        broken = f3_common.host_record(runner=failing)
        self.assertEqual(broken["sysctl"]["error"], "FileNotFoundError: missing")
        self.assertNotIn("values", broken["sw_vers"])


# MARK: - Sampler runs

def read_samples(output):
    return [json.loads(line) for line in
            (output / "host_samples.jsonl").read_text().splitlines() if line.strip()]


class SamplerRunTests(TemporaryDirectoryCase):
    def run_sampler(self, stub, extra_argv=(), duration="0.4"):
        output = self.directory / "out"
        argv = ["--out", str(output), "--interval", "0.05", "--slow-interval", "0.1",
                "--disk-interval", "0.1", "--df-interval", "0.1", "--file-interval", "0.05",
                "--duration", duration, *extra_argv]
        with mock.patch.object(sampler, "run_command", stub):
            with contextlib.redirect_stdout(io.StringIO()):
                code = sampler.main(argv)
        self.assertEqual(code, 0)
        return output, read_samples(output), json.loads((output / "sampler.json").read_text())

    def test_duration_run_writes_all_record_kinds_and_sampler_json(self):
        stub = CommandStub()
        bundle = self.directory / "bundle"
        bundle.mkdir()
        output, samples, report = self.run_sampler(
            stub, ["--pid", "41303", "--label", "41303=vphone-cli",
                   "--bundle", str(bundle), "--vz-baseline"])

        kinds = {record["kind"] for record in samples}
        self.assertEqual(kinds, {"process", "host", "disk", "df", "vz_scan"})
        self.assertNotIn("file", kinds)  # no --file: the task is not scheduled
        for record in samples:
            self.assertIn("t_wall", record)
            self.assertIsInstance(record["t_mono"], float)

        # Flat records: one line per measured entity, consumable by the summary tool.
        entry = next(record for record in samples
                     if record["kind"] == "process" and record["pid"] == 41303
                     and record["measurement"] == "ps")
        self.assertEqual(entry["label"], "vphone-cli")
        self.assertTrue(entry["present"])
        self.assertAlmostEqual(entry["cpu_seconds"], 186.12)
        self.assertEqual(entry["rss_bytes"], 344064 * 1024)
        self.assertNotIn("pcpu", entry)

        footprint = next(record for record in samples
                         if record["kind"] == "process" and record["pid"] == 41303
                         and record["measurement"] == "ps+footprint")
        self.assertEqual(footprint["footprint_bytes"], 337 * (1 << 20))
        self.assertEqual(footprint["peak_bytes"], 402 * (1 << 20))
        self.assertEqual(footprint["label"], "vphone-cli")
        # The footprint measurement always rides on a record that also has ps fields.
        self.assertAlmostEqual(footprint["cpu_seconds"], 186.12)

        host = next(record for record in samples if record["kind"] == "host")
        self.assertEqual(host["vm_stat"]["counters"]["pages_free"], 167136)
        self.assertEqual(host["swap_load"]["swap"]["used_mib"], 6037.0)
        self.assertEqual(host["swapins"], 3283251)
        self.assertEqual(host["swapouts"], 3593217)
        self.assertEqual(host["swap_used_bytes"], 6037 * (1 << 20))
        self.assertEqual(host["load_average_1m"], 2.54)
        self.assertIn("memory free percentage", host["memory_pressure"]["raw"])
        self.assertIn("thermal warning", host["therm"]["raw"])
        self.assertEqual(host["sampler"]["pid"], os.getpid())

        disks = [record for record in samples if record["kind"] == "disk"]
        self.assertEqual([record["file"] for record in disks[:3]],
                         ["Disk.img", "nvram.bin", "SEPStorage"])
        self.assertEqual(disks[0]["label"], "bundle/Disk.img")
        self.assertEqual(disks[0]["blocks"], 42473888)
        self.assertEqual(disks[0]["allocated_bytes"], 42473888 * 512)

        df = next(record for record in samples if record["kind"] == "df")
        self.assertEqual(df["available_kib"], 210976484)
        self.assertEqual(df["available_bytes"], 210976484 * 1024)
        self.assertEqual(df["label"], "/System/Volumes/Data")

        self.assertEqual(report["schema_version"], sampler.SCHEMA_VERSION)
        self.assertEqual(report["script"], "scripts/f3_host_sampler.py")
        self.assertEqual(report["stop_reason"], "duration")
        self.assertIsNone(report["signal"])
        self.assertEqual(report["parameters"]["pids"], [41303])
        self.assertEqual(report["parameters"]["labels"], {"41303": "vphone-cli"})
        self.assertEqual(report["parameters"]["bundles"], [str(bundle)])
        self.assertTrue(report["parameters"]["vz_baseline"])
        self.assertEqual(report["vz_baseline"]["pids"], [41311])
        self.assertEqual(report["host"]["sysctl"]["values"]["hw.model"], "Mac17,9")
        self.assertIn("host_end", report)
        self.assertEqual(report["sample_lines"], len(samples))
        self.assertEqual(sum(report["sample_counts"].values()), len(samples))
        self.assertEqual(report["failures"]["total"], 0)
        self.assertEqual({item["pid"] for item in report["tracked"]}, {41303, 41311})

        # Nothing is written inside the sampled bundle.
        self.assertEqual(list(bundle.iterdir()), [])
        self.assertEqual(sorted(item.name for item in output.iterdir()),
                         ["host_samples.jsonl", "sampler.json"])

    def test_existing_file_size_is_sampled_with_default_and_custom_label(self):
        boot_log = self.directory / "boot.log"
        boot_log.write_bytes(b"x" * 4096)
        other = self.directory / "vphone-vcam.log"
        other.write_bytes(b"y" * 10)
        _output, samples, report = self.run_sampler(
            CommandStub(), ["--file", str(boot_log), "--file", str(other),
                            "--file-label", f"{other}=vcam"])
        files = [record for record in samples if record["kind"] == "file"]
        self.assertTrue(files)
        first = next(record for record in files if record["path"] == str(boot_log))
        self.assertEqual(first["label"], "boot.log")
        self.assertTrue(first["present"])
        self.assertEqual(first["size_bytes"], 4096)
        self.assertEqual(first["allocated_bytes"], first["blocks"] * 512)
        self.assertNotIn("error", first)
        labelled = next(record for record in files if record["path"] == str(other))
        self.assertEqual(labelled["label"], "vcam")
        self.assertEqual(labelled["size_bytes"], 10)
        self.assertEqual(report["parameters"]["file_interval"], 0.05)
        self.assertEqual(report["parameters"]["files"], [str(boot_log), str(other)])
        self.assertEqual(report["parameters"]["file_labels"], {str(other): "vcam"})
        self.assertEqual(report["sample_counts"]["file"], len(files))
        self.assertEqual(sum(report["sample_counts"].values()), report["sample_lines"])

    def test_missing_file_is_not_present_and_not_a_failure(self):
        missing = self.directory / "boot.log"
        _output, samples, report = self.run_sampler(CommandStub(), ["--file", str(missing)])
        files = [record for record in samples if record["kind"] == "file"]
        self.assertTrue(files)
        for record in files:
            self.assertFalse(record["present"])
            self.assertNotIn("size_bytes", record)
            self.assertNotIn("error", record)
        self.assertEqual(report["failures"]["total"], 0)

    def test_file_appearing_during_the_run_is_sampled_from_then_on(self):
        boot_log = self.directory / "boot.log"
        timer = threading.Timer(0.2, lambda: boot_log.write_bytes(b"z" * 128))
        timer.start()
        self.addCleanup(timer.cancel)
        _output, samples, _report = self.run_sampler(
            CommandStub(), ["--file", str(boot_log)], duration="0.6")
        files = [record for record in samples if record["kind"] == "file"]
        self.assertFalse(files[0]["present"])
        self.assertTrue(files[-1]["present"], msg=f"{files[-1]}")
        self.assertEqual(files[-1]["size_bytes"], 128)

    def test_new_virtualization_pid_is_tracked_with_lstart(self):
        # First listing: --vz-baseline. Second: first scan. Third onwards: the new PID.
        stub = CommandStub(ps_comm=[PS_COMM, PS_COMM, PS_COMM_EXTRA])
        original_sample_host = sampler.Sampler.sample_host

        def delayed_sample_host(instance):
            # Force the second process tick past the slower footprint interval.
            time.sleep(0.12)
            return original_sample_host(instance)

        with mock.patch.object(sampler.Sampler, "sample_host", delayed_sample_host):
            _output, samples, report = self.run_sampler(stub, ["--vz-baseline"])
        scans = [record for record in samples if record["kind"] == "vz_scan"]
        self.assertGreaterEqual(len(scans), 2)
        self.assertEqual(scans[0]["pids"], [41311])
        appeared = [item for scan in scans for item in scan["new_pids"] if item["pid"] == 52000]
        self.assertEqual(len(appeared), 1)
        self.assertEqual(appeared[0]["lstart"], "Wed Sep 17 21:29:03 2026")
        self.assertFalse(appeared[0]["in_baseline"])
        self.assertEqual(report["vz_baseline"]["pids"], [41311])
        self.assertIn(52000, [item["pid"] for item in report["tracked"]])
        process = next(record for record in samples if record["kind"] == "process"
                       and record["pid"] == 52000
                       and record["measurement"].startswith("ps"))
        self.assertEqual(process["measurement"], "ps+footprint")

    def test_explicit_pids_are_marked_by_executable_not_by_how_they_were_supplied(self):
        """§3.3: is_vz comes from the sampler's own scan, for --pid entries too."""
        stub = CommandStub()
        _output, samples, _report = self.run_sampler(
            stub, ["--pid", "41303", "--pid", "41311",
                   "--label", "41303=d4acc-cli", "--label", "41311=d4acc-vz-a"])
        entries = {}
        for record in samples:
            if record["kind"] == "process" and record["measurement"].startswith("ps"):
                entries[record["pid"]] = record
        self.assertEqual(entries[41303]["source"], "argument")
        self.assertEqual(entries[41311]["source"], "argument")
        self.assertIs(entries[41303]["is_vz"], False)
        self.assertIs(entries[41311]["is_vz"], True)

    def test_absent_pid_is_recorded_as_not_present_without_counting_a_failure(self):
        stub = CommandStub(dead_pids=(999999,))
        _output, samples, report = self.run_sampler(stub, ["--pid", "999999"])
        entries = [record for record in samples if record["kind"] == "process"
                   and record["pid"] == 999999 and record["measurement"] == "ps"]
        self.assertTrue(entries)
        self.assertFalse(entries[0]["present"])
        self.assertTrue(entries[-1]["gone"])
        self.assertEqual(report["failures"]["by_command"].get("ps", 0), 0)

    def test_footprint_parse_failure_is_recorded_not_raised(self):
        stub = CommandStub(footprint_broken=True)
        _output, samples, report = self.run_sampler(stub, ["--pid", "41303"])
        entry = next(record for record in samples
                     if record["kind"] == "process" and record["pid"] == 41303
                     and record["measurement"] == "ps+footprint")
        self.assertIn("footprint_parse_error", entry)
        self.assertEqual(entry["footprint_raw_prefix"], "unexpected output\n")
        self.assertNotIn("footprint_bytes", entry)
        self.assertGreaterEqual(report["failures"]["by_command"]["footprint"], 1)

    def test_existing_output_directory_is_refused(self):
        output = self.directory / "out"
        output.mkdir()
        with mock.patch.object(sampler, "run_command", CommandStub()), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(sampler.main(["--out", str(output), "--duration", "0.1"]), 2)
        self.assertEqual(list(output.iterdir()), [])


SIGTERM_DRIVER = """
import sys
sys.path.insert(0, {scripts!r})
import f3_host_sampler as sampler


def stub(argv, timeout=None):
    return {{"argv": [str(item) for item in argv], "duration_s": 0.0, "returncode": 0,
            "stdout": "", "stderr": ""}}


sampler.run_command = stub
sys.exit(sampler.main(sys.argv[1:]))
"""


class SignalTests(TemporaryDirectoryCase):
    def test_sigterm_writes_sampler_json_and_exits_zero(self):
        driver = self.directory / "driver.py"
        driver.write_text(SIGTERM_DRIVER.format(scripts=str(SCRIPTS)))
        output = self.directory / "out"
        process = subprocess.Popen(
            [sys.executable, "-B", str(driver), "--out", str(output),
             "--interval", "0.05", "--slow-interval", "0.05", "--df-interval", "0.05",
             "--duration", "120"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            samples = output / "host_samples.jsonl"
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if samples.exists() and samples.read_text().strip():
                    break
                if process.poll() is not None:
                    break
                time.sleep(0.05)
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=30)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
        self.assertEqual(process.returncode, 0, msg=f"stdout={stdout!r} stderr={stderr!r}")
        report = json.loads((output / "sampler.json").read_text())
        self.assertEqual(report["stop_reason"], "signal")
        self.assertEqual(report["signal"], "SIGTERM")
        self.assertGreaterEqual(report["sample_lines"], 1)
        self.assertIn("sampler.json", stdout)


if __name__ == "__main__":
    unittest.main()
