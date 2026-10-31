import json
from pathlib import Path
import socket
import tempfile
import threading
import time
import unittest

from launch_t52_diagnostic_session import wait_until_ready


class Recorder:
    def record(self, *args):
        pass


class Launcher:
    returncode = None

    def poll(self):
        return self.returncode


class DiagnosticReadinessTests(unittest.TestCase):
    def test_launcher_waits_for_delayed_socket_without_starting_another_vm(self):
        with tempfile.TemporaryDirectory(prefix='t52-ready-', dir='/tmp') as folder:
            vm = Path(folder)
            errors = []
            def server():
                try:
                    time.sleep(.15)
                    (vm / '.vphone-runtime.json').write_text(json.dumps(dict(operation='boot', instanceID='new', pid=42)))
                    with socket.socket(socket.AF_UNIX) as listener:
                        listener.bind(str(vm / 'vphone.sock'))
                        listener.listen()
                        listener.settimeout(2)
                        for response in [dict(guest_connected=True), dict(ok=True)]:
                            connection, _ = listener.accept()
                            with connection:
                                connection.recv(4096)
                                connection.sendall(json.dumps(response).encode() + b'\n')
                except Exception as error:
                    errors.append(error)
            thread = threading.Thread(target=server)
            thread.start()
            try:
                result = wait_until_ready(Launcher(), vm=vm, previous_instance='old', recorder=Recorder(), timeout=2)
                self.assertEqual(result['runtime']['instanceID'], 'new')
                self.assertEqual(result['runtime']['pid'], 42)
            finally:
                thread.join(3)
            self.assertFalse(thread.is_alive())
            self.assertEqual(errors, [])

    def test_absent_socket_is_bounded_by_deadline(self):
        with tempfile.TemporaryDirectory(prefix='t52-ready-', dir='/tmp') as folder:
            with self.assertRaisesRegex(RuntimeError, 'did not become ready'):
                wait_until_ready(Launcher(), vm=Path(folder), previous_instance='old', recorder=Recorder(), timeout=.1)

    def test_exited_launcher_is_not_treated_as_pending_readiness(self):
        with tempfile.TemporaryDirectory(prefix='t52-ready-', dir='/tmp') as folder:
            child = Launcher(); child.returncode = 23
            with self.assertRaisesRegex(RuntimeError, 'launcher exited: 23'):
                wait_until_ready(child, vm=Path(folder), previous_instance='old', recorder=Recorder(), timeout=.1)


if __name__ == '__main__':
    unittest.main()
