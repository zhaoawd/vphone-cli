"""Real CFW entrypoint refusal must precede target writes and runtime hooks."""
import fcntl
import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from patchers import cfw


class PlanEntrypointTests(unittest.TestCase):
    def test_changed_plan_refused_before_write(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'dropbear.plist'
            target.write_bytes(plistlib.dumps({'ProgramArguments': ['/usr/local/bin/dropbear']}))
            original = target.read_bytes()
            plan = Path(directory) / 'plan.json'
            plan.write_text('{"schemaVersion":999}')
            with patch.dict(os.environ, {'VPHONE_FROZEN_PLAN': str(plan),
                       'VPHONE_FROZEN_PLAN_SHA256': '0' * 64}, clear=True), \
                 patch.object(sys, 'argv', ['cfw.py', 'patch-dropbear-plist', str(target)]), \
                 contextlib.redirect_stdout(io.StringIO()):
                try:
                    cfw.main()
                except (SystemExit, ValueError):
                    pass
            self.assertEqual(target.read_bytes(), original)

    def test_guest_mode_cannot_be_overridden(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'lib').mkdir()
            marker = root / 'runtime-called'
            (root / 'lib/cfw_common.sh').write_text(
                'cfw_require_runtime_and_lock() { touch "$VM_DIR/runtime-called"; exit 73; }\n')
            script = root / 'cfw_install_exp.sh'
            script.write_bytes((ROOT / 'scripts/cfw_install_exp.sh').read_bytes())
            result = subprocess.run(['/bin/zsh', str(script), str(root)],
                env={'PATH': os.environ['PATH'], 'VPHONE_CFW_VARIANT': 'regular'},
                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(marker.exists(), result.stderr.decode())

    def test_unknown_record_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / 'dropbear.plist'
            target.write_bytes(plistlib.dumps({'ProgramArguments': ['/usr/local/bin/dropbear']}))
            before = target.read_bytes()
            with patch.dict(os.environ, {'VPHONE_DECLARATION_ID': 'unknown'}, clear=True), \
                 patch.object(sys, 'argv', ['cfw.py', 'patch-dropbear-plist', str(target)]), \
                 contextlib.redirect_stdout(io.StringIO()):
                try:
                    cfw.main()
                except (SystemExit, ValueError):
                    pass
            self.assertEqual(target.read_bytes(), before)

from patchers import plan_gate as gate
from patchers import guest_write
import hashlib

class FrozenGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.vm = self.root / 'vm'; self.vm.mkdir()
        self.lock_fd=os.open(self.vm,os.O_RDONLY|os.O_DIRECTORY);fcntl.flock(self.lock_fd,fcntl.LOCK_EX)
        self.addCleanup(os.close,self.lock_fd)
        self.mount = self.vm / '.cfw_mount.test'; (self.mount / 'mnt1').mkdir(parents=True)
        self.stage = self.vm / '.cfw_temp'; self.stage.mkdir()
        self.evidence = self.vm / '.cfw_disk.test/guest-changes.jsonl'
        self.verifier = self.root / 'verifier'
        self.verifier.write_text('#!/bin/sh\ncat "$VPHONE_TEST_VERIFIED_EXPORT"\n')
        self.verifier.chmod(0o755)
        _, digest = guest_write.target_table()
        self.entries = [dict(id=identifier, disposition='guestUncovered',
            recordRules=[{'literal':'guest-target-map-v1:'+digest+':'+identifier, 'hexadecimalOffsetSuffix':False}])
            for identifier in ['system-launchdaemons-boot-install','system-iosbinpack-boot-install','system-launchdaemons-boot-environment','system-seputil-boot-gigalocker_uuid']]
        self.plan = {group:[] for group in gate.GROUPS}
        self.plan.update(variant='regular', gates={'variant':'regular','enableFrida':False,'guestEnvironmentV2':False},
                         guestUncovered=self.entries)
        self.record = dict(schemaVersion=1,upstreamTarget=gate.TARGET,catalogSHA256='c'*64,
                           generationID='a'*64,identity={'diskInode':1},plan=self.plan,
                           planSHA256=hashlib.sha256(gate.canonical(self.plan)).hexdigest())
        self.context = {key:self.record[key] for key in ['identity','generationID','catalogSHA256','planSHA256','upstreamTarget']}
        self.context.update(schemaVersion=1,vmDirectory=str(self.vm),variant='regular',
            verifierPath=str(self.verifier),verifierSHA256=hashlib.sha256(self.verifier.read_bytes()).hexdigest(),
            guestEnvironment='classic',spoofBuild='',disableLaunchdHook='0')
        self.export=self.root/'verified.json'
        self.publish()
        self.environment = dict(VPHONE_FROZEN_PLAN=str(self.path),VPHONE_FROZEN_PLAN_SHA256=self.digest,
            VPHONE_FROZEN_CONTEXT=json.dumps(self.context),VPHONE_TEST_VERIFIED_EXPORT=str(self.export),
            VPHONE_CFW_VARIANT='regular',VPHONE_VM_LOCK_FD=str(self.lock_fd),CFW_HOST_MNT=str(self.mount),VPHONE_GUEST_EVIDENCE=str(self.evidence))
        self.envpatch=patch.dict(os.environ,self.environment);self.envpatch.start();self.addCleanup(self.envpatch.stop)

    def publish(self):
        self.record['planSHA256']=hashlib.sha256(gate.canonical(self.plan)).hexdigest()
        self.context['planSHA256']=self.record['planSHA256']
        self.path=self.vm/'.firmware-desired-plan.json';self.path.write_bytes(gate.canonical(self.record))
        self.digest=hashlib.sha256(self.path.read_bytes()).hexdigest()
        self.export.write_bytes(gate.canonical(dict(schemaVersion=1,state='ready',rawSHA256=self.digest,record=self.record)))

    def load(self):
        return gate.load_plan(self.path,self.digest,self.context)

    def test_real_guarded_copy_and_patch_records_actual_bytes(self):
        target=self.mount/'mnt1/System/Library/LaunchDaemons/dropbear.plist';target.parent.mkdir(parents=True)
        target.write_bytes(b'old-target')
        source=self.stage/'dropbear.plist';source.write_bytes(plistlib.dumps({'ProgramArguments':['dropbear']}))
        with patch.object(sys,'argv',['cfw.py','patch-dropbear-plist',str(source)]):
            cfw.main()
        after=source.read_bytes()
        guest_write.run(self.load(),['/bin/cp',str(source),str(target)])
        self.assertEqual(target.read_bytes(),after)
        rows=[json.loads(line) for line in self.evidence.read_text().splitlines()]
        row=rows[-1]
        self.assertEqual(row['declarationID'],'system-launchdaemons-boot-install')
        self.assertEqual(row['target'],'system:/System/Library/LaunchDaemons/dropbear.plist')
        self.assertEqual(row['beforeSHA256'],hashlib.sha256(b'old-target').hexdigest())
        self.assertEqual(row['afterSHA256'],hashlib.sha256(after).hexdigest())
        self.assertEqual(row['planDigest'],self.record['planSHA256'])

    def test_unknown_target_or_declaration_cannot_write(self):
        plan=self.load();target=self.mount/'mnt1/unknown';source=self.stage/'data';source.write_bytes(b'new')
        with self.assertRaises(ValueError): guest_write.run(plan,['cp',str(source),str(target)])
        self.assertFalse(target.exists())
        with self.assertRaises(ValueError): gate.record_change(plan,'unknown','system:/usr/libexec/seputil',b'a',b'b')
        with self.assertRaises(ValueError): gate.authorize(plan,'system-seputil-boot-gigalocker_uuid-extra','system:/usr/libexec/seputil')

    def test_plan_change_after_load_preserves_target(self):
        plan=self.load();source=self.stage/'seputil';source.write_bytes(b'new')
        target=self.mount/'mnt1/usr/libexec/seputil';target.parent.mkdir(parents=True);target.write_bytes(b'old')
        self.path.write_bytes(self.path.read_bytes()+b' ')
        with self.assertRaises(ValueError):guest_write.run(plan,['cp',str(source),str(target)])
        self.assertEqual(target.read_bytes(),b'old')

    def test_target_rule_change_refused(self):
        plan=self.load();table,digest=guest_write.target_table()
        with patch.object(guest_write,'target_table',return_value=(table,'0'*64)):
            with self.assertRaises(ValueError):gate.authorize(plan,'system-seputil-boot-gigalocker_uuid','system:/usr/libexec/seputil')

    def test_unknown_schema_missing_context_and_preview_refused(self):
        for key in self.context:
            bad=dict(self.context);bad.pop(key)
            with self.assertRaises(ValueError):gate.load_plan(self.path,self.digest,bad)
        self.path.write_bytes(gate.canonical({'schemaVersion':1,'variant':'regular','selected':[]}))
        with self.assertRaises(ValueError):gate.load_plan(self.path,hashlib.sha256(self.path.read_bytes()).hexdigest(),self.context)

    def test_legacy_nil_and_profile_mismatch_cannot_promote_v2(self):
        for profile in [None,True]:
            self.plan['gates']['guestEnvironmentV2']=profile;self.publish()
            with self.assertRaises(ValueError):self.load()
        self.plan['gates']['guestEnvironmentV2']=True;self.context['guestEnvironment']='v2';self.publish()
        plan=self.load()
        with patch.dict(os.environ,{'VPHONE_GUEST_ENVIRONMENT':'classic'}):
            with self.assertRaises(ValueError):gate.validate_entry(plan,'cfw_install.sh')

    def test_linked_target_parent_preserves_external_file(self):
        outside=self.root/'external';outside.mkdir();(outside/'seputil').write_bytes(b'old')
        (self.mount/'mnt1/usr').mkdir();(self.mount/'mnt1/usr/libexec').symlink_to(outside)
        source=self.stage/'seputil';source.write_bytes(b'new')
        with self.assertRaises(ValueError):guest_write.run(self.load(),['cp',str(source),str(self.mount/'mnt1/usr/libexec/seputil')])
        self.assertEqual((outside/'seputil').read_bytes(),b'old')

    def test_changed_archive_member_refused_before_extraction(self):
        import tarfile
        archive=self.stage/'iosbinpack64.tar'
        with tarfile.open(archive,'w') as stream:
            info=tarfile.TarInfo('iosbinpack64/unknown-file');info.size=3;stream.addfile(info,io.BytesIO(b'new'))
        with self.assertRaises(ValueError):guest_write.run(self.load(),['/opt/homebrew/bin/gtar','-xf',str(archive),'-C',str(self.mount/'mnt1')])
        self.assertFalse((self.mount/'mnt1/iosbinpack64').exists())

    def test_missing_lock_or_evidence_refuses_before_target_write(self):
        source=self.stage/'data';source.write_bytes(b'new')
        target=self.mount/'mnt1/usr/libexec/seputil';target.parent.mkdir(parents=True);target.write_bytes(b'old')
        for key,value in [('VPHONE_VM_LOCK_FD','-1'),('VPHONE_GUEST_EVIDENCE',str(self.root/'outside.jsonl'))]:
            with patch.dict(os.environ,{key:value}):
                with self.assertRaises((ValueError,OSError)):guest_write.run(self.load(),['cp',str(source),str(target)])
            self.assertEqual(target.read_bytes(),b'old')

    def test_private_command_cannot_write_outside_bound_staging(self):
        source=self.stage/'data';source.write_bytes(b'new');outside=self.root/'output'
        with self.assertRaises(ValueError):guest_write.run(self.load(),['cp',str(source),str(outside)])
        self.assertFalse(outside.exists())

    def test_actual_target_table_bytes_change_invalidates_frozen_rules(self):
        plan=self.load();directory=self.root/'rules';directory.mkdir()
        table=json.loads((ROOT/'scripts/patchers/guest-targets.json').read_bytes())
        table['owners']['system:/usr/libexec/seputil'].append('unknown')
        (directory/'guest-targets.json').write_bytes(gate.canonical(table))
        with patch.object(guest_write,'__file__',str(directory/'guest_write.py')):
            with self.assertRaises(ValueError):gate.authorize(plan,'system-seputil-boot-gigalocker_uuid','system:/usr/libexec/seputil')

    def cryptex_fixture(self):
        from patchers import cryptex_source
        _,digest=guest_write.target_table()
        self.entries.append(dict(id='system-cryptex-boot-install',disposition='guestUncovered',
            recordRules=[{'literal':'guest-target-map-v1:'+digest+':system-cryptex-boot-install','hexadecimalOffsetSuffix':False}]))
        self.publish();plan=self.load()
        source=self.vm/'iPhone_Restore/AppOS.dmg';source.parent.mkdir();source.write_bytes(b'generation-image-bytes')
        original=self.vm/'.firmware-generations'/self.context['generationID']/'originals/iPhone_Restore/AppOS.dmg'
        original.parent.mkdir(parents=True);original.write_bytes(source.read_bytes())
        cache=self.stage/'CryptexAppOS.dmg';cryptex_source.prepare(plan,'appos',source,cache)
        mounted=self.mount/'mnt_appos';mounted.mkdir();(mounted/'file').write_bytes(b'actual-image-file')
        target=self.mount/'mnt1/System/Cryptexes/App';target.mkdir(parents=True)
        info=plistlib.dumps({'images':[{'image-path':str(cache),'system-entities':[{'mount-point':str(mounted)}]}]})
        return cryptex_source,plan,source,mounted,target,info

    def test_bound_cryptex_tree_copy_reads_back_actual_members(self):
        helper,plan,source,mounted,target,info=self.cryptex_fixture()
        with patch.object(helper.subprocess,'check_output',return_value=info):
            guest_write.run(plan,['cp','-R',str(mounted)+'/.',str(target)])
        self.assertEqual((target/'file').read_bytes(),b'actual-image-file')
        record=json.loads(self.evidence.read_text().splitlines()[-1])
        self.assertEqual(record['target'],'system:/System/Cryptexes/App')
        self.assertNotEqual(record['beforeSHA256'],record['afterSHA256'])

    def test_wrong_cryptex_image_refused_before_tree_removal(self):
        helper,plan,source,mounted,target,info=self.cryptex_fixture();(target/'preserve').write_bytes(b'old')
        with patch.object(helper.subprocess,'check_output',return_value=plistlib.dumps({'images':[]})):
            with self.assertRaises(ValueError):guest_write.run(plan,['rm','-rf',str(target)])
        self.assertEqual((target/'preserve').read_bytes(),b'old')
        source.write_bytes(b'changed')
        with self.assertRaises(ValueError):helper.prepare(plan,'appos',source,self.stage/'CryptexAppOS.dmg')

    def test_unknown_cache_is_rebuilt_by_bound_producer_before_stamp(self):
        helper,plan,source,mounted,target,info=self.cryptex_fixture()
        cache=self.stage/'CryptexAppOS.dmg'
        helper.marker(cache).unlink()
        cache.write_bytes(b'unknown-existing-image')
        helper.prepare(plan,'appos',source,cache)
        self.assertEqual(cache.read_bytes(),source.read_bytes())
        self.assertEqual(json.loads(helper.marker(cache).read_bytes())['cacheSHA256'],
                         hashlib.sha256(source.read_bytes()).hexdigest())
        cache=self.stage/'CryptexSystemOS.dmg';cache.write_bytes(b'unknown-decrypted-cache')
        def produce(input_path, output_path):
            self.assertEqual(input_path,source)
            self.assertFalse(output_path.exists())
            self.assertFalse(helper.marker(output_path).exists())
            output_path.write_bytes(b'controlled-decryption-result')
        with patch('cache_systemos.cache_systemos',side_effect=produce) as producer:
            helper.prepare(plan,'systemos',source,cache)
        producer.assert_called_once()
        self.assertEqual(cache.read_bytes(),b'controlled-decryption-result')
        self.assertEqual(json.loads(helper.marker(cache).read_bytes())['cacheSHA256'],
                         hashlib.sha256(cache.read_bytes()).hexdigest())

    def test_direct_python_patch_rejects_linked_guest_parent(self):
        outside=self.root/'external';outside.mkdir()
        source=outside/'seputil';source.write_bytes(b'prefix/%s.gl\0suffix')
        before=source.read_bytes()
        (self.mount/'mnt1/usr').mkdir()
        (self.mount/'mnt1/usr/libexec').symlink_to(outside)
        with patch.object(sys,'argv',['cfw.py','patch-seputil',str(self.mount/'mnt1/usr/libexec/seputil')]):
            with self.assertRaises(ValueError):cfw.main()
        self.assertEqual(source.read_bytes(),before)

    def test_bound_maxslide_write_preserves_decision_bytes_and_evidence(self):
        from tests.test_dsc_maxslide import build_cache, zeroed_slide, START
        _,digest=guest_write.target_table()
        self.entries.append(dict(id='dyld-boot-maxslide',disposition='guestUncovered',
            recordRules=[dict(literal='guest-target-map-v1:'+digest+':dyld-boot-maxslide',hexadecimalOffsetSuffix=False)]))
        self.publish()
        directory=self.mount/'mnt1/System/Library/Caches/com.apple.dyld';directory.mkdir(parents=True)
        target=directory/'dyld_shared_cache_arm64e'
        with patch.dict(os.environ,dict(VPHONE_FROZEN_PLAN_SHA256=self.digest,VPHONE_FROZEN_CONTEXT=json.dumps(self.context))):
            for start,valid in [(START+0x4000,False),(START,True)]:
                original=build_cache(size=0x17D504000,max_slide=0x20000000,start=start)
                target.write_bytes(original)
                with patch.object(sys,'argv',['cfw.py','patch-dsc-maxslide',str(directory)]), contextlib.redirect_stdout(io.StringIO()):
                    if valid:
                        with self.assertRaises(SystemExit) as exit: cfw.main()
                        self.assertEqual(exit.exception.code,0)
                    else:
                        with self.assertRaises(RuntimeError): cfw.main()
                after=zeroed_slide(original) if valid else original
                self.assertEqual(target.read_bytes(),after)
                row=json.loads(self.evidence.read_text().splitlines()[-1])
                self.assertEqual(row['beforeSHA256'],hashlib.sha256(original).hexdigest())
                self.assertEqual(row['afterSHA256'],hashlib.sha256(after).hexdigest())
                self.assertEqual(row['planDigest'],self.record['planSHA256'])

    def test_build_version_missing_build_cannot_turn_option_into_write(self):
        target=self.root/'SystemVersion.plist'
        original=plistlib.dumps({'ProductBuildVersion':'23B85'})
        for arguments in [[str(target),'--dry-run'],['--dry-run',str(target)],
                          [str(target),'23F77','--dry-run'],['--dry-run',str(target),'23F77']]:
            with self.subTest(arguments=arguments):
                target.write_bytes(original)
                with patch.dict(os.environ,{},clear=True):
                    result=subprocess.run([sys.executable,str(ROOT/'scripts/patchers/cfw.py'),'patch-build-version',*arguments],capture_output=True)
                self.assertEqual(target.read_bytes(),original,result.stderr)
                self.assertEqual(result.returncode==0,'23F77' in arguments,result.stderr)

    def test_dsc_final_symlink_preserves_external_cache(self):
        from tests.test_dsc_maxslide import build_cache
        _,digest=guest_write.target_table()
        self.entries.append(dict(id='dyld-boot-maxslide',disposition='guestUncovered',
            recordRules=[dict(literal='guest-target-map-v1:'+digest+':dyld-boot-maxslide',hexadecimalOffsetSuffix=False)]))
        self.publish()
        outside=self.root/'external-cache';original=build_cache(size=0x17D504000,max_slide=0x20000000)
        outside.write_bytes(original)
        directory=self.mount/'mnt1/dsc';directory.mkdir()
        (directory/'dyld_shared_cache_arm64e').symlink_to(outside)
        with patch.dict(os.environ,dict(VPHONE_FROZEN_PLAN_SHA256=self.digest,VPHONE_FROZEN_CONTEXT=json.dumps(self.context))), \
             patch.object(sys,'argv',['cfw.py','patch-dsc-maxslide',str(directory)]),contextlib.redirect_stdout(io.StringIO()):
            try: cfw.main()
            except (SystemExit,ValueError): pass
        self.assertEqual(outside.read_bytes(),original)
        self.assertEqual(self.evidence.read_bytes(),b'')

    def test_jb_exp_archive_root_and_content_moves_use_frozen_rules(self):
        # Use actual shipped archive member bytes and each installer's two move lines.
        import tarfile
        import io
        raw=subprocess.check_output(['/usr/bin/tar','-xOf',str(ROOT/'scripts/resources/cfw_jb_input.tar.zst'),
                                     'cfw_jb_input/jb/bootstrap-iphoneos-arm64.tar.zst'])
        raw=subprocess.check_output(['zstd','-dc'],input=raw)
        with tarfile.open(fileobj=io.BytesIO(raw)) as archive:
            member=next(item for item in archive if str(Path(item.name))=='var/jb/usr/bin/apt')
            payload=archive.extractfile(member).read()
        _,digest=guest_write.target_table()
        self.entries.append(dict(id='preboot-jb-bootstrap-install',disposition='guestUncovered',
            recordRules=[dict(literal='guest-target-map-v1:'+digest+':preboot-jb-bootstrap-install',hexadecimalOffsetSuffix=False)]))
        for variant in ('jb','exp'):
            with self.subTest(variant=variant):
                self.plan['variant']=variant;self.plan['gates']['variant']=variant;self.context['variant']=variant;self.publish()
                boot_hash=('A' if variant=='jb' else 'B')*96
                base=self.mount/'mnt5'/boot_hash/'jb-vphone'
                source=base/'var/jb/usr/bin/apt';source.parent.mkdir(parents=True);source.write_bytes(payload)
                lines=(ROOT/f'scripts/cfw_install_{variant}.sh').read_text().splitlines()
                moves=[line for line in lines if 'cfw_guest_write' in line and 'mv ' in line and '/procursus' in line]
                self.assertEqual(len(moves),2)
                # Do not mask a failure from the second actual installer command.
                body='\n'.join(line.removesuffix(' 2>/dev/null || true') for line in moves)
                env=dict(os.environ,VPHONE_FROZEN_PLAN_SHA256=self.digest,VPHONE_FROZEN_CONTEXT=json.dumps(self.context),
                         VPHONE_CFW_VARIANT=variant,PYTHON3=sys.executable,SCRIPT_DIR=str(ROOT/'scripts'),
                         MNT5=str(self.mount/'mnt5'),BOOT_HASH=boot_hash,JB_DIR_NAME='jb-vphone')
                result=subprocess.run(['/bin/zsh','-c','set -euo pipefail\nsource "$SCRIPT_DIR/lib/cfw_common.sh"\n'+body],
                                      env=env,pass_fds=(self.lock_fd,),capture_output=True,text=True)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual((base/'procursus/usr/bin/apt').read_bytes(),payload)
                self.assertFalse(source.exists())
                rows=[json.loads(line) for line in self.evidence.read_text().splitlines()]
                self.assertTrue(any(row['target'].endswith('/procursus') and row['planDigest']==self.record['planSHA256'] for row in rows))

    def test_unlisted_dsc_member_cannot_reach_writer(self):
        from tests.test_dsc_maxslide import build_cache
        _,digest=guest_write.target_table()
        self.entries.append(dict(id='dyld-boot-maxslide',disposition='guestUncovered',
            recordRules=[dict(literal='guest-target-map-v1:'+digest+':dyld-boot-maxslide',hexadecimalOffsetSuffix=False)]))
        self.publish()
        directory=self.mount/'mnt1/dsc';directory.mkdir()
        original=build_cache(size=0x17D504000,max_slide=0x20000000)
        (directory/'dyld_shared_cache_arm64e').write_bytes(original)
        outside=self.root/'external-cache';outside.write_bytes(original)
        (directory/'dyld_shared_cache_arm64e.unlisted').symlink_to(outside)
        with patch.dict(os.environ,dict(VPHONE_FROZEN_PLAN_SHA256=self.digest,VPHONE_FROZEN_CONTEXT=json.dumps(self.context))), \
             patch.object(sys,'argv',['cfw.py','patch-dsc-maxslide',str(directory)]),contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(ValueError):cfw.main()
        self.assertEqual(outside.read_bytes(),original)
        self.assertEqual((directory/'dyld_shared_cache_arm64e').read_bytes(),original)
        self.assertEqual(self.evidence.read_bytes(),b'')
