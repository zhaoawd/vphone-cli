import importlib.util
import json
import os
import sys
from tests import test_patch_plan_gate as frozen_tests
from patchers import guest_write
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('guest_payloads', ROOT / 'scripts/check_guest_payloads.py')
guest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guest)


class GuestPayloadTests(unittest.TestCase):
    def test_metadata_accepts_ios_arm64_and_matching_entitlements(self):
        guest.validate_metadata('arm64\n', ' platform IOS\n minos 15.0\n', '_malloc', {'test': True}, {'test': True})

    def test_metadata_rejects_wrong_platform_target_architecture_import_and_policy(self):
        cases = [
            ('arm64 x86_64', ' platform IOS\n minos 15.0\n', '', {'test': True}),
            ('arm64', ' platform MACOS\n minos 15.0\n', '', {'test': True}),
            ('arm64', ' platform IOS\n minos 26.4\n', '', {'test': True}),
            ('arm64', ' platform IOS\n minos 15.0\n', ' U _swift_initBorrow\n', {'test': True}),
            ('arm64', ' platform IOS\n minos 15.0\n', '', {'other': True}),
        ]
        for arch, build, symbols, entitlements in cases:
            with self.subTest(arch=arch, build=build, symbols=symbols, entitlements=entitlements):
                with self.assertRaises(ValueError):
                    guest.validate_metadata(arch, build, symbols, entitlements, {'test': True})

    def test_missing_or_linked_payload_rejected_before_tools(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaisesRegex(ValueError, 'Missing regular'):
                guest.inspect(root)
            (root / 'target').write_bytes(b'fixture')
            (root / 'vphoned').symlink_to(root / 'target')
            with self.assertRaisesRegex(ValueError, 'Missing regular'):
                guest.inspect(root)

    def run_shell(self, script_dir, vm, body):
        return subprocess.run(['/bin/zsh', '-c',
            'set -euo pipefail; SCRIPT_DIR="$1"; VM_DIR="$2"; source "$3"; ' + body,
            'test', str(script_dir), str(vm), str(ROOT / 'scripts/lib/cfw_common.sh'), str(ROOT / 'scripts')],
            cwd='/', capture_output=True, text=True,
            pass_fds=(int(os.environ['VPHONE_VM_LOCK_FD']),) if 'VPHONE_VM_LOCK_FD' in os.environ else ())

    def test_installer_uses_presigned_payload_from_app_and_development_tree(self):
        for app in (False, True):
            with self.subTest(app=app), tempfile.TemporaryDirectory(prefix='guest layout ') as tmp:
                root = Path(tmp)
                base = root / 'Test.app/Contents/Resources' if app else root / 'dev'
                scripts = base / 'scripts'; scripts.mkdir(parents=True)
                payload = base / ('guest-resources' if app else '.build/guest')
                payload.mkdir(parents=True)
                content = b'presigned fixture\x00unchanged'
                (payload / 'vphoned').write_bytes(content); (payload / 'vphoned').chmod(0o755)
                (payload / 'vphoned.plist').write_text('plist fixture')
                fixture = frozen_tests.FrozenGateTests(); fixture.setUp()
                self.addCleanup(fixture.doCleanups)
                _, digest = guest_write.target_table()
                fixture.entries.append(dict(id='system-vphoned-boot-install', disposition='guestUncovered',
                    recordRules=[dict(literal='guest-target-map-v1:'+digest+':system-vphoned-boot-install', hexadecimalOffsetSuffix=False)]))
                fixture.publish()
                os.environ.update(VPHONE_FROZEN_PLAN_SHA256=fixture.digest, VPHONE_FROZEN_CONTEXT=json.dumps(fixture.context), PYTHON3=sys.executable)
                vm = fixture.vm
                (fixture.mount / 'mnt1/usr/bin').mkdir(parents=True)
                result = self.run_shell(scripts, vm,
                    'TEMP_DIR="$VM_DIR/.cfw_temp"; MNT1="$CFW_HOST_MNT/mnt1"; '
                    'payload="$(cfw_guest_resources)"; SCRIPT_DIR="$4"; cfw_stage_vphoned "$payload"; print -r -- "$payload"')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(Path(result.stdout.strip()).resolve(), payload.resolve())
                for name in ('.cfw_mount.test/mnt1/usr/bin/vphoned', '.vphoned.signed', '.cfw_temp/vphoned'):
                    self.assertEqual((vm / name).read_bytes(), content)
                self.assertEqual((payload / 'vphoned').read_bytes(), content)

    def test_installer_does_not_fall_back_to_legacy_daemon(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); scripts = root / 'App.app/Contents/Resources/scripts'
            scripts.mkdir(parents=True)
            legacy = scripts / 'vphoned'; legacy.mkdir()
            (legacy / 'vphoned').write_bytes(b'old daemon')
            result = self.run_shell(scripts, root, 'cfw_guest_resources')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Missing guest resources', result.stderr)

    def test_installer_rejects_symlink_payload(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); scripts = root / 'scripts'; scripts.mkdir()
            payload = root / '.build/guest'; payload.mkdir(parents=True)
            external = root / 'external'; external.write_bytes(b'fixture'); external.chmod(0o755)
            (payload / 'vphoned').symlink_to(external)
            (payload / 'vphoned.plist').write_text('fixture')
            result = self.run_shell(scripts, root, 'cfw_guest_resources')
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('regular guest payload', result.stderr)
