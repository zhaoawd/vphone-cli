"""Environment publication must preserve the selected generation on failed upgrades."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / 'scripts'
sys.path.insert(0, str(SCRIPTS))
import python_environment as manager


class EnvironmentPublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.target = self.root / 'venv'
        self.old = self.root / 'old-generation'
        self.old.mkdir()
        (self.old / 'sentinel').write_text('old')
        self.target.symlink_to(self.old)

    def test_publish_preserves_old_generation_and_candidate_paths(self):
        candidate = self.root / 'candidate'
        candidate.mkdir()
        manager.publish(self.target, candidate)
        self.assertEqual(self.target.resolve(), candidate)
        self.assertEqual((self.old / 'sentinel').read_text(), 'old')

    def test_failed_publication_restores_real_legacy_directory(self):
        self.target.unlink()
        self.target.mkdir()
        (self.target / 'sentinel').write_text('legacy')
        candidate = self.root / 'candidate'
        candidate.mkdir()
        with patch.object(manager.os, 'replace', side_effect=OSError('publication failed')):
            with self.assertRaises(OSError):
                manager.publish(self.target, candidate)
        self.assertEqual((self.target / 'sentinel').read_text(), 'legacy')
        self.assertFalse(self.target.is_symlink())

    def test_compatible_environment_does_not_install(self):
        with patch.object(manager, 'lock_path', return_value=self.root / 'lock'), \
             patch.object(manager, 'check', return_value={'ok': True}), \
             patch.object(manager, 'run') as run:
            self.assertEqual(manager.ensure(self.root, self.target), self.target / 'bin/python3')
            run.assert_not_called()

    def test_install_failure_keeps_previous_selection(self):
        lock = self.root / 'lock'
        lock.write_text('pip==1 \\\n    --hash=sha256:abc\n')
        with patch.object(manager, 'lock_path', return_value=lock), \
             patch.object(manager, 'run', side_effect=[None, subprocess.CalledProcessError(1, 'pip')]):
            with self.assertRaises(subprocess.CalledProcessError):
                manager.ensure(self.root, self.target, force=True)
        self.assertEqual(self.target.resolve(), self.old)
        self.assertEqual(list((self.root / '.venv.generations').iterdir()), [])

    def test_rejects_unrelated_directory_before_any_install(self):
        self.target.unlink()
        self.target.mkdir()
        (self.target / 'document').write_text('retain')
        with patch.object(manager, 'lock_path', return_value=self.root / 'lock'):
            with self.assertRaisesRegex(RuntimeError, 'not a recognized'):
                manager.ensure(self.root, self.target, force=True)
        self.assertEqual((self.target / 'document').read_text(), 'retain')
