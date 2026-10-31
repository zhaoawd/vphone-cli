"""Validate scoped grants and xpcproxy credential forwarding with real C code."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class GuestSimulationAccessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='simulation-access-build-')
        cls.addClassCleanup(cls.temp.cleanup)
        cls.binary = Path(cls.temp.name) / 'access'
        run = subprocess.run(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror',
                              str(ROOT / 'tests/fixtures/guest_simulation_access.c'), '-o', str(cls.binary)],
                             capture_output=True, text=True, timeout=60)
        if run.returncode: raise RuntimeError(run.stderr)

    def run_case(self, case):
        with tempfile.TemporaryDirectory(prefix='simulation-access-data-') as folder:
            run = subprocess.run([str(self.binary), folder, case], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stderr)

    def test_preparation_preserves_existing_receipt_and_rejects_symlinks(self):
        for case in ['prepare', 'symlink']:
            with self.subTest(case=case): self.run_case(case)

    def test_grants_and_forwarding_keep_write_access_out_of_apps(self): self.run_case('scopes')
    def test_consume_removes_credentials_and_preserves_process_scope(self): self.run_case('consume')
    def test_only_known_app_and_camera_targets_receive_grants(self): self.run_case('targets')


if __name__ == '__main__': unittest.main()
