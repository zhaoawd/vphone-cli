import contextlib
import hashlib
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

import execute_t32_resumed_file_acceptance as runner


class ContinuationGuardsTests(unittest.TestCase):
    def test_separate_approval_frozen_inputs_and_interpreter_are_required(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            tool = root / 'tool'
            tool.write_bytes(b'input')
            plan = dict(VMStarts=0, securityWindows=0, automaticRetry=False,
                        python=str(tool), pythonResolved=str(tool.resolve()),
                        frozenInputs={str(tool): hashlib.sha256(b'input').hexdigest()})
            path = root / 'resumed-file-acceptance-plan.json'
            path.write_text(json.dumps(plan))
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            with patch.object(runner, 'WORK', root):
                with self.assertRaises(FileNotFoundError):
                    runner.approved(digest)
                approval = root / 'resumed-file-acceptance-approval.json'
                approval.write_text(json.dumps(dict(approved=False, planSHA256=digest)))
                with self.assertRaisesRegex(ValueError, 'Separate continuation approval'):
                    runner.approved(digest)
                approval.write_text(json.dumps(dict(approved=True, planSHA256=digest)))
                self.assertEqual(runner.approved(digest), plan)
                tool.write_bytes(b'changed')
                with self.assertRaisesRegex(ValueError, 'Frozen input changed'):
                    runner.approved(digest)
                with self.assertRaisesRegex(ValueError, 'plan changed'):
                    runner.approved('0' * 64)

    def test_complete_baseline_checks_identity_and_all_bytes(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            disk = root / 'Disk.img'
            disk.write_bytes(b'original')
            info = disk.stat()
            identity = dict(dev=info.st_dev, ino=info.st_ino, size=info.st_size,
                            mtime_ns=info.st_mtime_ns, mode=stat.S_IMODE(info.st_mode), uid=info.st_uid, gid=info.st_gid)
            expected = {'Disk.img': hashlib.sha256(b'original').hexdigest()}
            identities = {'Disk.img': identity}
            with patch.object(runner.audit, 'locked_vm', side_effect=lambda _: contextlib.nullcontext()), \
                 patch.object(runner.txn, 'require_unheld'):
                self.assertEqual(runner.verify_files(root, expected, identities), expected)
                with self.assertRaisesRegex(ValueError, 'identity changed'):
                    runner.verify_files(root, expected, {'Disk.img': dict(identity, ino=identity['ino'] + 1)})
                with self.assertRaisesRegex(ValueError, 'state changed'):
                    runner.verify_files(root, {'Disk.img': '0' * 64}, identities)


if __name__ == '__main__':
    unittest.main()
