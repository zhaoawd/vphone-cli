"""Run the standalone launcher process implementation in an isolated process."""
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class LauncherProcessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='vphone-launcher-tests-')
        cls.addClassCleanup(cls.temp.cleanup)
        root = Path(cls.temp.name)
        main = root / 'main.swift'
        main.write_text('''import Darwin
let arguments = Array(CommandLine.arguments.dropFirst())
do {
    let status = try VPhoneLaunchpadLauncherProcess.run(path: arguments[0], argv: arguments)
    VPhoneLaunchpadLauncherProcess.exit(withStatusOf: status)
} catch { exit(71) }
''')
        cls.binary = root / 'probe'
        subprocess.run(['swiftc', str(ROOT / 'sources/VPhoneLaunchpadLauncherEntry/VPhoneLaunchpadLauncherProcess.swift'),
                        str(main), '-o', str(cls.binary)], check=True, capture_output=True, timeout=90)

    def test_child_output_and_exit_status_including_immediate_exit(self):
        for _ in range(20):
            result = subprocess.run([str(self.binary), '/bin/sh', '-c', 'printf tail; exit 23'],
                                    capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 23)
            self.assertEqual(result.stdout, b'tail')

    def test_spawn_failure_is_not_reported_as_success(self):
        result = subprocess.run([str(self.binary), '/nonexistent-vphone-child'], capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 71)

    def test_ordinary_child_inherits_cwd_environment_and_standard_descriptors(self):
        environment = dict(os.environ, VPHONE_LAUNCHER_TEST='value')
        result = subprocess.run([str(self.binary), '/bin/sh', '-c', 'printf "%s\\n" "$PWD" "$VPHONE_LAUNCHER_TEST"; cat'],
                                cwd=self.temp.name, env=environment, input=b'stdin', capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, (str(Path(self.temp.name).resolve()) + '\nvalue\nstdin').encode())

    def test_forwarded_signals_preserve_child_signal_status(self):
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT):
            with self.subTest(signal=number):
                child = subprocess.Popen([str(self.binary), '/bin/sleep', '30'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    time.sleep(.15)
                    child.send_signal(number)
                    child.communicate(timeout=10)
                    self.assertEqual(child.returncode, -number)
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.communicate(timeout=10)


if __name__ == '__main__':
    unittest.main()
