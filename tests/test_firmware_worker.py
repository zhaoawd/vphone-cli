"""Exercise worker/recovery locking with real temporary subprocesses."""

from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKER = ROOT / "scripts/firmware_worker.py"


@contextmanager
def directory_fd(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        yield fd
    finally:
        os.close(fd)


class FirmwareWorkerTests(unittest.TestCase):
    def test_worker_survives_parent_kill_and_retains_lock(self):
        with tempfile.TemporaryDirectory() as temporary:
            transaction = Path(temporary)
            (transaction / "work").mkdir()
            ready, release = transaction / "ready", transaction / "release"
            child_code = ("from pathlib import Path; import time,sys; Path(sys.argv[1]).touch(); "
                          "exec('while not Path(sys.argv[2]).exists(): time.sleep(0.01)')")
            worker_args = [sys.executable, str(WORKER), str(transaction), sys.executable,
                           "-c", child_code, str(ready), str(release)]
            parent_code = "import subprocess,sys; p=subprocess.Popen(sys.argv[1:]); print(p.pid,flush=True); p.wait()"
            parent = subprocess.Popen([sys.executable, "-c", parent_code] + worker_args,
                                      stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            try:
                self.assertGreater(int(parent.stdout.readline()), 0)
                deadline = time.monotonic() + 10
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(ready.exists())
                parent.kill()
                parent.wait(timeout=10)
                with directory_fd(transaction) as handle:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                release.touch()
                with directory_fd(transaction) as handle:
                    deadline = time.monotonic() + 10
                    while True:
                        try:
                            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                            break
                        except BlockingIOError:
                            if time.monotonic() >= deadline:
                                self.fail("worker did not release its lock after tool exit")
                            time.sleep(0.01)
            finally:
                release.touch()
                if parent.poll() is None:
                    parent.kill()
                parent.wait(timeout=10)
                parent.stdout.close()

    def test_worker_holds_lock_until_child_finishes(self):
        with tempfile.TemporaryDirectory() as temporary:
            transaction = Path(temporary)
            (transaction / "work").mkdir()
            ready = transaction / "ready"
            release = transaction / "release"
            code = ("from pathlib import Path; import time,sys; "
                    "Path(sys.argv[1]).touch(); "
                    "exec('while not Path(sys.argv[2]).exists(): time.sleep(0.01)')")
            process = subprocess.Popen([sys.executable, str(WORKER), str(transaction),
                                        sys.executable, "-c", code, str(ready), str(release)],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 10
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(ready.exists())
                with directory_fd(transaction) as handle:
                    with self.assertRaises(BlockingIOError):
                        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                release.touch()
                self.assertEqual(process.wait(timeout=10), 0)
                with directory_fd(transaction) as handle:
                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                release.touch()
                process.wait(timeout=10)
                process.stderr.close()

    def test_worker_cannot_start_after_recovery_archives_its_lock(self):
        with tempfile.TemporaryDirectory() as temporary:
            transaction = Path(temporary) / "active"
            transaction.mkdir()
            (transaction / "work").mkdir()
            marker = Path(temporary) / "should-not-exist"
            with directory_fd(transaction) as handle:
                fcntl.flock(handle, fcntl.LOCK_EX)
                process = subprocess.Popen([sys.executable, str(WORKER), str(transaction),
                                            sys.executable, "-c", "from pathlib import Path; import sys; Path(sys.argv[1]).touch()", str(marker)],
                                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
                transaction.rename(Path(temporary) / "archived")
                fcntl.flock(handle, fcntl.LOCK_UN)
            self.assertEqual(process.wait(timeout=10), 1)
            process.stderr.close()
            self.assertFalse(marker.exists())

    def test_shell_lock_refuses_unrecovered_firmware(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / ".firmware-transaction").mkdir()
            for operation in ("boot", "dfu", "cfw", "export", "fw-prepare"):
                result = subprocess.run([sys.executable, str(ROOT / "scripts/vm_lock.py"), temporary,
                                         operation, "--", "/usr/bin/true"], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("pending firmware transaction", result.stderr)
            result = subprocess.run([sys.executable, str(ROOT / "scripts/vm_lock.py"), temporary,
                                     "fw-patch", "--", "/usr/bin/true"], capture_output=True)
            self.assertEqual(result.returncode, 0)
