"""Committed DSC undo candidates use the actual producer and disk journal.

APFS/source mounts and the patch algorithm use the existing source-proof
fixture. Evidence, source qualification, page verification and swap are real.
"""
import contextlib
import io
import hashlib
import json
import os
import subprocess
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from tests import test_undo_provenance as fixtures
from patchers import cfw, component_effects as effects, plan_gate as gate, guest_write
import cfw_disk_txn as txn


class GuestUndoTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixtures.UndoProvenanceTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        f = self.fixture
        self.vm, self.work = f.f.vm, f.work
        self.generation = f.plan.context['generationID']
        self.fd = os.open(self.vm / 'Disk.img', os.O_RDONLY)
        self.addCleanup(os.close, self.fd)
        record = txn.load_record(self.work)
        record.update(version=3, guestEvidenceRequired=True, checks=[], failure=None)
        record['original']['sample'] = txn.sample_digest(self.fd, record['original']['size'])
        txn.save_record(self.work, record)
        self.args = SimpleNamespace(vm=self.vm, work=self.work, fd=self.fd,
            owner_pid=os.getpid(), exit_code=0, retain_staged=False)
        self.holders = patch.object(txn, 'holders', return_value=[])
        self.holders.start(); self.addCleanup(self.holders.stop)

    def commit(self, second=False):
        f = self.fixture
        if isinstance(second, str):
            _, digest = guest_write.target_table()
            f.f.entries.append(dict(id=second, disposition='guestUncovered', recordRules=[
                dict(literal='guest-target-map-v1:'+digest+':'+second, hexadecimalOffsetSuffix=False)]))
            f.f.publish()
            os.environ.update(VPHONE_FROZEN_PLAN_SHA256=f.f.digest, VPHONE_FROZEN_CONTEXT=json.dumps(f.f.context))
            f.plan = f.f.load()
        f.produce()
        if second:
            def change(*, guest_environment):
                self.assertEqual(guest_environment, f.f.context['guestEnvironment'])
                data = bytearray(f.dsc.read_bytes())
                data[512:519] = b'second!'
                data[4168:4200] = hashlib.sha256(data[:4096]).digest()
                f.dsc.write_bytes(data)
            command = 'patch-dsc-maxslide' if isinstance(second, str) else 'patch-camera-dsc'
            with patch.object(fixtures.sys, 'argv', ['cfw.py', command, str(f.dsc.parent), str(f.dsc)]), \
                 patch.object(cfw, '_dispatch', side_effect=change):
                cfw.main()
        f.finalize()
        txn.seal(self.args); txn.publish(self.args)
        with contextlib.redirect_stdout(io.StringIO()): txn.finish(self.args)
        self.archive = next((self.vm / '.cfw-history').iterdir())

    def preview(self, declarations=('dyld-cfw-camera',)):
        return txn.preview_guest_undo(self.vm, self.generation, declarations)

    def test_committed_original_is_returned_after_all_operations_are_reversed(self):
        self.commit(second=True)
        before = effects.digest(self.vm / 'Disk.img')
        result = self.preview()
        self.assertEqual(result['state'], 'undo-preview')
        self.assertFalse(result['writeAuthorized']); self.assertFalse(result['runtimeValidated'])
        self.assertEqual(result['entries'][0]['restoredSHA256'], gate.sha(fixtures.cache(b'initial')))
        self.assertEqual(len(result['entries'][0]['reversedOperations']), 2)
        self.assertEqual(result['entries'][0]['verifiedCodePages'], 1)
        self.assertEqual(effects.digest(self.vm / 'Disk.img'), before)

    def test_changed_desired_does_not_erase_prior_committed_undo_evidence(self):
        self.commit()
        self.fixture.f.path.write_bytes(b'new desired selection')
        self.assertEqual(self.preview()['state'], 'undo-preview')

    def test_removing_tail_preserves_prior_patch_but_removing_middle_refuses(self):
        self.commit(second='dyld-boot-maxslide')
        with self.assertRaisesRegex(txn.Refused, 'retains later operations'):
            self.preview()
        result = self.preview(['dyld-boot-maxslide'])
        entry = result['entries'][0]
        self.assertEqual(entry['restoredSHA256'], gate.sha(fixtures.cache(b'changed')))
        self.assertFalse(entry['restoresFirstOriginal'])
        self.assertEqual(entry['remainingDeclarations'], ['dyld-cfw-camera'])
        self.assertEqual(self.preview(['dyld-cfw-camera', 'dyld-boot-maxslide'])['entries'][0]['restoredSHA256'],
                         gate.sha(fixtures.cache(b'initial')))

    def test_original_with_inconsistent_code_page_is_not_an_undo_candidate(self):
        source = self.fixture.source_dsc
        data = bytearray(source.read_bytes()); data[500] ^= 1; source.write_bytes(data)
        self.commit()
        with self.assertRaisesRegex(txn.Refused, 'page hash differs'): self.preview()

    def test_actual_cli_produces_read_only_json_and_requires_the_vm_lock(self):
        self.commit()
        command = [sys.executable, str(fixtures.plan_tests.ROOT / 'scripts/cfw_disk_txn.py'), 'preview-undo',
                   '--generation', self.generation, '--declaration', 'dyld-cfw-camera', str(self.vm)]
        result = subprocess.run(command, pass_fds=(self.fixture.f.lock_fd,), capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)['state'], 'undo-preview')
        refused = subprocess.run(command, capture_output=True)
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn(b'VM lock', refused.stderr)

    def test_cli_selection_options_are_not_accepted_for_mutation_commands(self):
        with self.assertRaises(SystemExit) as missing:
            txn.main(['preview-undo', str(self.vm)])
        self.assertEqual(missing.exception.code, 2)
        with self.assertRaises(SystemExit) as misplaced:
            txn.main(['recover', '--generation', self.generation, str(self.vm), str(self.work)])
        self.assertEqual(misplaced.exception.code, 2)

    def test_locked_journal_inspection_refuses_unfinished_publication(self):
        f = self.fixture
        f.produce(); f.finalize(); txn.seal(self.args); txn.publish(self.args)
        with self.assertRaisesRegex(txn.Refused, 'finish/recovery'): self.preview()
        with contextlib.redirect_stdout(io.StringIO()): txn.finish(self.args)
        self.assertEqual(self.preview()['state'], 'undo-preview')

    def test_old_schema_and_non_dsc_declaration_do_not_gain_undo(self):
        self.commit()
        with self.assertRaisesRegex(txn.Refused, 'no qualified Undo'):
            self.preview(['system-cryptex-boot-install'])
        record = txn.load_record(self.archive)
        record['version'] = 2
        record.pop('guestEvidenceRequired'); record.pop('guestEvidenceSHA256')
        txn.save_record(self.archive, record)
        with self.assertRaisesRegex(txn.Refused, 'no committed guest checkpoint'):
            self.preview()

    def test_missing_original_blob_and_archive_index_changes_refuse(self):
        self.commit()
        index = json.loads((self.archive / 'guest-undo-provenance.json').read_bytes())
        original = self.archive / 'effect-blobs' / index['entries'][0]['originalSHA256']
        data = original.read_bytes(); original.unlink()
        with self.assertRaises(txn.Refused): self.preview()
        original.write_bytes(data)
        (self.archive / 'guest-undo-provenance.json').write_bytes(b'changed index')
        with self.assertRaises(txn.Refused): self.preview()

    def test_wrong_generation_missing_evidence_and_unknown_declaration_refuse(self):
        with self.assertRaises(txn.Refused): self.preview()
        self.commit()
        with self.assertRaises(txn.Refused): txn.preview_guest_undo(self.vm, '0'*64, ['dyld-cfw-camera'])
        for declarations in ([], ['unknown'], ['dyld-cfw-camera', 'dyld-cfw-camera']):
            with self.assertRaises(txn.Refused): self.preview(declarations)

    def test_changed_disk_or_generation_original_refuses(self):
        self.commit()
        disk = self.vm / 'Disk.img'; saved = disk.read_bytes()
        disk.write_bytes(b'changed image')
        with self.assertRaises(txn.Refused): self.preview()
        disk.write_bytes(saved)
        # Restore the checkpoint identity so the source qualification is tested.
        checkpoint = json.loads((self.archive / 'guest-publication.json').read_bytes())
        os.utime(disk, ns=(disk.stat().st_atime_ns, checkpoint['imageIdentity']['mtime_ns']))
        self.fixture.original.write_bytes(b'changed generation original')
        with self.assertRaisesRegex(txn.Refused, 'original tree'): self.preview()

    def test_preview_rechecks_sources_after_candidate_verification(self):
        self.commit()
        from patchers import guest_undo
        actual = guest_undo.verify_code_pages
        def changed(path):
            result = actual(path)
            self.fixture.original.write_bytes(b'changed during preview')
            return result
        with patch.object(guest_undo, 'verify_code_pages', side_effect=changed):
            with self.assertRaises(txn.Refused): self.preview()


if __name__ == '__main__': unittest.main()
