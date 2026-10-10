"""独立 worktree 路径与离线迁移计划；仅使用临时目录夹具。"""
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
RESEARCH = ROOT / 'research/upstream_integration_2026-10-06'
sys.path.insert(0, str(RESEARCH))
import t08_workspace as workspace
spec = importlib.util.spec_from_file_location('t08_offline', RESEARCH / 'evidence/B37/T08/offline.py')
offline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(offline)


class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='t08-workspace-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.code = self.root / 'code'
        self.code.mkdir()
        (self.code / 'Package.swift').write_text('// fixture')
        self.artifact = self.root / 'frozen'
        self.artifact.mkdir()
        self.vm = self.root / 'vms'
        self.vm.mkdir()
        self.config = self.code / 'workspace.json'
        self.raw = {'code_root': str(self.code), 'artifact_root': str(self.artifact),
                    'vm_root': str(self.vm), 'work_root': str(self.code / '.build/test')}
        self.write()

    def write(self):
        self.config.write_text(json.dumps(self.raw))

    def test_disjoint_roots_do_not_infer_vms_from_code(self):
        p = workspace.load_workspace(self.config)
        self.assertEqual(p.research_vm, self.vm / 'vm-roothide-b33-20261010')
        self.assertEqual(p.vm_binary, self.artifact / '.build/vphone-cli.app/Contents/MacOS/vphone-vm')
        self.assertFalse(p.work_root.exists())

    def test_output_outside_checkout_is_rejected(self):
        self.raw['work_root'] = str(self.artifact / 'output')
        self.write()
        with self.assertRaisesRegex(ValueError, 'remain'):
            workspace.load_workspace(self.config)

    def test_symlink_output_cannot_redirect_writes_to_primary(self):
        (self.code / '.build').symlink_to(self.vm, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'remain'):
            workspace.load_workspace(self.config)

    def test_missing_or_relative_root_is_rejected(self):
        self.raw['artifact_root'] = 'frozen'
        self.write()
        with self.assertRaisesRegex(ValueError, 'absolute'):
            workspace.load_workspace(self.config)
        del self.raw['artifact_root']
        self.write()
        with self.assertRaisesRegex(ValueError, 'explicit'):
            workspace.load_workspace(self.config)

    def test_low_disk_stops_before_output_creation(self):
        class Disk:
            f_bavail = 4 * 1024**3
            f_frsize = 1
        with patch.object(workspace.os, 'statvfs', return_value=Disk()):
            with self.assertRaisesRegex(RuntimeError, 'below 5 GiB'):
                workspace.load_workspace(self.config)
        self.assertFalse((self.code / '.build').exists())

    def test_changed_and_escaping_source_inputs_fail(self):
        f = self.code / 'input'
        f.write_bytes(b'original')
        entries = [{'path': 'input', 'sha256': hashlib.sha256(b'original').hexdigest()}]
        workspace.verify_entries(self.code, entries)
        f.write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError, 'mismatch'):
            workspace.verify_entries(self.code, entries)
        entries[0]['path'] = '../frozen/input'
        with self.assertRaisesRegex(ValueError, 'escapes'):
            workspace.verify_entries(self.code, entries)

    def test_another_vm_classification_is_rejected(self):
        p = workspace.load_workspace(self.config)
        record = {'exit_code': 0, 'report': {'classification': 'full_migration_required',
                  'vm': str(p.source_vm), 'bootstrap': {'launchd_custom_loads': ['/b']}}}
        with self.assertRaisesRegex(ValueError, 'another VM'):
            offline.migration_plan(p, record, {}, {}, {})

    def test_plan_preserves_control_camera_and_activation_limits(self):
        p = workspace.load_workspace(self.config)
        record = {'exit_code': 0, 'report': {'classification': 'full_migration_required',
                  'vm': str(p.research_vm), 'bootstrap': {'launchd_custom_loads': ['/b']}}}
        api = {'files_sha256': {'vphoned': 'a', 'vphoned.plist': 'b'}, 'vsock_port': 1339, 'pins': []}
        components = {'files_sha256': {'hook/hook': 'c'}, 'camera_header_bytes': 64,
                      'compatible_with_classic_camera': False}
        environment = {'libraries': [{'stage': 'hook/hook', 'guest': 'usr/lib/hook', 'loaded_by': 'launchd'}],
                       'load_alias': {'target': '/usr/lib/hook'}}
        result = offline.migration_plan(p, record, environment, api, components)
        self.assertFalse(result['executed'])
        self.assertFalse(result['live_disk_rechecked'])
        self.assertFalse(result['host_control']['compatibility_verified'])
        self.assertEqual(result['host_control']['classic_port'], 1337)
        self.assertFalse(result['camera']['compatible_with_classic_camera'])
        self.assertEqual(result['files'][0]['sha256'], 'c')

    def test_classic_default_never_counts_as_modern_acceptance(self):
        result = offline.default_status({'files_sha256': {'vphoned': 'classic'}},
                                        {'files_sha256': {'vphoned': 'modern'}}, {'camera_header_bytes': 64})
        self.assertEqual(result['bundled_guest'], 'classic')
        self.assertFalse(result['modern_daemon_packaged'])
        self.assertFalse(result['default_modern_acceptance'])
        self.assertFalse(result['runtime_validated'])

    def test_offline_scope_refuses_runtime_even_when_requested(self):
        for name in ('boot.py', 'client.py'):
            result = subprocess.run([sys.executable, '-B', str(RESEARCH / 'evidence/B37/T08' / name),
                                     '--workspace', str(self.config), '--run'], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('offline only', result.stderr)
        self.assertFalse((self.code / '.build').exists())
