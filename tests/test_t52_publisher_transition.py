"""Exercise publisher rename/rollback on real files without any guest access."""
import base64
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('publisher_transition', ROOT / 'research/upstream_integration_2026-10-15/tools/deploy_t52_consumer_publisher.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class PublisherTransitionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cache = self.root / 'vphoned'; self.cache.write_bytes(b'old'); self.cache.chmod(0o755)
        self.candidate = self.root / 'candidate'; self.candidate.write_bytes(b'new')
        self.failure = None
        self.renames = 0

    def rpc(self, method, params):
        if method == 'files.list':
            return {'entries': [{'name': p.name, 'type': 'file', 'is_symlink': p.is_symlink(),
                                  'perm': oct(p.stat().st_mode & 0o777)[2:]} for p in self.root.iterdir()]}
        self.assertEqual(method, 'files.rename')
        self.renames += 1
        if self.failure == ('before', self.renames): raise OSError('rename failed')
        source, target = [self.root / Path(params[key]).name for key in ('from', 'to')]
        if target.exists(): raise FileExistsError(target)
        source.rename(target)
        if self.failure == ('after', self.renames): raise OSError('reply lost')
        return {'moved': True}

    def call(self, payload):
        path = self.root / Path(payload['path']).name
        if payload['t'] == 'file_get': return {'data': base64.b64encode(path.read_bytes()).decode()}
        self.assertEqual(payload['t'], 'file_put')
        self.assertFalse(path.exists())
        shutil.copyfile(payload['load'], path); path.chmod(0o755)
        if self.failure == 'corrupt-stage': path.write_bytes(b'incomplete')
        return {'ok': True}

    def apply(self):
        return m.transition(self.call, self.rpc, self.candidate, before=m.sha(b'old'), after=m.sha(b'new'), nonce='0' * 32)

    def test_success_preserves_old_executable_under_unique_name(self):
        result = self.apply()
        self.assertEqual(self.cache.read_bytes(), b'new')
        self.assertEqual((self.root / Path(result['retained']).name).read_bytes(), b'old')
        self.assertFalse(result['responseRecovered'])

    def test_failed_and_uncertain_renames_restore_original_or_verify_published_bytes(self):
        for phase in [('before', 1), ('after', 1), ('before', 2), ('after', 2)]:
            with self.subTest(phase=phase):
                # Each case uses an isolated transaction and real filesystem.
                with tempfile.TemporaryDirectory() as directory:
                    prior = self.root; self.root = Path(directory)
                    self.cache = self.root / 'vphoned'; self.cache.write_bytes(b'old'); self.cache.chmod(0o755)
                    self.candidate = self.root / 'candidate'; self.candidate.write_bytes(b'new')
                    self.failure = phase; self.renames = 0
                    if phase == ('after', 2):
                        result = self.apply(); self.assertTrue(result['responseRecovered'])
                        self.assertEqual(self.cache.read_bytes(), b'new')
                        self.assertEqual((self.root / Path(result['retained']).name).read_bytes(), b'old')
                    else:
                        with self.assertRaises(OSError): self.apply()
                        self.assertEqual(self.cache.read_bytes(), b'old')
                    self.root = prior

    def test_changed_inputs_conflicting_names_and_bad_stage_never_replace_cache(self):
        self.cache.write_bytes(b'foreign')
        with self.assertRaises(ValueError): self.apply()
        self.assertEqual(self.cache.read_bytes(), b'foreign')
        self.cache.write_bytes(b'old')
        self.failure = 'corrupt-stage'
        with self.assertRaises(ValueError): self.apply()
        self.assertEqual(self.cache.read_bytes(), b'old')
        with self.assertRaisesRegex(ValueError, 'Conflicting'): self.apply()


if __name__ == '__main__': unittest.main()
