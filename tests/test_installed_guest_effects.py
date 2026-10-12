"""Installed effect inspection does not manufacture a guest producer receipt."""
import json
import unittest
from tests import test_patch_plan_gate as fixtures
from patchers import guest_write
import verify_installed_guest_effects as installed

class InstalledGuestEffectsTests(unittest.TestCase):
    setUp = fixtures.FrozenGateTests.setUp
    publish = fixtures.FrozenGateTests.publish
    load = fixtures.FrozenGateTests.load

    def fixture(self, trusted=True):
        resources = self.root/'Resources'; resources.mkdir()
        source = (resources if trusted else self.stage)/'seputil'
        source.write_bytes(b'verified-source')
        target = self.mount/'mnt1/usr/libexec/seputil'; target.parent.mkdir(parents=True)
        guest_write.run(self.load(), ['cp', str(source), str(target)])
        return resources, source, target

    def inspect(self, resources):
        return installed.verify(self.load(), self.evidence, self.evidence.parent/'effect-blobs',
                                {'system': self.mount/'mnt1'}, resources)

    def test_actual_bundle_source_and_final_output_are_both_read(self):
        resources, source, target = self.fixture()
        result = self.inspect(resources)
        self.assertEqual(result['state'], 'inspected-unqualified-producer')
        self.assertEqual(result['outputs'][0]['target'], 'system:/usr/libexec/seputil')
        self.assertNotIn('origin', result)
        source.write_bytes(b'substituted-input')
        with self.assertRaises(ValueError): self.inspect(resources)
        source.write_bytes(b'verified-source');target.write_bytes(b'overwritten-output')
        with self.assertRaises(ValueError): self.inspect(resources)

    def test_unrelated_copy_source_is_not_a_bundle_input(self):
        resources, _, _ = self.fixture(trusted=False)
        with self.assertRaises(ValueError): self.inspect(resources)

    def test_missing_legacy_or_changed_operation_evidence_refused(self):
        resources, _, _ = self.fixture()
        rows = [json.loads(line) for line in self.evidence.read_bytes().splitlines()]
        del rows[0]['effect'];self.evidence.write_text(json.dumps(rows[0])+'\n')
        with self.assertRaises(ValueError): self.inspect(resources)
        self.evidence.write_bytes(b'')
        with self.assertRaises(ValueError): self.inspect(resources)

if __name__ == '__main__': unittest.main()
