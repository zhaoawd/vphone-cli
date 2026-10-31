import importlib.util
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
            'test', str(script_dir), str(vm), str(ROOT / 'scripts/lib/cfw_common.sh')],
            cwd='/', capture_output=True, text=True)

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
                vm = root / 'vm'; (vm / 'mnt/usr/bin').mkdir(parents=True); (vm / 'temp').mkdir()
                result = self.run_shell(scripts, vm,
                    'TEMP_DIR="$VM_DIR/temp"; MNT1="$VM_DIR/mnt"; '
                    'payload="$(cfw_guest_resources)"; cfw_stage_vphoned "$payload"; print -r -- "$payload"')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(Path(result.stdout.strip()).resolve(), payload.resolve())
                for name in ('mnt/usr/bin/vphoned', '.vphoned.signed', 'temp/vphoned'):
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
