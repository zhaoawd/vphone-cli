"""Exercise shared installer operations with temporary files and command doubles."""
import os
import json
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
# Unit tests of cache/cleanup helpers; real gate chain has separate integration tests.
cfw_guest_write() { "$@"; }
cfw_cache_appos() { [[ -f "$2" ]] || cp "$1" "$2"; }
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


class JournalBoundMountTests(unittest.TestCase):
    def setUp(self):
        from tests.test_patch_plan_gate import FrozenGateTests
        from cfw_disk_txn import mount_identity
        self.f = FrozenGateTests()
        self.f.setUp()
        self.addCleanup(self.f.doCleanups)
        self.mount = self.f.root.resolve() / '.cfw_mount.external'
        self.mount.mkdir(mode=0o700)
        self.target = self.mount / 'mnt_sysos'
        self.target.mkdir()
        self.work = self.f.evidence.parent
        self.work.mkdir(mode=0o700)
        self.record = dict(version=5, provenanceMode='required', guestEvidenceRequired=True,
                           runtimeImageEvidenceRequired=True, vm=str(self.f.vm),
                           mountRoot=mount_identity(self.mount))
        self.journal = self.work / 'transaction.json'
        self.journal.write_text(json.dumps(self.record))

    def check(self, target):
        return subprocess.run(['/bin/zsh', '-c', '''
SCRIPT_DIR="$CFW_TEST_SCRIPTS"
VM_DIR="$CFW_TEST_VM"
PYTHON3="$VPHONE_PYTHON"
source "$CFW_TEST_COMMON"
assert_mount_under_vm "$CFW_TEST_TARGET" "SystemOS mountpoint"
'''], env=dict(os.environ, CFW_TEST_SCRIPTS=str(ROOT / 'scripts'),
              CFW_TEST_VM=str(self.f.vm), VPHONE_PYTHON=sys.executable,
              CFW_TEST_COMMON=str(COMMON), CFW_TEST_TARGET=str(target),
              CFW_HOST_MNT=str(self.mount)), capture_output=True, text=True,
              pass_fds=(self.f.lock_fd,), timeout=20)

    def test_external_mount_bound_to_live_plan_lock_and_journal_is_accepted(self):
        result = self.check(self.target)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unbound_sibling_link_and_replaced_root_are_rejected(self):
        sibling = self.mount.parent / 'unbound-mount'
        sibling.mkdir()
        link = self.mount / 'linked'
        link.symlink_to(sibling, target_is_directory=True)
        for target in (sibling, link):
            with self.subTest(target=str(target)):
                self.assertNotEqual(self.check(target).returncode, 0)
        self.mount.rename(self.mount.with_name(self.mount.name + '-retained'))
        self.target.mkdir(parents=True)
        self.mount.chmod(0o700)
        self.assertNotEqual(self.check(self.target).returncode, 0)

    def test_wrong_vm_missing_journal_and_changed_plan_are_rejected(self):
        self.record['vm'] = str(self.mount.parent / 'another-vm')
        self.journal.write_text(json.dumps(self.record))
        self.assertNotEqual(self.check(self.target).returncode, 0)
        self.journal.unlink()
        self.assertNotEqual(self.check(self.target).returncode, 0)
        self.record['vm'] = str(self.f.vm)
        self.journal.write_text(json.dumps(self.record))
        self.f.path.write_bytes(b'changed-plan')
        self.assertNotEqual(self.check(self.target).returncode, 0)
