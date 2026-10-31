import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / 'scripts/vm_lock.py'


class VMLockTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='vm lock ')
        self.addCleanup(self.tmp.cleanup)
        self.vm = Path(self.tmp.name).resolve()

    def launch(self, command=None, directory=None):
        command = command or [sys.executable, '-c', 'import time; time.sleep(30)']
        proc = subprocess.Popen([sys.executable, str(HELPER), str(directory or self.vm), 'test', '--', *command],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        self.addCleanup(lambda: self.stop(proc))
        return proc

    def stop(self, proc):
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
        proc.communicate(timeout=5)

    def wait_record(self):
        record = self.vm / '.vphone-runtime.json'
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if record.exists():
                return json.loads(record.read_text())
            time.sleep(.02)
        self.fail('runtime record was not published')

    def test_diagnostic_failure_keeps_lock_and_runs_command(self):
        (self.vm / '.vphone-runtime.json').mkdir()
        proc = self.launch(['/bin/zsh', '-c', 'print ready; sleep 1'])
        self.assertEqual(proc.stdout.readline().strip(), b'ready')
        fd = os.open(self.vm, os.O_RDONLY)
        try:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            os.close(fd)
        _, error = proc.communicate(timeout=5)
        self.assertEqual(proc.returncode, 0, error)
        self.assertIn(b'runtime record', error)

    def test_parallel_launch_and_alias_are_rejected(self):
        first = self.launch()
        state = self.wait_record()
        self.assertEqual(state['pid'], first.pid)
        self.assertTrue(state['instanceID'])
        self.assertTrue(state['startedAt'])
        alias = self.vm / 'alias'
        alias.symlink_to(self.vm)
        second = self.launch(directory=alias)
        _, error = second.communicate(timeout=5)
        self.assertNotEqual(second.returncode, 0)
        self.assertIn(b'VM lock unavailable', error)
        (self.vm / '.vphone-runtime.json').unlink()
        third = self.launch()
        third.communicate(timeout=5)
        self.assertNotEqual(third.returncode, 0)

    def test_simultaneous_launch_has_exactly_one_owner(self):
        first, second = self.launch(), self.launch()
        self.wait_record()
        deadline = time.monotonic() + 5
        while first.poll() is None and second.poll() is None and time.monotonic() < deadline:
            time.sleep(.02)
        statuses = [first.poll(), second.poll()]
        self.assertEqual(statuses.count(None), 1, statuses)
        self.assertTrue(any(code is not None and code != 0 for code in statuses))

    def test_kernel_releases_after_kill_and_stale_record_is_replaced(self):
        first = self.launch()
        old = self.wait_record()
        self.stop(first)
        second = self.launch([sys.executable, '-c', 'pass'])
        second.communicate(timeout=5)
        self.assertEqual(second.returncode, 0)
        self.assertNotEqual(self.wait_record()['instanceID'], old['instanceID'])

    def test_exit_code_and_inherited_descriptor_validation(self):
        child = self.launch(['/bin/zsh', '-c', '"$1" "$2" --check-inherited "$3" || exit 90; exit 37',
                             'zsh', sys.executable, str(HELPER), str(self.vm)])
        _, error = child.communicate(timeout=5)
        self.assertEqual(child.returncode, 37, error)
        invalid = subprocess.run([sys.executable, str(HELPER), '--check-inherited', str(self.vm)],
                                 env=dict(os.environ, VPHONE_VM_LOCK_FD='999'), capture_output=True)
        self.assertNotEqual(invalid.returncode, 0)

    def test_other_vm_is_independent(self):
        self.launch()
        self.wait_record()
        other = self.vm / 'other'
        other.mkdir()
        proc = self.launch([sys.executable, '-c', 'pass'], directory=other)
        proc.communicate(timeout=5)
        self.assertEqual(proc.returncode, 0)

    def test_child_keeps_lock_if_shell_owner_is_killed(self):
        proc = self.launch(['/bin/zsh', '-c', 'sleep 2 & print ready; wait'])
        self.assertEqual(proc.stdout.readline().strip(), b'ready')
        proc.kill()
        fd = os.open(self.vm, os.O_RDONLY)
        try:
            with self.assertRaises(BlockingIOError):
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            proc.communicate(timeout=5)
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        finally:
            os.close(fd)


if __name__ == '__main__':
    unittest.main()
