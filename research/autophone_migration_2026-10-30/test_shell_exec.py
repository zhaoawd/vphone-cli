"""Run the actual guest shell executor C source against macOS POSIX processes."""
import ctypes
import json
import os
import subprocess
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / ".build/autophone-stage2/upstream/VPhoneDaemon/Native/vphoned_shell_exec.c"
LIBRARY = ROOT / ".build/autophone-stage2/native/libShellExec.dylib"
CANCEL = ctypes.CFUNCTYPE(ctypes.c_bool, ctypes.c_void_p)


class Result(ctypes.Structure):
    _fields_ = [("out_bytes", ctypes.c_void_p), ("out_length", ctypes.c_size_t),
                ("err_bytes", ctypes.c_void_p), ("err_length", ctypes.c_size_t),
                ("exit_code", ctypes.c_int), ("timed_out", ctypes.c_bool),
                ("cancelled", ctypes.c_bool), ("stdout_truncated", ctypes.c_bool),
                ("stderr_truncated", ctypes.c_bool)]


class ShellExecTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        LIBRARY.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", "-Werror", "-dynamiclib",
                        str(SOURCE), "-o", str(LIBRARY)], check=True)
        cls.library = ctypes.CDLL(str(LIBRARY))
        cls.library.vp_shell_execute.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p,
                                                ctypes.c_int, CANCEL, ctypes.c_void_p,
                                                ctypes.POINTER(Result)]
        cls.library.vp_shell_execute.restype = ctypes.c_int
        cls.library.vp_shell_result_free.argtypes = [ctypes.POINTER(Result)]

    def run_shell(self, command, *, timeout=3000, cwd=None, cancelled=lambda: False):
        result = Result()
        callback = CANCEL(lambda _context: cancelled())
        code = self.library.vp_shell_execute(b"/bin/sh", command.encode(),
                                             str(cwd).encode() if cwd else None,
                                             timeout, callback, None, ctypes.byref(result))
        if code:
            raise OSError(code, os.strerror(code))
        try:
            return {"stdout": ctypes.string_at(result.out_bytes, result.out_length).decode("utf-8", "replace"),
                    "stderr": ctypes.string_at(result.err_bytes, result.err_length).decode("utf-8", "replace"),
                    **{key: getattr(result, key) for key in ("exit_code", "timed_out", "cancelled",
                                                           "stdout_truncated", "stderr_truncated")}}
        finally:
            self.library.vp_shell_result_free(ctypes.byref(result))

    def assert_reaped(self, pid):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(.02)
        self.fail(f"child PID {pid} remains after cleanup")

    def test_stdout_stderr_exit_and_parent(self):
        result = self.run_shell("printf '%s' \"$PPID\"; printf error >&2; exit 7")
        self.assertEqual(result["stdout"], str(os.getpid()))
        self.assertEqual(result["stderr"], "error")
        self.assertEqual(result["exit_code"], 7)

    def test_cwd_and_stdin_eof(self):
        with tempfile.TemporaryDirectory(prefix="shell cwd ") as directory:
            result = self.run_shell("read input; pwd", cwd=directory)
            self.assertEqual(Path(result["stdout"].strip()).resolve(), Path(directory).resolve())

    def test_missing_cwd_refuses_spawn(self):
        with self.assertRaises(OSError):
            self.run_shell("exit 0", cwd="/this-directory-must-not-exist-vphone")

    def test_timeout_kills_child_group(self):
        result = self.run_shell("sleep 60 & child=$!; printf '%s' \"$child\"; wait", timeout=100)
        self.assertTrue(result["timed_out"])
        self.assertEqual(result["exit_code"], 137)
        self.assert_reaped(int(result["stdout"]))

    def test_exited_leader_does_not_leave_pipe_owner(self):
        result = self.run_shell("sleep 60 & printf '%s' \"$!\"", timeout=100)
        self.assertTrue(result["timed_out"])
        self.assert_reaped(int(result["stdout"]))

    def test_cancellation_kills_child_group(self):
        event = threading.Event()
        timer = threading.Timer(.1, event.set)
        timer.start()
        try:
            result = self.run_shell("sleep 60 & child=$!; printf '%s' \"$child\"; wait",
                                    cancelled=event.is_set)
        finally:
            timer.join()
        self.assertTrue(result["cancelled"])
        self.assertFalse(result["timed_out"])
        self.assert_reaped(int(result["stdout"]))

    def test_early_cancellation_never_starts_command(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_shell("printf bad > marker", cwd=directory, cancelled=lambda: True)
            self.assertTrue(result["cancelled"])
            self.assertFalse((Path(directory) / "marker").exists())

    def test_stream_caps_and_json_worst_case(self):
        result = self.run_shell("printf '%070000d' 0; printf '%070000d' 0 >&2")
        self.assertEqual(len(result["stdout"]), 65536)
        self.assertEqual(len(result["stderr"]), 65536)
        self.assertTrue(result["stdout_truncated"] and result["stderr_truncated"])
        result = self.run_shell("dd if=/dev/zero bs=65536 count=1 2>/dev/null; dd if=/dev/zero bs=65536 count=1 >&2 2>/dev/null")
        self.assertEqual(result["stdout"], "\0" * 65536)
        self.assertEqual(result["stderr"], "\0" * 65536)
        self.assertFalse(result["stdout_truncated"] or result["stderr_truncated"])
        self.assertLess(len(json.dumps({"ok": True, "result": result}).encode()), 1 << 20)

    def test_infinite_output_does_not_prevent_timeout(self):
        start = time.monotonic()
        result = self.run_shell("while :; do printf output; done", timeout=100)
        self.assertTrue(result["timed_out"])
        self.assertLess(time.monotonic() - start, 2)

    def test_independent_command_is_not_blocked(self):
        with ThreadPoolExecutor(max_workers=2) as pool:
            slow = pool.submit(self.run_shell, "sleep 1")
            start = time.monotonic()
            self.assertEqual(self.run_shell("printf ready")["stdout"], "ready")
            self.assertLess(time.monotonic() - start, .5)
            self.assertEqual(slow.result()["exit_code"], 0)


if __name__ == "__main__":
    unittest.main()
