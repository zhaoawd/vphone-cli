"""Incomplete, empty and external bundle assets must fail distribution checks."""
import plistlib
import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('check_bundle', Path(__file__).resolve().parents[1] / 'scripts/check_bundle.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class BundleValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.bundle = Path(self.temp.name) / 'test.app'
        self.resources = self.bundle / 'Contents/Resources'
        for name in module.REQUIRED:
            path = self.resources / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'fixture')
            path.chmod(0o755)
        for name in ('vphone-cli', 'vphone-vm', 'ldid'):
            path = self.bundle / 'Contents/MacOS' / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'fixture')
            path.chmod(0o755)

    def test_complete_layout(self):
        self.assertEqual(module.check_resources(self.bundle), self.resources)

    def test_missing_real_certificate_path(self):
        (self.resources / 'scripts/vphoned/signcert.p12').unlink()
        (self.resources / 'signcert.p12').write_bytes(b'wrong path')
        with self.assertRaisesRegex(ValueError, 'signcert'):
            module.check_resources(self.bundle)

    def test_empty_archive(self):
        (self.resources / 'scripts/resources/cfw_input.tar.zst').write_bytes(b'')
        with self.assertRaisesRegex(ValueError, 'empty'):
            module.check_resources(self.bundle)

    def test_resource_symlink_outside_bundle(self):
        external = Path(self.temp.name) / 'external'
        external.write_bytes(b'not portable')
        path = self.resources / 'requirements.txt'
        path.unlink()
        path.symlink_to(external)
        with self.assertRaisesRegex(ValueError, 'escapes'):
            module.check_resources(self.bundle)

    def test_tool_without_execute_permission(self):
        (self.resources / '.tools/bin/trustcache').chmod(0o644)
        with self.assertRaisesRegex(ValueError, 'not executable'):
            module.check_resources(self.bundle)

    def test_kernel_update_protocol_requires_exact_marker(self):
        info = self.bundle / 'Contents/Info.plist'
        for value in ('', 'vphone.kernel-update.v0', 'vphone.kernel-update.v1'):
            info.write_bytes(plistlib.dumps({'VPhoneKernelUpdateProtocol': value}))
            if value == 'vphone.kernel-update.v1':
                module.check_kernel_update_protocol(self.bundle)
            else:
                with self.assertRaisesRegex(ValueError, 'kernel update protocol'):
                    module.check_kernel_update_protocol(self.bundle)

    def test_kernel_rollback_protocol_requires_exact_marker(self):
        info = self.bundle / 'Contents/Info.plist'
        for value in ('', 'vphone.kernel-rollback.v0', 'vphone.kernel-rollback.v1'):
            info.write_bytes(plistlib.dumps({'VPhoneKernelRollbackProtocol': value}))
            if value == 'vphone.kernel-rollback.v1':
                module.check_kernel_rollback_protocol(self.bundle)
            else:
                with self.assertRaisesRegex(ValueError, 'kernel rollback protocol'):
                    module.check_kernel_rollback_protocol(self.bundle)
