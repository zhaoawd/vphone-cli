"""Exercise cleanup capacity, preservation and refusal on disposable fixture trees."""
from contextlib import ExitStack,redirect_stdout
import gzip
import hashlib
import io
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import failed_rounds_cleanup_20261025 as runner


class FailedRoundsCleanupTests(unittest.TestCase):
    def setUp(self):
        temporary=tempfile.TemporaryDirectory();self.addCleanup(temporary.cleanup)
        self.root=Path(temporary.name).resolve();self.out=self.root/'evidence';self.out.mkdir()
        self.stack=ExitStack();self.addCleanup(self.stack.close)
        for owner,key,value in ((runner,'ROOT',self.root),(runner,'OUT',self.out),(runner,'OLD_VM',self.root/'old'),
                (runner,'PRIMARY',('cache',)),(runner,'SECONDARY',('history','legacy-disk','working')),
                (runner.storage,'ROOT',self.root),(runner.storage,'OUT',self.out)):
            self.stack.enter_context(patch.object(owner,key,value))
        (self.root/'old').mkdir();(self.root/'.build/t33t-20261025').mkdir(parents=True)
        for name in ('cache','history','working','generation'):
            p=self.root/name;p.mkdir();(p/'record.json').write_bytes(b'{"fixture":true}')
        for name in ('legacy-disk','current.img','keep'):(self.root/name).write_bytes(b'complete fixture bytes')
        runner.configure()
        info=(self.root/'legacy-disk').stat()
        inventories={name:runner.inventory(self.root/name) for name in runner.PRIMARY+runner.SECONDARY}
        raw=gzip.compress(json.dumps(inventories).encode(),mtime=0)
        (self.out/'inventory-before.json.gz').write_bytes(raw)
        self.plan=dict(primary=list(runner.PRIMARY),secondary=list(runner.SECONDARY),targetFreeBytes=runner.TARGET_FREE,
            VMStarts=0,securityWindows=0,automaticRetry=False,protectedInputs={str(self.root/'keep'):runner.sha(self.root/'keep')},
            protectedDiskIdentities={'legacy-disk':dict(dev=info.st_dev,ino=info.st_ino,size=info.st_size)},
            protectedTrees={'generation':runner.storage.inventory(self.root/'generation')},
            currentEXPDisk='current.img',expectedEXPDiskSHA256=runner.sha(self.root/'current.img'),
            inventorySHA256=hashlib.sha256(raw).hexdigest())
        runner.save(self.out/'plan.json',self.plan);self.digest=runner.sha(self.out/'plan.json')
        runner.save(self.out/'approval.json',dict(approved=True,planSHA256=self.digest,allowOldDSC=True))
        self.stack.enter_context(patch.object(runner,'unused'))
        self.stack.enter_context(patch.object(runner.storage,'attachments'))
        self.stack.enter_context(patch.object(runner.previous.base,'baseline',return_value=dict(files=10,fullReadbackPassed=True)))

    def apply(self,space):
        with patch.object(runner.shutil,'disk_usage',side_effect=lambda _:SimpleNamespace(free=space())),redirect_stdout(io.StringIO()):
            code=runner.apply(self.digest)
        return code,json.loads((self.out/'result.json').read_bytes())

    def test_primary_capacity_preserves_all_optional_old_state(self):
        code,result=self.apply(lambda:(80 if (self.root/'cache').exists() else 101)*1024**3)
        self.assertEqual(code,0);self.assertEqual(result['removed'],['cache'])
        self.assertTrue((self.root/'legacy-disk').exists());self.assertEqual(result['skipped'],list(runner.SECONDARY))

    def test_fallback_stops_after_history_if_capacity_reached(self):
        code,result=self.apply(lambda:(80 if (self.root/'history').exists() else 101)*1024**3)
        self.assertEqual(code,0);self.assertEqual(result['removed'],['cache','history'])
        self.assertTrue(result['retiredOldDSCHistory']);self.assertFalse(result['retiredOldDSCDisk'])
        self.assertTrue((self.root/'working').exists());self.assertEqual((self.root/'keep').read_bytes(),b'complete fixture bytes')

    def test_capacity_failure_does_not_expand_scope(self):
        code,result=self.apply(lambda:80*1024**3)
        self.assertEqual(code,1);self.assertEqual(result['state'],'capacity-target-not-met')
        self.assertEqual(result['removed'],list(runner.PRIMARY+runner.SECONDARY));self.assertTrue((self.root/'keep').exists())

    def test_changed_last_root_prevents_all_deletions(self):
        (self.root/'working/new').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError,'input changed'):self.apply(lambda:80*1024**3)
        self.assertTrue((self.root/'cache').exists());self.assertTrue((self.root/'legacy-disk').exists())

    def test_protected_input_mutation_prevents_deletion(self):
        (self.root/'keep').write_bytes(b'changed')
        with self.assertRaisesRegex(ValueError,'Protected input'):self.apply(lambda:80*1024**3)
        self.assertTrue((self.root/'cache').exists())

    def test_separate_old_state_approval_is_required(self):
        (self.out/'approval.json').write_text(json.dumps(dict(approved=True,planSHA256=self.digest,allowOldDSC=False)))
        with self.assertRaisesRegex(ValueError,'retirement approval'):self.apply(lambda:80*1024**3)
        self.assertFalse((self.out/'result.json').exists())

    def test_no_replay_after_completed_run(self):
        self.apply(lambda:101*1024**3)
        with self.assertRaisesRegex(ValueError,'no replay'):self.apply(lambda:101*1024**3)

    def test_symlink_root_is_refused(self):
        path=self.root/'linked';path.symlink_to(self.root/'generation',target_is_directory=True)
        with self.assertRaisesRegex(ValueError,'Linked'):runner.inventory(path)

    def test_protected_descendant_scope_is_refused(self):
        plan=dict(self.plan,protectedInputs={str(self.root/'cache/record.json'):'a'*64})
        with self.assertRaisesRegex(ValueError,'intersects'):runner.exact_scope(plan)


if __name__=='__main__':unittest.main()
