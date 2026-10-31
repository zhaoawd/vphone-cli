"""Exercise the actual guarded patcher after its producer's staging copy."""
import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import sys
import subprocess
import unittest
from unittest.mock import patch

from tests import test_patch_plan_gate as fixtures
from patchers import cfw, guest_write


class BuildVersionTargetBindingTests(unittest.TestCase):
    setUp=fixtures.FrozenGateTests.setUp
    publish=fixtures.FrozenGateTests.publish
    load=fixtures.FrozenGateTests.load

    def prepare(self,volume):
        _,digest=guest_write.target_table()
        declaration='system-systemversion-cfw-build_version'
        self.entries.append(dict(id=declaration,disposition='guestUncovered',recordRules=[
            dict(literal='guest-target-map-v1:'+digest+':'+declaration,hexadecimalOffsetSuffix=False)]))
        self.plan['variant']='exp';self.plan['gates']['variant']='exp'
        self.context.update(variant='exp',spoofBuild='23Z999999');self.publish()
        os.environ.update(VPHONE_CFW_VARIANT='exp',VPHONE_FROZEN_PLAN_SHA256=self.digest,
                          VPHONE_FROZEN_CONTEXT=json.dumps(self.context))
        if volume=='preboot':
            source=self.mount/'mnt5/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist'
            target='preboot:/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist'
        elif volume=='cryptex':
            source=self.mount/'mnt1/System/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist'
            target='system:/System/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist'
        else:
            source=self.mount/'mnt1/System/Library/CoreServices/SystemVersion.plist'
            target='system:/System/Library/CoreServices/SystemVersion.plist'
        source.parent.mkdir(parents=True,exist_ok=True)
        source.write_bytes(plistlib.dumps(dict(ProductBuildVersion='23A341',ProductVersion='26.0')))
        staged=self.stage/(str(source).replace('/','_')+'.plist')
        guest_write.run(self.load(),['cp',str(source),str(staged)])
        self.assertEqual(guest_write.logical(source),target)
        self.assertEqual(json.loads(self.evidence.read_text().splitlines()[-1])['target'],target)
        return staged,target,source

    def invoke(self,staged):
        with patch.object(sys,'argv',['cfw.py','patch-build-version',str(staged),'23Z999999']), \
             contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as stopped:cfw.main()
        self.assertEqual(stopped.exception.code,0)

    def test_root_staging_copy_keeps_its_source_target(self):
        staged,target,source=self.prepare('system');self.invoke(staged)
        self.assertEqual(json.loads(self.evidence.read_text().splitlines()[-1])['target'],target)
        self.assertEqual(plistlib.loads(source.read_bytes())['ProductBuildVersion'],'23A341')

    def test_system_cryptex_staging_copy_keeps_its_source_target(self):
        staged,target,source=self.prepare('cryptex');self.invoke(staged)
        self.assertEqual(json.loads(self.evidence.read_text().splitlines()[-1])['target'],target)
        self.assertEqual(plistlib.loads(source.read_bytes())['ProductBuildVersion'],'23A341')

    def test_previous_target_rules_cannot_authorize_new_writes(self):
        staged,_,_=self.prepare('system');self.evidence.write_text('');staged.unlink()
        entry=self.entries[-1]
        entry['recordRules'][0]['literal']='guest-target-map-v1:5f259f42583bb7b1f1426b986a86801fc421e17921fc157fe4a74bd596771213:'+entry['id']
        self.publish()
        os.environ.update(VPHONE_FROZEN_PLAN_SHA256=self.digest,VPHONE_FROZEN_CONTEXT=json.dumps(self.context))
        source=self.mount/'mnt1/System/Library/CoreServices/SystemVersion.plist'
        with self.assertRaises(ValueError):guest_write.run(self.load(),['cp',str(source),str(staged)])
        self.assertFalse(staged.exists());self.assertEqual(self.evidence.read_bytes(),b'')

    def run_installer_version_step(self,preboot_present):
        _,_,root=self.prepare('system')
        cryptex=self.mount/'mnt1/System/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist'
        preboot=self.mount/'mnt5/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist'
        paths=[root,cryptex]+([preboot] if preboot_present else [])
        for path in paths:
            path.parent.mkdir(parents=True,exist_ok=True)
            path.write_bytes(plistlib.dumps({'ProductBuildVersion':'23A341','ProductVersion':'26.0'}))
        text=(fixtures.ROOT/'scripts/cfw_install_exp.sh').read_text()
        body=text[text.index('if [[ -n "${SPOOF_BUILD:-}" ]]'):text.index('# ═══════════ CLEANUP')]
        env=dict(os.environ,PYTHON3=sys.executable,SCRIPT_DIR=str(fixtures.ROOT/'scripts'),
                 VM_DIR=str(self.vm),TEMP_DIR=str(self.stage),SPOOF_BUILD='23Z999999',
                 MNT1=str(self.mount/'mnt1'),MNT5=str(self.mount/'mnt5'))
        result=subprocess.run(['/bin/zsh','-c','set -euo pipefail\nsource "$SCRIPT_DIR/lib/cfw_common.sh"\n'+body],
                              env=env,pass_fds=(self.lock_fd,),capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        for path in paths:self.assertEqual(plistlib.loads(path.read_bytes())['ProductBuildVersion'],'23Z999999',str(path))
        if not preboot_present:self.assertFalse(preboot.exists())
        rows=[json.loads(line) for line in self.evidence.read_text().splitlines()]
        from patchers import component_effects
        outputs=component_effects.verify_rows(self.load(),rows,{'system':self.mount/'mnt1','preboot':self.mount/'mnt5'},self.evidence.parent/'effect-blobs')
        self.assertEqual({row['target'] for row in outputs},{guest_write.logical(path) for path in paths})

    def test_installer_changes_both_system_files_when_preboot_absent(self):
        self.run_installer_version_step(False)

    def test_installer_also_changes_present_preboot_file(self):
        self.run_installer_version_step(True)

    def test_preboot_staging_copy_keeps_its_source_target(self):
        staged,target,source=self.prepare('preboot');self.invoke(staged)
        self.assertEqual(json.loads(self.evidence.read_text().splitlines()[-1])['target'],target)
        self.assertEqual(plistlib.loads(source.read_bytes())['ProductBuildVersion'],'23A341')

    def rewrite_rows(self,rows):
        self.evidence.write_text(''.join(json.dumps(row)+'\n' for row in rows))

    def refused(self,staged):
        before=staged.read_bytes();evidence=self.evidence.read_bytes()
        with self.assertRaises((ValueError,KeyError)):
            self.invoke(staged)
        self.assertEqual(staged.read_bytes(),before)
        self.assertEqual(self.evidence.read_bytes(),evidence)

    def test_repeated_patch_keeps_copy_binding(self):
        staged,target,_=self.prepare('preboot')
        self.invoke(staged);first=staged.read_bytes();self.invoke(staged)
        self.assertEqual(staged.read_bytes(),first)
        self.assertTrue(all(json.loads(line)['target']==target for line in self.evidence.read_text().splitlines()))

    def test_unrelated_intervening_record_does_not_change_binding(self):
        staged,target,_=self.prepare('preboot')
        rows=[json.loads(line) for line in self.evidence.read_text().splitlines()]
        unrelated=dict(rows[0],path=str(self.stage/'unrelated'))
        self.rewrite_rows(rows+[unrelated]);self.invoke(staged)
        self.assertEqual(json.loads(self.evidence.read_text().splitlines()[-1])['target'],target)

    def test_missing_copy_refused_before_write(self):
        staged,_,_=self.prepare('preboot');self.evidence.write_text('');self.refused(staged)

    def test_changed_file_refused_before_write(self):
        staged,_,_=self.prepare('preboot');staged.write_bytes(plistlib.dumps({'ProductBuildVersion':'other'}))
        self.refused(staged)

    def test_changed_metadata_refused_before_write(self):
        staged,_,_=self.prepare('preboot');staged.chmod(0o600);self.refused(staged)

    def test_changed_guest_source_refused_before_write(self):
        staged,_,source=self.prepare('preboot');source.write_bytes(b'changed');self.refused(staged)

    def test_copy_context_and_target_tampering_refused(self):
        staged,_,_=self.prepare('preboot')
        original=self.evidence.read_bytes()
        for field,value in [('generationID','b'*64),('planDigest','b'*64),
                            ('desiredSHA256','b'*64),('declarationID','system-seputil-boot-gigalocker_uuid'),
                            ('target','system:/System/Library/CoreServices/SystemVersion.plist'),
                            ('phase','guest'),('afterSHA256','b'*64),
                            ('afterMetadata',{'mode':0,'uid':0,'gid':0})]:
            with self.subTest(field=field):
                row=json.loads(original);row[field]=value;self.rewrite_rows([row]);self.refused(staged)

    def test_copy_source_target_and_path_tampering_refused(self):
        staged,_,_=self.prepare('preboot');original=self.evidence.read_bytes()
        for field,value in [('sourceTarget','system:/System/Library/CoreServices/SystemVersion.plist'),
                            ('sourcePath',str(staged)),('command','mv')]:
            with self.subTest(field=field):
                row=json.loads(original);row['effect'][field]=value
                self.rewrite_rows([row]);self.refused(staged)

    def test_discontinuous_patch_chain_refused(self):
        staged,_,_=self.prepare('preboot');self.invoke(staged)
        rows=[json.loads(line) for line in self.evidence.read_text().splitlines()]
        # Keep row/effect internally consistent while breaking copy -> patch continuity.
        rows[-1]['effect']['before']['sha256']='b'*64;rows[-1]['beforeSHA256']='b'*64
        self.rewrite_rows(rows);self.refused(staged)

    def test_symlinked_staging_file_refused(self):
        staged,_,source=self.prepare('preboot');staged.unlink();staged.symlink_to(source)
        self.refused(staged)

    def test_hardlinked_staging_file_refused(self):
        staged,_,_=self.prepare('preboot');os.link(staged,self.stage/'other-link');self.refused(staged)


if __name__=='__main__':unittest.main()
