"""Historical generation source observations must retain cryptographic checks."""
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from tests import test_undo_provenance as fixtures
from tests import test_guest_file_originals as file_fixtures
from tests import test_guest_reboot_recovery as recovery_fixtures
from tests import test_guest_file_undo as file_undo_fixtures
from patchers import cryptex_source, undo_provenance as undo
from patchers import file_originals, guest_undo
import cfw_source_identity as identity
import cfw_disk_txn as transaction


class GenerationSourceRebootTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.UndoProvenanceTests(); self.fixture.setUp(); self.addCleanup(self.fixture.doCleanups)
        original = cryptex_source.observation
        def before_reboot(path):
            row = original(path)
            if '.firmware-generations' in Path(path).parts:
                row = dict(row, device=row['device'] - 1)
            return row
        # Capture and seal the real DSC source/effect proof with a historical
        # device observation; all bytes, source manifests and inodes are real.
        with patch.object(cryptex_source, 'observation', side_effect=before_reboot):
            self.fixture.produce(); self.index = self.fixture.finalize()

    def test_complete_retained_dsc_index_rebuild_survives_only_registered_source_change(self):
        entry = self.index['entries'][0]
        binding = json.loads((self.fixture.work / 'effect-blobs' / entry['sourceBindingSHA256']).read_bytes())
        source = Path(binding['source']); actual = undo.qualify_source(self.fixture.plan, source)
        row = dict(path=str(source.relative_to(self.fixture.f.vm)),
            recordedQualification=binding['originalDSC']['generationSource'], currentQualification=actual,
            currentMetadata=identity.metadata(source.stat()))
        registration = identity.SourceBinding(self.fixture.f.vm, self.fixture.plan.context['generationID'],
            'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', [row])
        registration.verify_files(self.fixture.plan, registration.volume_uuid)
        with patch.object(identity, 'binding_for', return_value=registration):
            self.assertEqual(self.fixture.finalize(), self.index)

    def test_unregistered_historical_device_still_fails_with_original_error(self):
        with self.assertRaisesRegex(ValueError, 'Undo source no longer matches original observation'):
            self.fixture.finalize()


def historical_observation(path, original):
    row = original(path)
    return dict(row, device=row['device'] - 1) if '.firmware-generations' in Path(path).parts else row


def source_binding(plan, vm, catalog):
    rows = {}
    for source in catalog['sources']:
        path = Path(source['source'])
        rows[str(path)] = dict(path=str(path.relative_to(vm)), recordedQualification=source['generationSource'],
            currentQualification=undo.qualify_source(plan, path), currentMetadata=identity.metadata(path.stat()))
    result = identity.SourceBinding(vm, plan.context['generationID'], 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', list(rows.values()))
    result.verify_files(plan, result.volume_uuid)
    return result


class FileSourceRebootTests(unittest.TestCase):
    def test_original_file_catalog_requires_the_same_explicit_source_binding(self):
        f = file_fixtures.GuestFileOriginalTests(); f.setUp(); self.addCleanup(f.doCleanups)
        observation = cryptex_source.observation
        with patch.object(cryptex_source, 'observation', side_effect=lambda path: historical_observation(path, observation)):
            catalog = f.catalog()
        with self.assertRaisesRegex(ValueError, 'File original generation source changed'):
            file_originals.load(f.f.plan, f.store)
        binding = source_binding(f.f.plan, f.f.f.vm, catalog)
        with patch.object(identity, 'binding_for', return_value=binding):
            self.assertEqual(file_originals.load(f.f.plan, f.store), catalog)


class MixedSourceRecoveryTests(unittest.TestCase):
    def test_retained_dsc_and_file_undo_can_recover_without_rewriting_old_source_observations(self):
        observation = cryptex_source.observation
        produce = file_undo_fixtures.GuestFileUndoTests.produce
        def mixed_produce(case, *args, **kwargs):
            result = produce(case, *args, **kwargs)
            case.o.f.produce()  # Retain an independently sourced DSC effect beside the selected file Undo.
            return result
        f = recovery_fixtures.GuestRebootRecoveryTests()
        with patch.object(cryptex_source, 'observation', side_effect=lambda path: historical_observation(path, observation)), \
             patch.object(file_undo_fixtures.GuestFileUndoTests, 'produce', new=mixed_produce):
            f.setUp()
        self.addCleanup(f.doCleanups)
        parent = transaction.committed_guest_evidence(f.f.vm)
        plan = f.f.fixture.f.plan
        catalog = json.loads((parent[0] / file_originals.FILENAME).read_bytes())
        binding = source_binding(plan, f.f.vm, catalog)
        with patch.object(identity, 'binding_for', return_value=binding):
            preview = guest_undo.preview(f.f.vm, plan.context['generationID'],
                [f.f.fixture.declaration], _committed=parent)
            self.assertEqual(len(preview['entries']), 1)
            # Use the actual recovered transaction, final reader, seal and publication.
            f.recover(); f.f.args = f.args; f.f.seal(); transaction.publish(f.args); transaction.finish(f.args)
            report = transaction.inspect_guest(f.f.vm)
            self.assertEqual(report['componentReceipts']['removedDeclarations'], [f.f.fixture.declaration])
            self.assertIn('dyld-cfw-camera', report['componentReceipts']['appliedDeclarations'])
        self.assertEqual(f.before, {str(p.relative_to(f.source)): undo.effects.digest(p)
            for p in f.source.rglob('*') if p.is_file()})


if __name__ == '__main__':
    unittest.main()
