"""Exact dependency overlays cannot authorize arbitrary checkout modifications."""
import hashlib
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class DaemonOverlayTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('daemon_overlays', ROOT / 'scripts/daemon_api_overlays.py')
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='vphone-overlay-')
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name) / 'example'
        self.repo.mkdir()
        subprocess.run(['git','init','-q',str(self.repo)], check=True)
        self.source = self.repo / 'source.m'
        self.source.write_text('old\n')
        subprocess.run(['git','-C',str(self.repo),'add','source.m'],check=True)
        subprocess.run(['git','-C',str(self.repo),'-c','user.name=fixture','-c','user.email=fixture@example.invalid','commit','-qm','base'],check=True)
        self.revision = subprocess.check_output(['git','-C',str(self.repo),'rev-parse','HEAD'],text=True).strip()
        self.patch = Path(self.temp.name) / 'fix.patch'
        self.patch.write_text('diff --git a/source.m b/source.m\n--- a/source.m\n+++ b/source.m\n@@ -1 +1 @@\n-old\n+new\n')
        digest = lambda data: hashlib.sha256(data).hexdigest()
        self.overlay = {'identity':'example','revision':self.revision,'path':'source.m',
                        'base_sha256':digest(b'old\n'),'patched_sha256':digest(b'new\n'),
                        'patch_sha256':digest(self.patch.read_bytes())}

    def apply(self):
        self.module.apply_overlay(self.repo,self.overlay,self.patch)

    def test_candidate_marker_binds_the_declared_overlay_set(self):
        overlays=[self.overlay]
        marker=self.module.marker(overlays)
        self.module.validate_marker(b'MachO'+marker.encode(),overlays)
        with self.assertRaises(ValueError):self.module.validate_marker(b'old binary',overlays)
        mutated=[dict(self.overlay,patched_sha256='b'*64)]
        with self.assertRaises(ValueError):self.module.validate_marker(marker.encode(),mutated)

    def test_apply_is_exact_and_idempotent(self):
        self.apply()
        self.assertEqual(self.source.read_bytes(),b'new\n')
        self.apply()
        self.assertEqual(self.module.validate_overlay(self.repo,self.overlay,self.patch),self.overlay)

    def test_modified_source_or_wrong_revision_is_rejected(self):
        self.source.write_text('user work\n')
        with self.assertRaises(ValueError):self.apply()
        self.assertEqual(self.source.read_text(),'user work\n')
        self.source.write_text('old\n')
        self.overlay['revision']='a'*40
        with self.assertRaises(ValueError):self.apply()
        self.assertEqual(self.source.read_text(),'old\n')

    def test_unrelated_or_untracked_modification_is_rejected(self):
        (self.repo/'extra').write_text('user work\n')
        with self.assertRaises(ValueError):self.apply()
        self.assertEqual(self.source.read_text(),'old\n')

    def test_patch_tampering_is_rejected_before_write(self):
        self.patch.write_text(self.patch.read_text().replace('+new','+other'))
        with self.assertRaises(ValueError):self.apply()
        self.assertEqual(self.source.read_text(),'old\n')

    def test_validator_rejects_absent_or_mutated_overlay(self):
        with self.assertRaises(ValueError):self.module.validate_overlay(self.repo,self.overlay,self.patch)
        self.apply()
        self.source.write_text('other\n')
        with self.assertRaises(ValueError):self.module.validate_overlay(self.repo,self.overlay,self.patch)

    def test_path_escape_is_rejected(self):
        for path in ['../outside','/outside']:
            self.overlay['path']=path
            with self.assertRaises(ValueError):self.apply()
