"""Run the API daemon's mapped-file scan (environment.loaded) on macOS.

The scan uses proc_pidinfo region path information. The harness loads a test
dylib, replaces it by rename as environment.install does, and checks that the
process still maps the old inode. This proves the host-kernel behaviour only;
iOS policy for inspecting other processes is not covered here.
"""
import errno
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / 'sources/VPhoneDaemon/Native'


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('clang'), 'macOS clang required')
class DaemonEnvironmentMappingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='vphone-env-map-build-')
        cls.harness = Path(cls.build.name) / 'harness'
        subprocess.run(['/usr/bin/clang', '-Wall', '-Wextra', '-Werror', '-DVP_CHECK_LAYOUT',
                        '-I', str(NATIVE / 'Include'),
                        str(ROOT / 'tests/fixtures/daemon_env_mappings/main.c'),
                        str(NATIVE / 'vphoned_mappings.c'), '-o', str(cls.harness)],
                       check=True, capture_output=True, text=True)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def dylib(self, directory, name, text):
        source = Path(directory) / f'{name}.c'
        source.write_text(f'const char *vp_marker_{name}(void) {{ return "{text}"; }}\n')
        output = Path(directory) / f'{name}.dylib'
        subprocess.run(['/usr/bin/clang', '-dynamiclib', str(source), '-o', str(output)],
                       check=True, capture_output=True, text=True)
        return output

    def run_harness(self, pid=0):
        with tempfile.TemporaryDirectory(prefix='vphone-env-map-run-') as directory:
            library = self.dylib(directory, 'libvpenv', 'old')
            replacement = self.dylib(directory, 'libvpenvnew', 'new')
            result = subprocess.run([str(self.harness), str(library), str(replacement), str(pid)],
                                    capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.splitlines()

    def test_layout_matches_the_sdk_header(self):
        self.assertIn('layout ok', self.run_harness())

    def test_loaded_library_is_current_then_stale_after_rename(self):
        lines = self.run_harness()
        self.assertIn('before-load 0', lines)
        self.assertIn('loaded current', lines)
        inodes = next(line for line in lines if line.startswith('inodes '))
        old, new = (int(part.split('=')[1]) for part in inodes.split()[1:])
        self.assertNotEqual(old, new)
        self.assertIn('after-replace old=1 new=0', lines)

    def test_buffer_too_small_is_an_error_not_a_partial_list(self):
        self.assertIn(f'capacity -1 errno={errno.ENOBUFS}', self.run_harness())

    def test_another_process_of_the_same_user_is_inspected(self):
        child = subprocess.Popen(['/bin/sleep', '30'])
        self.addCleanup(child.wait)
        self.addCleanup(child.kill)
        self.assertIn(f'pid {child.pid} result=1 errno=0', self.run_harness(child.pid))

    @unittest.skipIf(os.geteuid() == 0, 'root may inspect launchd')
    def test_uninspectable_process_reports_errno(self):
        line = next(line for line in self.run_harness(1) if line.startswith('pid 1 '))
        self.assertIn('result=-1', line)
        self.assertNotIn('errno=0', line)


if __name__ == '__main__':
    unittest.main()
