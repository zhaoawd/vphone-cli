"""Exercise destructive operations only on disposable, isolated fixture trees."""
import io
import json
from pathlib import Path
import tempfile
import unittest
from contextlib import ExitStack, redirect_stdout
from unittest.mock import patch

import retire_t32_t33_states_20261025 as runner
import launch_t32_t33_retirement_20261025 as launcher


class RetirementTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.out = self.root / 'evidence'; self.out.mkdir()
        self.stack = ExitStack(); self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.object(runner, 'ROOT', self.root))
        self.stack.enter_context(patch.object(runner, 'OUT', self.out))
        self.paths = [self.root / name for name in runner.NAMES]
        self.assessment = dict(retirementTargets=[])
        for path in self.paths:
            path.mkdir(parents=True)
            (path / 'Disk.img').write_bytes(b'fixture disk')
            (path / 'phase.json').write_text('{"state":"failed"}')
            self.assessment['retirementTargets'].append(dict(path=str(path.relative_to(self.root)),
                rootIdentity={k: v for k, v in runner.metadata(path).items() if k in ('dev','ino','mode','uid','gid')}))

    def test_only_four_exact_roots_are_admitted(self):
        self.assertEqual(runner.validate_roots(self.assessment, {}), self.paths)
        self.assessment['retirementTargets'].pop()
        with self.assertRaises(ValueError):runner.validate_roots(self.assessment, {})

    def test_symlink_root_and_protected_descendant_are_rejected(self):
        with self.assertRaisesRegex(ValueError,'Protected input'):
            runner.validate_roots(self.assessment, {str(self.paths[0] / 'phase.json'): 'a'*64})
        original=self.paths[0];renamed=original.with_name('preserved');original.rename(renamed)
        original.symlink_to(renamed,target_is_directory=True)
        with self.assertRaisesRegex(ValueError,'Linked'):
            runner.validate_roots(self.assessment, {})

    def test_metadata_archive_is_read_back_and_excludes_disk(self):
        inventories={str(path.relative_to(self.root)):runner.inventory(path) for path in self.paths}
        self.assertEqual(runner.archive_small_records(inventories),4)
        report=json.loads((self.out/'retired-small-records-manifest.json').read_text())
        self.assertFalse(report['fullDiskBackup'])
        self.assertTrue(all(row['path'].endswith('phase.json') for row in report['files']))
        self.assertTrue(all(path.exists() for path in self.paths))

    def test_changed_later_root_prevents_all_deletions(self):
        inventories={str(path.relative_to(self.root)):runner.inventory(path) for path in self.paths}
        (self.paths[-1]/'phase.json').write_text('changed')
        with patch.object(runner,'unused'),patch.object(runner,'attachments'):
            with self.assertRaisesRegex(ValueError,'inventory changed'):
                runner.remove_verified(self.paths,inventories,[])
        self.assertTrue(all(path.exists() for path in self.paths))

    def test_open_holder_or_attachment_prevents_deletion(self):
        inventories={str(path.relative_to(self.root)):runner.inventory(path) for path in self.paths}
        for name in ('unused','attachments'):
            with self.subTest(name=name),ExitStack() as stack:
                stack.enter_context(patch.object(runner,'unused'))
                stack.enter_context(patch.object(runner,'attachments'))
                stack.enter_context(patch.object(runner,name,side_effect=ValueError('held')))
                with self.assertRaises(ValueError):runner.remove_verified(self.paths,inventories,[])
                self.assertTrue(all(path.exists() for path in self.paths))

    def test_four_fixture_roots_removed_and_unrelated_file_preserved(self):
        keep=self.root/'keep.img';keep.write_bytes(b'preserved')
        inventories={str(path.relative_to(self.root)):runner.inventory(path) for path in self.paths};removed=[]
        with patch.object(runner,'unused'),patch.object(runner,'attachments'),redirect_stdout(io.StringIO()):
            runner.remove_verified(self.paths,inventories,removed)
        self.assertEqual(removed,list(runner.NAMES))
        self.assertTrue(all(not path.exists() for path in self.paths));self.assertEqual(keep.read_bytes(),b'preserved')

    def test_plan_activation_retains_all_three_original_records(self):
        work=self.root/'work';work.mkdir()
        old=b'old plan';new=b'approved amended plan'
        originals={'offline-plan.json':old,'approval.json':b'old approval','executor-inputs.json':b'old input record'}
        for name,value in originals.items():(work/name).write_bytes(value)
        old_digest=runner.sha(work/'offline-plan.json')
        import hashlib
        new_digest=hashlib.sha256(new).hexdigest()
        with patch.object(runner,'WORK',work),patch.object(runner,'OLD',old_digest),patch.object(runner,'NEW',new_digest):
            runner.publish_amendment(new,dict(planSHA256=old_digest,files={'retained':'digest'}))
        for name,value in originals.items():self.assertEqual((work/(name+'.before-retirement-20261025')).read_bytes(),value)
        self.assertEqual((work/'offline-plan.json').read_bytes(),new)
        self.assertEqual(json.loads((work/'executor-inputs.json').read_bytes()),dict(planSHA256=new_digest,files={'retained':'digest'}))

    def test_launcher_detaches_all_pipes_and_refuses_duplicate_start(self):
        (self.out/'cleanup-inputs.json').write_text('{"files":{}}')
        with patch.object(launcher,'ROOT',self.root),patch.object(launcher,'OUT',self.out), \
             patch.object(launcher.os,'geteuid',return_value=0), \
             patch.object(launcher.subprocess,'Popen') as launch,redirect_stdout(io.StringIO()):
            launch.return_value.pid=12345
            self.assertEqual(launcher.start(),12345)
            self.assertTrue(launch.call_args.kwargs['start_new_session'])
            self.assertTrue(launch.call_args.kwargs['close_fds'])
            self.assertEqual(launch.call_args.kwargs['stdin'],launcher.subprocess.DEVNULL)
            self.assertEqual(launch.call_args.kwargs['stderr'],launcher.subprocess.STDOUT)
            self.assertIsNotNone(launch.call_args.kwargs['stdout'])
            with self.assertRaisesRegex(ValueError,'do not replay'):launcher.start()
            self.assertEqual(launch.call_count,1)


if __name__=='__main__':unittest.main()
