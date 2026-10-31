"""Verify four-root retirement and finalization on disposable fixtures only."""
from contextlib import ExitStack, redirect_stdout
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import retire_t33_dev_overlay_states as retirement
import finalize_t33_dev_overlay_acceptance as finalizer


class DevOverlayRetirementTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve(); self.out = self.root/'evidence'; self.out.mkdir()
        self.stack = ExitStack(); self.addCleanup(self.stack.close)
        for owner, key, value in ((retirement.runner,'ROOT',self.root), (retirement.storage,'ROOT',self.root),
                (retirement.storage,'OUT',self.out), (retirement.storage,'NAMES',retirement.NAMES)):
            self.stack.enter_context(patch.object(owner,key,value))
        self.roots = [self.root/name for name in retirement.NAMES]
        self.rows=[]
        for path in self.roots:
            path.mkdir(parents=True); (path/'Disk.img').write_bytes(b'fixture disk')
            (path/'record.json').write_text('{"failed":true}')
            self.rows.append(dict(path=str(path.relative_to(self.root)),
                rootIdentity={k:v for k,v in retirement.storage.metadata(path).items() if k in ('dev','ino','mode','uid','gid')}))
        self.plan=dict(retirement=dict(retirementTargets=self.rows, requiresExplicitDeletionApproval=True,
            fullDiskBackup=False, removedPreservedDiskIdentities={name+'/Disk.img':{} for name in
            (retirement.NAMES[0],retirement.NAMES[2])}),unrelatedDiskIdentities={})

    def test_exact_scope_and_identity_exceptions_only(self):
        retirement.validate_scope(self.plan)
        for changes in (dict(requiresExplicitDeletionApproval=False),dict(fullDiskBackup=True),
                        dict(removedPreservedDiskIdentities={}),dict(retirementTargets=self.rows[:-1])):
            plan=copy.deepcopy(self.plan);plan['retirement'].update(changes)
            with self.subTest(changes=changes),self.assertRaises(ValueError):retirement.validate_scope(plan)

    def test_separate_deletion_approval_required_before_root_checks(self):
        digest='a'*64
        with patch.object(retirement.runner,'configure'),patch.object(retirement.runner.base,'approved'), \
             patch.object(retirement.runner.base.evidence,'read',return_value=b'{"approved":true}'):
            with self.assertRaisesRegex(ValueError,'deletion approval'):retirement.approval(digest)
        value=dict(approved=True,planSHA256=digest,authorizedRetirementPaths=list(retirement.NAMES))
        with patch.object(retirement.runner,'configure'),patch.object(retirement.runner.base,'approved'), \
             patch.object(retirement.runner.base.evidence,'read',return_value=json.dumps(value).encode()):
            retirement.approval(digest)

    def test_protected_descendant_and_replaced_root_refused(self):
        with self.assertRaisesRegex(ValueError,'Protected input'):
            retirement.storage.validate_roots(self.plan['retirement'],{str(self.roots[0]/'record.json'):'a'*64})
        old=self.roots[0];old.rename(old.with_name('preserved'));old.mkdir()
        with self.assertRaisesRegex(ValueError,'identity changed'):
            retirement.storage.validate_roots(self.plan['retirement'],{})

    def test_small_record_archive_excludes_disks_and_is_read_back(self):
        inventories={str(p.relative_to(self.root)):retirement.storage.inventory(p) for p in self.roots}
        self.assertEqual(retirement.storage.archive_small_records(inventories),4)
        value=json.loads((self.out/'retired-small-records-manifest.json').read_bytes())
        self.assertFalse(value['fullDiskBackup']);self.assertTrue(all(r['path'].endswith('record.json') for r in value['files']))
        self.assertTrue(all(p.exists() for p in self.roots))

    def test_later_root_change_prevents_any_deletion(self):
        inventories={str(p.relative_to(self.root)):retirement.storage.inventory(p) for p in self.roots}
        (self.roots[-1]/'record.json').write_bytes(b'changed')
        with patch.object(retirement.storage,'unused'),patch.object(retirement.storage,'attachments'):
            with self.assertRaisesRegex(ValueError,'inventory changed'):
                retirement.storage.remove_verified(self.roots,inventories,[])
        self.assertTrue(all(p.exists() for p in self.roots))

    def test_fixture_retirement_keeps_unrelated_files(self):
        keep=self.root/'keep';keep.write_bytes(b'preserved')
        inventories={str(p.relative_to(self.root)):retirement.storage.inventory(p) for p in self.roots};removed=[]
        with patch.object(retirement.storage,'unused'),patch.object(retirement.storage,'attachments'),redirect_stdout(io.StringIO()):
            retirement.storage.remove_verified(self.roots,inventories,removed)
        self.assertEqual(removed,list(retirement.NAMES));self.assertEqual(keep.read_bytes(),b'preserved')

    def test_insufficient_capacity_does_not_start_native(self):
        with patch.object(retirement.runner,'execute') as execute:
            self.assertEqual(retirement.continue_if_capacity({},'a'*64,{'capacity75GiBPassed':False}),0)
            execute.assert_not_called()
        self.assertEqual(json.loads((self.out/'pipeline-result.json').read_bytes()),
                         dict(state='awaiting-capacity',nativeStarted=False))

    def test_native_called_once_and_failure_not_retried(self):
        with patch.object(retirement.runner,'execute',return_value=1) as execute:
            self.assertEqual(retirement.continue_if_capacity({},'a'*64,{'capacity75GiBPassed':True}),1)
            execute.assert_called_once_with({},'a'*64)

    def test_finalizer_refuses_missing_backup_or_preservation_failure(self):
        good=dict(state='failed',VMStarts=0,securityWindows=0,originalVMWritten=False,deletionPerformed=False,
            baseline=dict(files=10,fullReadbackPassed=True),targetAttachments=[],beforeWriteBackupVerified=True)
        finalizer.validate_native(good)
        for key,value in [('beforeWriteBackupVerified',False),('targetAttachments',['disk']),('VMStarts',1),
                          ('preservationOrCleanupError','failed'),('state','running')]:
            with self.subTest(key=key),self.assertRaises(ValueError):finalizer.validate_native(dict(good,**{key:value}))


if __name__=='__main__':unittest.main()
