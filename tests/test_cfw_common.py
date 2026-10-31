"""Exercise shared installer operations with temporary files and command doubles."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
COMMON = ROOT / "scripts/lib/cfw_common.sh"


class CommonCFWTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cfw common ")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.scripts = self.base / "scripts"
        self.scripts.mkdir()
        self.vm = self.base / "vm"
        self.vm.mkdir()
        self.env = dict(os.environ, CFW_TEST_COMMON=str(COMMON),
                        CFW_TEST_SCRIPTS=str(self.scripts), CFW_TEST_VM=str(self.vm),
                        VPHONE_PYTHON=sys.executable)

    def run_shell(self, body, **env):
        return subprocess.run(["/bin/zsh", "-c", '''
SCRIPT_DIR="$CFW_TEST_SCRIPTS"
VM_DIR="$CFW_TEST_VM"
source "$CFW_TEST_COMMON"
''' + body], capture_output=True, text=True, env=dict(self.env, **env), timeout=20)

    def test_archive_search_order_and_existing_input_reuse(self):
        resources = self.scripts / "resources"
        resources.mkdir()
        for parent in (resources, self.scripts, self.vm):
            (parent / "input.tar").write_text(parent.name)
        body = '''
tar_double() { print -r -- "$*" >> "$VM_DIR/calls"; mkdir "$VM_DIR/input"; }
cfw_extract_input input input.tar missing tar_double --zstd
cfw_extract_input input input.tar missing tar_double --zstd
'''
        result = self.run_shell(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = (self.vm / "calls").read_text().splitlines()
        self.assertEqual(len(lines), 1)
        self.assertIn(str(resources / "input.tar"), lines[0])

    def test_archive_failure_preserves_exit_code_and_stops_next_stage(self):
        (self.vm / "input.tar").touch()
        result = self.run_shell('''
tar_double() { return 37; }
cfw_extract_input input input.tar missing tar_double
print next > "$VM_DIR/next"
''')
        self.assertEqual(result.returncode, 37)
        self.assertFalse((self.vm / "next").exists())

    def test_appos_repeat_uses_original_cache(self):
        source = self.vm / "source"
        source.write_bytes(b"first")
        result = self.run_shell('''
cfw_cache_appos "$VM_DIR/source" "$VM_DIR/cache"
print second > "$VM_DIR/source"
cfw_cache_appos "$VM_DIR/source" "$VM_DIR/cache"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.vm / "cache").read_bytes(), b"first")

    def test_invalid_python_stops_before_lock_or_install(self):
        (self.scripts / "check_python_runtime.py").write_text("raise SystemExit(19)\n")
        (self.scripts / "vm_lock.py").write_text("raise AssertionError('lock must not be reached')\n")
        result = self.run_shell('cfw_require_runtime_and_lock\nprint next > "$VM_DIR/next"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Python runtime invalid", result.stderr)
        self.assertNotIn("AssertionError", result.stderr)
        self.assertFalse((self.vm / "next").exists())

    def test_missing_lock_stops_before_install(self):
        (self.scripts / "check_python_runtime.py").write_text("pass\n")
        (self.scripts / "vm_lock.py").write_text("raise SystemExit(17)\n")
        result = self.run_shell('cfw_require_runtime_and_lock\nprint next > "$VM_DIR/next"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("VM lock missing", result.stderr)
        self.assertFalse((self.vm / "next").exists())

    def test_cleanup_only_detaches_own_cryptex_paths_and_retains_failure(self):
        result = self.run_shell('''
CFW_HOST_MNT="$VM_DIR/private-mounts"
safe_detach() { print -r -- "$1" >> "$VM_DIR/detaches"; return 9; }
trap cleanup_on_exit EXIT
exit 37
''')
        self.assertEqual(result.returncode, 37)
        self.assertEqual((self.vm / "detaches").read_text().splitlines(),
                         [str(self.vm / "private-mounts/mnt_sysos"), str(self.vm / "private-mounts/mnt_appos")])

    def test_symlink_outside_vm_is_rejected(self):
        (self.vm / "escape").symlink_to(self.scripts, target_is_directory=True)
        result = self.run_shell('assert_mount_under_vm "$VM_DIR/escape"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsafe", result.stderr)

    def test_missing_restore_reports_error(self):
        result = self.run_shell('find_restore_dir')
        self.assertNotEqual(result.returncode, 0)
