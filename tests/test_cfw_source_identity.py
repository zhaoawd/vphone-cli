"""Source continuity grants only explicit manifest-backed file associations."""
import copy
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch

from tests import test_undo_provenance as fixtures
from patchers import undo_provenance as undo
import cfw_source_identity as identity


class SourceIdentityTests(unittest.TestCase):
    def setUp(self):
        self.f = fixtures.UndoProvenanceTests(); self.f.setUp(); self.addCleanup(self.f.doCleanups)
        self.plan = self.f.plan; self.vm = self.f.f.vm; self.path = self.f.original
        self.actual = undo.qualify_source(self.plan, self.path)
        self.old = copy.deepcopy(self.actual); self.old['source']['device'] -= 1
        self.member = dict(path=str(self.path.relative_to(self.vm)), recordedQualification=self.old,
            currentQualification=self.actual, currentMetadata=identity.metadata(self.path.stat()))
        self.volume = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'

    def binding(self, member=None):
        return identity.SourceBinding(self.vm, self.plan.context['generationID'], self.volume,
                                      [self.member if member is None else member])

    def test_verified_binding_accepts_only_the_registered_historical_observation(self):
        binding = self.binding(); self.assertFalse(binding.matches(self.path, self.actual, self.old))
        binding.verify_files(self.plan, self.volume)
        with patch.object(identity, 'binding_for', return_value=binding):
            self.assertTrue(identity.matches_qualified_source(self.plan, self.path, self.actual, self.old))
            for key, value in [('inode', 999), ('size', 999), ('sha256', 'e'*64), ('device', 999)]:
                changed = copy.deepcopy(self.old); changed['source'][key] = value
                with self.subTest(key=key):
                    self.assertFalse(identity.matches_qualified_source(self.plan, self.path, self.actual, changed))

    def test_missing_registration_and_another_manifest_are_refused(self):
        self.assertFalse(identity.matches_qualified_source(self.plan, self.path, self.actual, self.old))
        binding = self.binding(); binding.verify_files(self.plan, self.volume)
        with patch.object(identity, 'binding_for', return_value=binding):
            for key, value in [('manifestSHA256', 'b'*64), ('originalTreeSHA256', 'c'*64), ('originalName', 'different')]:
                old = copy.deepcopy(self.old); old[key] = value
                with self.subTest(key=key): self.assertFalse(identity.matches_qualified_source(self.plan, self.path, self.actual, old))

    def test_wrong_volume_or_generation_cannot_qualify_the_binding(self):
        with self.assertRaises(ValueError): self.binding().verify_files(self.plan, 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb')
        bad = self.binding(); bad.generation = 'b'*64
        with self.assertRaises(ValueError): bad.verify_files(self.plan, self.volume)

    def test_replaced_inode_or_changed_metadata_invalidates_a_verified_binding(self):
        binding = self.binding(); binding.verify_files(self.plan, self.volume)
        before = self.path.stat(); self.path.chmod(0o600 if before.st_mode & 0o777 != 0o600 else 0o644)
        self.assertFalse(binding.matches(self.path, self.actual, self.old))
        replacement = self.path.with_name('replacement'); replacement.write_bytes(self.path.read_bytes())
        os.replace(replacement, self.path)
        self.assertFalse(binding.matches(self.path, self.actual, self.old))

    def test_changed_bytes_with_restored_mtime_cannot_requalify(self):
        binding = self.binding(); before = self.path.stat()
        self.path.write_bytes(b'X'*before.st_size); os.utime(self.path, ns=(before.st_atime_ns, before.st_mtime_ns))
        with self.assertRaises(ValueError): binding.verify_files(self.plan, self.volume)
        # Even a newly captured stat tuple cannot legitimize changed source bytes.
        row = copy.deepcopy(self.member); row['currentMetadata'] = identity.metadata(self.path.stat())
        with self.assertRaises(ValueError): self.binding(row).verify_files(self.plan, self.volume)

    def test_namespace_duplicate_or_invented_historical_metadata_is_refused(self):
        for name in ('../other', 'Disk.img', str(self.path), '.firmware-generations/'+'b'*64+'/originals/iPhone_Restore/SystemOS.dmg'):
            row = copy.deepcopy(self.member); row['path'] = name
            with self.subTest(path=name), self.assertRaises(ValueError): self.binding(row)
        with self.assertRaises(ValueError):
            identity.SourceBinding(self.vm, self.plan.context['generationID'], self.volume, [self.member, self.member])
        row = copy.deepcopy(self.member); row['recordedQualification']['source']['mtime_ns'] = 0
        with self.assertRaises(ValueError): self.binding(row)

    def test_user_owned_carrier_and_nonroot_writer_never_grant_an_association(self):
        carrier = self.vm / identity.REGISTRATION; carrier.write_text('{}'); carrier.chmod(0o444)
        with self.assertRaises(ValueError): identity.registered_bytes(carrier)
        with patch.object(identity.os, 'geteuid', return_value=501), self.assertRaises(ValueError):
            identity.register_sources(self.plan, 'a'*64, [self.member])
        self.assertEqual(carrier.read_text(), '{}')


if __name__ == '__main__':
    unittest.main()
