"""Run the production event hub and publisher with a deterministic scheduler."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'macOS Swift required')
class DaemonEventPublisherTests(unittest.TestCase):
    def test_subscriptions_control_polling_and_reconnect_snapshot(self):
        wire = (ROOT / 'sources/VPhoneDaemon/Daemon/APIWire.swift').read_text()
        hub = wire.split('/// A client receives guest events', 1)[1]
        publisher = (ROOT / 'sources/VPhoneDaemon/Daemon/GuestEventPublisher.swift').read_text()
        publisher = '\n'.join(line for line in publisher.splitlines() if line != 'import IcliKit')
        harness = (ROOT / 'tests/fixtures/daemon_event_publisher/main.swift').read_text()
        with tempfile.TemporaryDirectory(prefix='vphone-event-publisher-') as temporary:
            root = Path(temporary)
            main = root / 'main.swift'
            main.write_text(publisher + '\n/// A client receives guest events' + hub + '\n' + harness)
            binary = root / 'probe'
            env = os.environ.copy()
            env.setdefault('CLANG_MODULE_CACHE_PATH', str(ROOT / '.build/test-module-cache'))
            result = subprocess.run(['swiftc', '-swift-version', '6', str(main), '-o', str(binary)],
                                    capture_output=True, text=True, timeout=90, env=env)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
