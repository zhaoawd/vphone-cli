"""Deliver native signals only to a child using the production registrations."""
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'macOS Swift required')
class ShutdownSignalTests(unittest.TestCase):
    def test_interrupt_and_termination_use_main_queue_then_restore_handlers(self):
        with tempfile.TemporaryDirectory(prefix='vphone-shutdown-signals-') as temporary:
            binary = Path(temporary) / 'signals'
            env = os.environ.copy()
            env.setdefault('CLANG_MODULE_CACHE_PATH', str(ROOT / '.build/test-module-cache'))
            compiled = subprocess.run([
                'swiftc', '-swift-version', '6',
                str(ROOT / 'sources/vphone-cli/VPhoneShutdownSignals.swift'),
                str(ROOT / 'tests/fixtures/shutdown_signals/main.swift'), '-o', str(binary),
            ], capture_output=True, text=True, env=env, timeout=90)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            for first, second in ((signal.SIGTERM, signal.SIGTERM),
                                  (signal.SIGINT, signal.SIGTERM),
                                  (signal.SIGTERM, signal.SIGINT),
                                  (signal.SIGINT, signal.SIGINT)):
                with self.subTest(first=first, second=second):
                    process = subprocess.Popen([str(binary)], stdout=subprocess.PIPE,
                                               stderr=subprocess.PIPE, bufsize=0)
                    pending = bytearray()

                    def line():
                        deadline = time.monotonic() + 5
                        while b'\n' not in pending:
                            remaining = deadline - time.monotonic()
                            self.assertGreater(remaining, 0, 'signal fixture did not respond')
                            ready, _, _ = select.select([process.stdout], [], [], remaining)
                            self.assertTrue(ready, 'signal fixture did not respond')
                            data = os.read(process.stdout.fileno(), 4096)
                            self.assertTrue(data, f'signal fixture exited before callback: {process.poll()}')
                            pending.extend(data)
                        output, _, rest = pending.partition(b'\n')
                        pending[:] = rest
                        return output.decode()

                    try:
                        self.assertEqual(line(), 'ready')
                        process.send_signal(first)
                        self.assertEqual(line(), f'received {first}')
                        self.assertIsNone(process.poll(), 'first signal bypassed orderly shutdown')
                        process.send_signal(second)
                        self.assertEqual(line(), f'received {second}')
                        self.assertEqual(line(), 'restored')
                        self.assertEqual(process.wait(timeout=5), 74)
                    finally:
                        if process.poll() is None:
                            process.kill()
                        process.wait(timeout=5)
                        process.stdout.close()
                        process.stderr.close()


if __name__ == '__main__':
    unittest.main()
