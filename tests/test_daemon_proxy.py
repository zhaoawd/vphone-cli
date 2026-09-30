"""Run the imported proxy/worker lifecycle on macOS with disposable host workers."""
import errno
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('clang'), 'macOS clang required')
class DaemonProxyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='vphone-proxy-build-')
        cls.binary = Path(cls.build.name) / 'proxy-harness'
        subprocess.run(['/usr/bin/clang', '-Wall', '-Wextra', '-Werror', '-pthread',
                        str(ROOT / 'tests/fixtures/daemon_proxy/main.c'), '-o', str(cls.binary)], check=True,
                       capture_output=True, text=True)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='vphone-proxy-run-')
        self.addCleanup(self.temp.cleanup)
        self.ready = Path(self.temp.name) / 'ready'

    def start(self, action='wait', pending=False, ignore_child=False):
        env = dict(os.environ, VPHONE_PROXY_TEST_ACTION=action, VPHONE_PROXY_TEST_READY=str(self.ready),
                   VPHONE_PROXY_TEST_PENDING='1' if pending else '0',
                   VPHONE_PROXY_TEST_PORT=str(self.ready.with_name('port')),
                   VPHONE_PROXY_TEST_IGNORE_CHLD='1' if ignore_child else '0')
        process = subprocess.Popen([str(self.binary)], env=env, start_new_session=True,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.cleanup_process, process)
        return process

    @staticmethod
    def cleanup_process(process):
        # Each harness owns a fresh process group, including its test worker.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate(timeout=5)

    @staticmethod
    def stop_and_read_log(process):
        process.terminate()
        _, log = process.communicate(timeout=5)
        return log

    def wait_workers(self, count=1, timeout=6):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            pids = [int(p) for p in self.ready.read_text().split()] if self.ready.exists() else []
            if len(pids) >= count:
                return pids
            time.sleep(.02)
        self.fail(f'Expected {count} ready workers')

    def assert_exited(self, pid):
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:
            status = subprocess.run(['/bin/ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True)
            if status.returncode != 0 or status.stdout.strip().startswith('Z'):
                return
            time.sleep(.03)
        self.fail(f'Test worker {pid} still running')

    def test_invalid_worker_arguments_are_rejected(self):
        for args in (['--io'], ['--io', '2'], ['--io', '-1'], ['--io', 'abc'],
                     ['--io', '999999999999999999999'], ['--unknown'], ['--io', '3', 'extra']):
            with self.subTest(args=args):
                result = subprocess.run([str(self.binary), *args], timeout=3)
                self.assertEqual(result.returncode, 64)

    def test_successful_worker_stops_proxy_without_retry(self):
        process = self.start('success')
        self.assertEqual(process.wait(timeout=4), 0)
        self.assertEqual(len(self.wait_workers()), 1)

    def test_failed_worker_is_restarted_and_stop_reaps_child(self):
        process = self.start('crash')
        pids = self.wait_workers(2)
        self.assertNotEqual(pids[0], pids[1])
        process.terminate()
        self.assertEqual(process.wait(timeout=4), 0)
        for pid in pids:
            self.assert_exited(pid)

    def test_proxy_sigterm_stops_worker(self):
        process = self.start()
        pid = self.wait_workers()[0]
        process.terminate()
        self.assertEqual(process.wait(timeout=4), 0)
        self.assert_exited(pid)

    def test_proxy_death_closes_liveness_pipe_and_worker_exits(self):
        process = self.start()
        pid = self.wait_workers()[0]
        process.kill()
        process.wait(timeout=4)
        self.assert_exited(pid)

    def test_stop_escalates_for_worker_ignoring_term_and_pipe(self):
        process = self.start('stubborn')
        pid = self.wait_workers()[0]
        process.terminate()
        self.assertEqual(process.wait(timeout=5), 0)
        self.assert_exited(pid)

    def test_pending_update_failure_returns_to_launchd_without_retry(self):
        process = self.start('crash', pending=True)
        self.assertEqual(process.wait(timeout=4), 1)
        self.assertEqual(len(self.wait_workers()), 1)

    # Upstream 2e2ed0a8: fixed one-second retry and a logged reason per exit.

    def test_restart_delay_stays_one_second(self):
        started = time.monotonic()
        process = self.start('crash')
        # Exponential backoff (1, 2, 4 s) needs about 7 s for the fourth worker.
        pids = self.wait_workers(4, timeout=5)
        elapsed = time.monotonic() - started
        self.stop_and_read_log(process)
        self.assertEqual(len(set(pids[:4])), 4)
        self.assertGreaterEqual(elapsed, 2.9, 'Three retries must each pause about one second')
        self.assertLess(elapsed, 5)

    def test_worker_exit_status_is_logged(self):
        process = self.start('crash')
        pids = self.wait_workers(2)
        log = self.stop_and_read_log(process)
        self.assertIn(f'vphoned proxy: worker {pids[0]} exited with status 23; retrying', log)

    def test_worker_signal_is_logged(self):
        process = self.start('signal')
        pids = self.wait_workers(2)
        log = self.stop_and_read_log(process)
        self.assertIn(f'vphoned proxy: worker {pids[0]} killed by signal {signal.SIGKILL.value}; retrying', log)

    def test_waitpid_failure_logs_wait_error_not_later_errno(self):
        # access() for the pending-update marker sets ENOENT after waitpid fails.
        process = self.start('crash', ignore_child=True)
        pids = self.wait_workers(2)
        log = self.stop_and_read_log(process)
        self.assertIn(f'vphoned proxy: waitpid {pids[0]} failed: {os.strerror(errno.ECHILD)}; retrying', log)
        self.assertNotIn(os.strerror(errno.ENOENT), log)

    def assert_port_released(self, port):
        deadline = time.monotonic() + 4
        while True:
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
                try:
                    probe.bind(('127.0.0.1', port))
                    return
                except OSError:
                    if time.monotonic() >= deadline:
                        self.fail(f'Worker port {port} is still bound')
            time.sleep(.03)

    def test_worker_port_is_released_after_proxy_stop_or_death(self):
        for stop in ('terminate', 'kill'):
            with self.subTest(stop=stop):
                self.ready.unlink(missing_ok=True)
                process = self.start('bind')
                pid = self.wait_workers()[0]
                port = int(self.ready.with_name('port').read_text())
                getattr(process, stop)()
                process.wait(timeout=5)
                self.assert_exited(pid)
                self.assert_port_released(port)
