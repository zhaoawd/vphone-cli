import importlib.util
import hashlib
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('guest_components', ROOT / 'scripts/check_guest_components.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class GuestComponentsTests(unittest.TestCase):
    def test_source_tampering_and_symlinks_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / 'component.c'
            path.write_bytes(b'fixed source')
            pins = {'files': [{'local': path.name, 'upstream_sha256': hashlib.sha256(path.read_bytes()).hexdigest()}]}
            module.check_sources(pins, root)
            path.write_bytes(b'changed source')
            with self.assertRaises(ValueError):
                module.check_sources(pins, root)
            path.unlink()
            other = root / 'other.c'
            other.write_bytes(b'fixed source')
            path.symlink_to(other)
            with self.assertRaises(ValueError):
                module.check_sources(pins, root)

    def test_incomplete_stage_is_rejected_before_running_tools(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError, 'regular file'):
                module.inspect(Path(tmp), {})

    def test_stage_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'link'
            path.symlink_to(Path(tmp))
            with self.assertRaisesRegex(ValueError, 'real directory'):
                module.inspect(path, {})
