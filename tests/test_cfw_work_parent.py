"""Private CFW scratch roots; staging and journals remain on the VM volume."""
import errno
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import cfw_disk_txn as txn
from patchers import plan_gate


class WorkParentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.vm = self.root / 'vm'
        self.vm.mkdir()
        self.work = self.vm / '.cfw_disk.test'
        self.work.mkdir(mode=0o700)
        self.parent = self.root / 'scratch space'
        self.parent.mkdir(mode=0o700)

    def test_private_and_sticky_parents_create_unique_private_roots(self):
        for mode in (0o700, 0o1777):
            self.parent.chmod(mode)
            first = txn.make_mount_directory(self.parent)
            second = txn.make_mount_directory(self.parent)
            self.assertNotEqual(first, second)
            self.assertEqual(first.parent, self.parent)
            self.assertEqual(stat.S_IMODE(first.stat().st_mode), 0o700)

    def test_shared_parent_and_symlink_are_refused(self):
        self.parent.chmod(0o755)
        with self.assertRaises(txn.Refused):
            txn.make_mount_directory(self.parent)
        self.parent.chmod(0o700)
        linked = self.root / 'linked'
        linked.symlink_to(self.parent)
        with self.assertRaises(txn.Refused):
            txn.make_mount_directory(linked)

    def test_external_mount_is_bound_to_journal_and_replacement_refuses(self):
        mount = txn.make_mount_directory(self.parent)
        record = {'version': 2, 'provenanceMode': 'required', 'vm': str(self.vm), 'mountRoot': txn.mount_identity(mount)}
        (self.work / 'transaction.json').write_text(json.dumps(record))
        plan = SimpleNamespace(context={'vmDirectory': str(self.vm)})
        env = {'VPHONE_GUEST_EVIDENCE': str(self.work / 'guest-changes.jsonl'), 'CFW_HOST_MNT': str(mount)}
        with patch.dict(os.environ, env):
            self.assertEqual(plan_gate.private_path(plan, mount / 'mnt1/file'), mount / 'mnt1/file')
            with self.assertRaises(ValueError):
                plan_gate.private_path(plan, self.parent / 'unbound')
            mount.rename(mount.with_name(mount.name + '-retained'))
            mount.mkdir(mode=0o700)
            with self.assertRaises(ValueError):
                plan_gate.private_path(plan, mount / 'mnt1/file')
    def test_space_check_deduplicates_volumes_and_refuses_unknown_or_low_space(self):
        volume = SimpleNamespace(f_bavail=100, f_frsize=1024)
        with patch.object(txn.os, 'statvfs', return_value=volume) as query:
            txn.require_free_space([self.vm, self.parent], minimum=1024)
            self.assertEqual(query.call_count, 1)
            with self.assertRaises(txn.Refused):
                txn.require_free_space([self.vm], minimum=102401)
        with patch.object(txn.os, 'statvfs', side_effect=OSError(errno.EIO, 'unavailable')):
            with self.assertRaises(txn.Refused):
                txn.require_free_space([self.vm], minimum=1)

    def test_staging_stays_inside_vm(self):
        self.assertIn("args.work.parent != args.vm", (ROOT / 'scripts/cfw_disk_txn.py').read_text())
        script = (ROOT / 'scripts/cfw_install_host.sh').read_text()
        self.assertIn('mktemp -d "$VM_DIR/.cfw_disk.XXXXXXXX"', script)
        self.assertIn('MODE_ARGS+=(--work-parent "$WORK_PARENT")', script)
