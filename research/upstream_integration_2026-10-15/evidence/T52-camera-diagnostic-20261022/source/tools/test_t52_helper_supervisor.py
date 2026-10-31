import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from t52_helper_supervisor import supervise


class HelperSupervisorTests(unittest.TestCase):
    def child(self, root):
        ready = root / 'ready'
        source = "import signal,time,pathlib; signal.signal(signal.SIGINT,signal.SIG_IGN); signal.signal(signal.SIGTERM,signal.SIG_IGN); pathlib.Path(%r).touch(); time.sleep(60)" % str(ready)
        child = subprocess.Popen([sys.executable, '-c', source], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(lambda: child.kill() if child.poll() is None else None)
        until = time.monotonic() + 3
        while not ready.exists() and time.monotonic() < until: time.sleep(.01)
        self.assertTrue(ready.exists())
        return child

    def test_stop_marker_escalates_while_unresponsive_worker_cannot_process_python_threads(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); child = self.child(root)
            marker = root / 'stop'; marker.touch()
            result = supervise(child, time.time() + 3, marker, grace_seconds=.1)
            self.assertEqual(result['signals'], ['SIGINT', 'SIGTERM', 'SIGKILL'])
            self.assertTrue(result['withinDeadline'])
            self.assertIsNotNone(child.poll())

    def test_deadline_reserves_escalation_time_without_a_marker(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); child = self.child(root)
            result = supervise(child, time.time() + 1.5, root / 'absent', grace_seconds=.1)
            self.assertTrue(result['withinDeadline'])
            self.assertEqual(result['signals'][-1], 'SIGKILL')


if __name__ == '__main__': unittest.main()
