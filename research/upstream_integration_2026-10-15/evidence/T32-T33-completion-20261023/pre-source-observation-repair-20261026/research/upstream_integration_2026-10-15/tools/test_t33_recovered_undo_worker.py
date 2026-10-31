"""Run the real recovery worker with disposable files and modeled APFS calls."""
from contextlib import ExitStack
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import run_t33_recovered_undo as worker
from tests import test_guest_reboot_recovery as fixtures
import cfw_disk_txn as txn
import cfw_guest_evidence as evidence
from patchers import guest_undo, final_guest


class RecoveredWorkerTests(unittest.TestCase):
    def setUp(self):
        self.f = fixtures.GuestRebootRecoveryTests(); self.f.setUp(); self.addCleanup(self.f.doCleanups)
        self.f.work.rmdir()  # Empty disposable fixture reservation, never a real transaction.
        self.vm = self.f.f.vm; self.work = self.f.work
        self.f.f.args = SimpleNamespace(work=self.work)
        self.f.f.mount.chmod(0o700)
        self.root = self.vm.parent / 'worker-plan'; self.root.mkdir(); (self.root / 'execution').mkdir()
        cli = self.vm.parent / 'candidate/Contents/MacOS/vphone-cli'; cli.parent.mkdir(parents=True)
        shutil.copy2(self.f.f.fixture.plan_fixture.verifier, cli)
        scripts = cli.parent.parent / 'Resources/scripts'; scripts.mkdir(parents=True)
        source = Path(txn.__file__); shutil.copy2(source, scripts / source.name)
        binding = dict(bundle='fixture'); (self.vm / 'launchpad.json').write_text(json.dumps(binding))
        self.plan = dict(candidate=dict(version='fixture', cliSHA256=evidence.digest(cli)), installedCLI=str(cli),
            installedModuleSHA256={source.name: evidence.digest(source)}, boundBeforeRecovery=binding,
            targets=[dict(vm=str(self.vm))], recovery=dict(preservedSource=str(self.f.source),
                newWork=str(self.work), transactionID='20261026T000000Z-resumed',
                sourceTransactionID=self.f.source.name, desiredSHA256=self.f.f.fixture.f.plan.raw_sha256,
                recordSHA256=self.f.expected['recordSHA256'], imageSHA256=self.f.expected['imageSHA256'],
                parentImageSHA256=self.f.expected['parentImageSHA256']))
        path = self.root / 'offline-plan.json'; path.write_text(json.dumps(self.plan))
        digest = evidence.digest(path)
        (self.root / 'approval.json').write_text(json.dumps(dict(approved=True, planSHA256=digest)))
        self.stack = ExitStack(); self.addCleanup(self.stack.close)
        self.stack.enter_context(patch('sys.argv', ['worker', '--plan', str(path), '--sha256', digest]))
        self.stack.enter_context(patch.object(worker, 'require_root'))
        self.stack.enter_context(patch.object(txn, 'make_mount_directory', return_value=self.f.f.mount))
        query = self.f.f.query(True)
        def output(argv, **kwargs):
            if argv[:2] == ['/usr/bin/hdiutil', 'attach']:
                return plistlib.dumps({'system-entities': [dict(content_hint='unused'),
                    {'dev-entry': '/dev/disk41', 'content-hint': 'GUID_partition_scheme'}]})
            return query(argv)
        self.stack.enter_context(patch.object(worker.subprocess, 'check_output', side_effect=output))
        native_run = subprocess.run
        def run(argv, **kwargs):
            if str(argv[0]) in ('/usr/bin/hdiutil', '/sbin/umount'):
                return subprocess.CompletedProcess(argv, 0)
            return native_run(argv, **kwargs)
        self.stack.enter_context(patch.object(worker.subprocess, 'run', side_effect=run))
        self.writer = self.stack.enter_context(patch.object(guest_undo, 'apply', side_effect=AssertionError('Undo writer repeated')))

    def test_worker_reads_seals_and_publishes_without_repeating_undo(self):
        worker.main()
        self.writer.assert_not_called()
        result = json.loads((self.root / 'execution/recovered-undo-result.json').read_bytes())
        self.assertEqual(result['state'], 'published')
        self.assertEqual(result['repeatedUndoWrites'], 0)
        self.assertEqual(evidence.digest(self.vm / 'Disk.img'), self.plan['recovery']['imageSHA256'])
        self.assertTrue((self.vm / '.cfw-history/20261026T000000Z-resumed/guest-publication.json').exists())
        self.assertEqual(self.f.before, {str(p.relative_to(self.f.source)): evidence.digest(p)
            for p in self.f.source.rglob('*') if p.is_file()})

    def test_final_read_failure_preserves_parent_and_staging_without_publish(self):
        with (patch.object(final_guest, 'run', side_effect=ValueError('modeled final read mismatch')),
              patch.object(txn, 'publish', wraps=txn.publish) as publication):
            with self.assertRaisesRegex(ValueError, 'final read mismatch'): worker.main()
        publication.assert_not_called(); self.writer.assert_not_called()
        self.assertEqual(evidence.digest(self.vm / 'Disk.img'), self.plan['recovery']['parentImageSHA256'])
        self.assertTrue((self.work / 'transaction.json').exists())
        self.assertFalse((self.root / 'execution/recovered-undo-result.json').exists())


if __name__ == '__main__':
    unittest.main()
