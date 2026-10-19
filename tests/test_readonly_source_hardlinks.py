"""Hardlinks may be read only from an explicitly qualified readonly source."""
import hashlib
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from patchers import component_effects as effects, plan_gate as gate


class ReadonlySourceHardlinkTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.file = self.root/'CodeResources'
        self.file.write_bytes(b'stable original source')
        self.alias = self.root/'linked'
        os.link(self.file, self.alias)
        self.readonly = SimpleNamespace(f_flag=os.ST_RDONLY)

    def test_default_snapshot_and_evidence_readers_still_refuse_hardlinks(self):
        with patch.object(os, 'fstatvfs', return_value=self.readonly):
            for reader in [lambda: gate.snapshot(self.file), lambda: effects.state(self.file),
                           lambda: effects.persist(self.file, self.root/'blobs')]:
                with self.subTest(reader=reader), self.assertRaises(ValueError): reader()

    def test_explicit_readonly_source_preserves_bytes_as_single_link_blob(self):
        wanted = hashlib.sha256(self.file.read_bytes()).hexdigest()
        with patch.object(os, 'fstatvfs', return_value=self.readonly):
            self.assertEqual(gate.snapshot(self.file, readonly_source=True).sha256, wanted)
            observed = effects.capture_input(self.file, self.root/'blobs', readonly_source=True)
        self.assertEqual(observed['sha256'], wanted)
        blob = effects.blob(self.root/'blobs', wanted)
        self.assertEqual(blob.stat().st_nlink, 1)
        self.assertEqual(blob.read_bytes(), self.file.read_bytes())

    def test_writable_filesystem_cannot_claim_readonly_hardlink_source(self):
        with patch.object(os, 'fstatvfs', return_value=SimpleNamespace(f_flag=0)):
            for reader in [lambda: gate.snapshot(self.file, readonly_source=True),
                           lambda: effects.capture_input(self.file, self.root/'blobs', readonly_source=True)]:
                with self.subTest(reader=reader), self.assertRaisesRegex(ValueError, 'not readonly'): reader()

    def test_remount_to_writable_during_read_refuses(self):
        with patch.object(os, 'fstatvfs', side_effect=[self.readonly, SimpleNamespace(f_flag=0)]):
            with self.assertRaisesRegex(ValueError, 'not readonly'):
                gate.snapshot(self.file, readonly_source=True)

    def test_alias_write_link_count_change_and_path_replacement_refuse(self):
        for mutation in ['alias-write', 'unlink-alias', 'replace-path']:
            case = ReadonlySourceHardlinkTests()
            case.setUp()
            try:
                if mutation == 'alias-write': action = lambda: case.alias.write_bytes(b'changed original bytes')
                elif mutation == 'unlink-alias': action = case.alias.unlink
                else:
                    def action():
                        replacement = case.root/'replacement'
                        replacement.write_bytes(case.file.read_bytes())
                        os.replace(replacement, case.file)
                with patch.object(os, 'fstatvfs', return_value=self.readonly):
                    with self.subTest(mutation=mutation), self.assertRaisesRegex(ValueError, 'changed during read'):
                        with effects.regular(case.file, readonly_source=True) as stream:
                            stream.read()
                            action()
            finally: case.doCleanups()

    def test_hardlinked_blob_is_refused_even_with_readonly_source_capture(self):
        with patch.object(os, 'fstatvfs', return_value=self.readonly):
            observed = effects.capture_input(self.file, self.root/'blobs', readonly_source=True)
            blob = self.root/'blobs'/observed['sha256']
            os.link(blob, self.root/'blob-alias')
            with self.assertRaises(ValueError): effects.blob(self.root/'blobs', observed['sha256'])
