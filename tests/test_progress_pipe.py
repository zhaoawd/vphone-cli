"""Exercise production progress writes with real PTY and broken pipe descriptors."""
import io
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'macOS Swift required')
class ProgressPipeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='vphone-progress-pipe-')
        cls.work = Path(cls.temporary.name)
        cls.binary = cls.work / 'progress'
        result = subprocess.run([
            'swiftc', '-swift-version', '6', '-module-cache-path', str(cls.work / 'modules'),
            str(ROOT / 'sources/vphone-cli/VPhoneProgressBar.swift'),
            *[str(ROOT / 'sources/VPhoneCore' / name) for name in (
                'VPhoneProcessRunner.swift', 'VPhoneChildCancellation.swift',
                'VPhoneProcessIdentity.swift', 'VPhoneShutdownPolicy.swift', 'VPhoneResources.swift')],
            str(ROOT / 'tests/fixtures/progress_pipe/main.swift'), '-o', str(cls.binary),
        ], capture_output=True, text=True, timeout=90)
        if result.returncode:
            cls.temporary.cleanup()
            raise RuntimeError(result.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def run_transfer(self, mode, interrupt=None):
        destination = self.work / f'{mode}-{interrupt}.data'
        command = [str(self.binary), mode, str(destination)]
        if mode == 'broken-tar':
            archive = self.work / 'input.tar'
            payload = b''.join(bytes([i]) * 1024 for i in range(1, 5))
            with tarfile.open(archive, 'w') as writer:
                entry = tarfile.TarInfo(destination.name)
                entry.size = len(payload)
                writer.addfile(entry, io.BytesIO(payload))
            command.append(str(archive))
        with subprocess.Popen(command,
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE) as process:
            try:
                self.assertTrue(select.select([process.stdout], [], [], 5)[0], 'fixture not ready')
                self.assertEqual(process.stdout.readline(), b'ready\n')
                if interrupt:
                    process.send_signal(interrupt)
                    stdout, stderr = process.communicate(timeout=5)
                    self.assertEqual(process.returncode, -interrupt, stderr)
                    self.assertFalse(destination.exists())
                else:
                    stdout, stderr = process.communicate(b'continue\n', timeout=5)
                    self.assertEqual(process.returncode, 0, stderr)
                    self.assertEqual(destination.read_bytes(), b''.join(bytes([i]) * 1024 for i in range(1, 5)))
                    self.assertIn(b'completed', stdout)
                return stdout, stderr
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()

    def test_broken_progress_pipe_does_not_abort_data_write(self):
        self.run_transfer('broken-ignored')

    def test_broken_progress_pipe_with_default_sigpipe_handler(self):
        self.run_transfer('broken-default')

    def test_terminal_hangup_does_not_abort_data_write(self):
        self.run_transfer('hangup')

    def test_real_tar_transfer_and_final_progress_survive_closed_reader(self):
        self.run_transfer('broken-tar')

    def test_normal_terminal_progress(self):
        stdout, _ = self.run_transfer('tty')
        self.assertIn(b'transferring [', stdout)
        self.assertIn(b'100%', stdout)

    def test_initial_pipe_remains_silent(self):
        _, stderr = self.run_transfer('pipe')
        self.assertEqual(stderr, b'')

    def test_interrupt_and_terminate_still_stop_transfer(self):
        for number in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=number):
                self.run_transfer('broken-ignored', interrupt=number)


if __name__ == '__main__':
    unittest.main()
