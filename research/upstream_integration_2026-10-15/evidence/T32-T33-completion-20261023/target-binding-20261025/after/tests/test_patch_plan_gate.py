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
        self.root = Path(self.temp.name).resolve()
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

    def test_binding_drift_refuses_entry_and_the_actual_guarded_writer(self):
        binding = self.vm / 'launchpad.json'
        raw = json.dumps({'bundle': '2.6.2'}).encode()
        binding.write_bytes(raw)
        expected = {'VPHONE_EXPECTED_BINDING_SHA256': hashlib.sha256(raw).hexdigest(),
                    'VPHONE_EXPECTED_CORE_BUNDLE': '2.6.2'}
        target = self.mount / 'mnt1/System/Library/LaunchDaemons/dropbear.plist'
        target.parent.mkdir(parents=True)
        target.write_bytes(b'preserve-target')
        source = self.stage / 'dropbear.plist'
        source.write_bytes(b'replacement')
        with patch.dict(os.environ, expected):
            plan = gate.from_environment()
            gate.recheck(plan)
            binding.write_text(json.dumps({'bundle': '2.6.3'}))
            with self.assertRaisesRegex(ValueError, 'binding changed'):
                gate.from_environment()
            with self.assertRaisesRegex(ValueError, 'binding changed'):
                guest_write.run(plan, ['cp', str(source), str(target)])
        self.assertEqual(target.read_bytes(), b'preserve-target')
        self.assertFalse(self.evidence.exists())

    def test_obsolete_implementation_refused_before_real_entrypoint_side_effects(self):
        self.plan['gates']['iosBaseIs27'] = True
        identifier = 'dyld-boot-iomfb_force_kern'
        _, digest = guest_write.target_table()
        self.entries.append(dict(id=identifier, disposition='guestUncovered', recordRules=[
            {'literal':'guest-target-map-v1:'+digest+':'+identifier, 'hexadecimalOffsetSuffix':False}]))
        self.publish()
        environment = dict(os.environ, VPHONE_FROZEN_PLAN_SHA256=self.digest,
                           VPHONE_FROZEN_CONTEXT=json.dumps(self.context))
        chunks = self.mount / 'mnt1/dsc'; chunks.mkdir()
        target = chunks / 'dyld_shared_cache_arm64e'
        commands = [
            [sys.executable, str(ROOT/'scripts/patchers/cfw.py'), 'patch-iomfb-force-kern', str(chunks)],
            [sys.executable, str(ROOT/'scripts/patchers/plan_gate.py'), 'entry', 'cfw_install_host.sh'],
            [sys.executable, str(ROOT/'scripts/patchers/plan_gate.py'), 'verify-final'],
            ['/bin/zsh', str(ROOT/'scripts/cfw_install.sh'), str(self.vm)],
        ]
        # Qualification must not depend on whether input looks new, old or
        # corrupt: none supplies authenticated originals or a current writer.
        for payload in (b'pristine-test-cache', b'previously-patched-test-cache', b''):
            target.write_bytes(payload)
            for command in commands:
                with self.subTest(payload=payload, command=command[1]):
                    result = subprocess.run(command, env=environment,
                                            capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn('target implementation unavailable', result.stderr)
                    self.assertEqual(target.read_bytes(), payload)
                    self.assertFalse(self.evidence.parent.exists())
                    self.assertNotIn('force-kern complete', result.stdout)

    def test_direct_writer_context_refuses_before_creating_evidence(self):
        self.entries.append(dict(id='dyld-boot-iomfb_force_kern', disposition='guestUncovered'))
        self.publish()
        plan = self.load()
        with self.assertRaisesRegex(ValueError, 'target implementation unavailable'):
            gate.require_write_context(plan)
        self.assertFalse(self.evidence.parent.exists())

    def test_excluded_implementation_does_not_block_other_writes(self):
        self.plan['gates']['iosBaseIs27'] = True
        source = self.stage / 'dropbear.plist'
        for group in ('excludedByVersion', 'excludedByVariant', 'excludedByOptIn', 'notImplemented'):
            with self.subTest(group=group):
                self.plan[group] = [dict(id='dyld-boot-iomfb_force_kern', disposition=group)]
                self.publish()
                source.write_bytes(plistlib.dumps({'ProgramArguments':['dropbear']}))
                before = source.read_bytes()
                with patch.dict(os.environ, {'VPHONE_FROZEN_PLAN_SHA256': self.digest,
                                             'VPHONE_FROZEN_CONTEXT': json.dumps(self.context)}), \
                     patch.object(sys, 'argv', ['cfw.py', 'patch-dropbear-plist', str(source)]):
                    cfw.main()
                self.assertNotEqual(source.read_bytes(), before)
                row = json.loads(self.evidence.read_text().splitlines()[-1])
                self.assertEqual(row['declarationID'], 'system-launchdaemons-boot-install')
                self.assertEqual(row['afterSHA256'], hashlib.sha256(source.read_bytes()).hexdigest())
                self.plan[group] = []

    def test_ios26_and_ios18_uncovered_id_allow_regular_write_but_not_legacy_writer(self):
        self.entries.append(dict(id='dyld-boot-iomfb_force_kern', disposition='guestUncovered'))
        source = self.stage / 'dropbear.plist'
        for ios18 in (False, True):
            with self.subTest(iosBaseIs18=ios18):
                self.plan['gates'].update(iosBaseIs27=False, iosBaseIs18=ios18)
                self.publish()
                source.write_bytes(plistlib.dumps({'ProgramArguments':['dropbear']}))
                with patch.dict(os.environ, {'VPHONE_FROZEN_PLAN_SHA256': self.digest,
                                             'VPHONE_FROZEN_CONTEXT': json.dumps(self.context)}):
                    with patch.object(sys, 'argv', ['cfw.py', 'patch-dropbear-plist', str(source)]):
                        cfw.main()
                    previous = self.evidence.read_bytes()
                    with patch.object(sys, 'argv', ['cfw.py', 'patch-iomfb-force-kern', str(self.mount)]):
                        with self.assertRaisesRegex(ValueError, 'target implementation unavailable'):
                            cfw.main()
                    self.assertEqual(self.evidence.read_bytes(), previous)
                row = json.loads(previous.splitlines()[-1])
                self.assertEqual(row['declarationID'], 'system-launchdaemons-boot-install')
                self.assertEqual(row['afterSHA256'], hashlib.sha256(source.read_bytes()).hexdigest())

    def test_old_target_refuses_new_execution_without_changing_evidence(self):
        self.record['upstreamTarget'] = '2d21d21fbdd4f51f013616273ceda9b35a3e0789'
        self.context['upstreamTarget'] = self.record['upstreamTarget']
        self.publish()
        before = self.path.read_bytes()
        with patch.dict(os.environ, {'VPHONE_FROZEN_PLAN_SHA256': self.digest,
                                     'VPHONE_FROZEN_CONTEXT': json.dumps(self.context)}), \
             patch.object(sys, 'argv', ['cfw.py', 'patch-iomfb-force-kern', str(self.mount)]):
            with self.assertRaisesRegex(ValueError, 'desired plan encoding/target mismatch'):
                cfw.main()
        self.assertEqual(self.path.read_bytes(), before)
        self.assertFalse(self.evidence.parent.exists())

    def test_selected_implementation_is_also_refused(self):
        self.plan['selected'] = [dict(id='dyld-boot-iomfb_force_kern', disposition='selected')]
        self.publish()
        with self.assertRaisesRegex(ValueError, 'target implementation unavailable'):
            gate.require_supported_implementations(self.load())

    def test_force_kern_dry_run_is_explicitly_isolated_and_read_only(self):
        output = io.StringIO()
        with patch.object(sys, 'argv', ['cfw.py', 'patch-iomfb-force-kern', '/unused', '--dry-run']), \
             patch.object(cfw, '_dispatch') as dispatch, contextlib.redirect_stdout(output):
            cfw.main()
        dispatch.assert_called_once_with(dry_run=True)
        self.assertIn('ISOLATED diagnostic only', output.getvalue())
        self.assertFalse(self.evidence.parent.exists())

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
            self.assertEqual(input_path,self.vm/'.firmware-generations'/self.context['generationID']/'originals'/source.relative_to(self.vm))
            self.assertEqual(input_path.read_bytes(),source.read_bytes())
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

    def test_data_companion_symlink_refuses_before_dispatch(self):
        self.assert_companion_symlink_refuses('dyld_shared_cache_arm64e.33.dylddata')

    def test_readonly_companion_symlink_refuses_before_dispatch(self):
        self.assert_companion_symlink_refuses('dyld_shared_cache_arm64e.34.dyldreadonly')

    def test_linkedit_companion_symlink_refuses_before_dispatch(self):
        self.assert_companion_symlink_refuses('dyld_shared_cache_arm64e.35.dyldlinkedit')

    def test_atlas_companion_symlink_refuses_before_dispatch(self):
        self.assert_companion_symlink_refuses('dyld_shared_cache_arm64e.atlas')

    def assert_companion_symlink_refuses(self, name):
        from tests.test_dsc_maxslide import build_cache
        _, digest = guest_write.target_table()
        self.entries.append(dict(id='dyld-boot-maxslide', disposition='guestUncovered',
            recordRules=[dict(literal='guest-target-map-v1:'+digest+':dyld-boot-maxslide', hexadecimalOffsetSuffix=False)]))
        self.publish()
        directory = self.mount/'mnt1/dsc'; directory.mkdir()
        original = build_cache(size=0x17D504000, max_slide=0x20000000)
        (directory/'dyld_shared_cache_arm64e').write_bytes(original)
        outside = self.root/'companion-external'; outside.write_bytes(original)
        (directory/name).symlink_to(outside)
        with patch.dict(os.environ, dict(VPHONE_FROZEN_PLAN_SHA256=self.digest, VPHONE_FROZEN_CONTEXT=json.dumps(self.context))), \
             patch.object(sys, 'argv', ['cfw.py','patch-dsc-maxslide',str(directory)]), \
             patch.object(cfw, '_dispatch') as dispatch:
            with self.assertRaisesRegex(ValueError, 'non-linked regular'): cfw.main()
            dispatch.assert_not_called()
        self.assertEqual(outside.read_bytes(), original)
        self.assertEqual(self.evidence.read_bytes(), b'')

    def test_explicit_signer_records_patch_sign_copy_and_rejects_code_restoration(self):
        from patchers import component_effects as effects
        from tests.test_component_signatures import signed_macho
        target=self.mount/'mnt1/usr/libexec/seputil';target.parent.mkdir(parents=True)
        source=self.stage/'seputil';source.write_bytes(signed_macho(b'00000000'))
        plan=self.load();gate.require_write_context(plan)
        store=self.evidence.parent/'effect-blobs'
        before=effects.capture_input(source,store); before_row=gate.snapshot(source)
        data=bytearray(source.read_bytes());data[256]=ord('1');source.write_bytes(data)
        first=effects.capture_change(before,source,store)
        gate.append_evidence(plan,'system-seputil-boot-gigalocker_uuid','system:/usr/libexec/seputil',source,before_row,gate.snapshot(source),effect=first)
        signer=self.root/'ldid';signed=self.root/'signed';signed.write_bytes(signed_macho(b'10000000',{'new':True}))
        signer.write_text('#!/bin/sh\nfor final; do :; done\n/bin/cp '+str(signed)+' "$final"\n');signer.chmod(0o755)
        guest_write.sign(plan,[str(signer),'-S','-M',str(source)])
        guest_write.run(plan,['cp',str(source),str(target)])
        rows=[json.loads(line) for line in self.evidence.read_text().splitlines()]
        effects.verify_rows(plan,rows,{'system':self.mount/'mnt1'},store)
        self.assertEqual(rows[1]['effect']['operation'],'sign')
        self.assertEqual(rows[1]['effect']['signerArguments'],['-S','-M',str(source)])
        signed.write_bytes(signed_macho(b'00000000',{'new':True}))
        with self.assertRaisesRegex(ValueError,'executable bytes'):
            guest_write.sign(plan,[str(signer),'-S','-M',str(source)])

    def test_signing_unknown_private_basename_refuses_before_signer(self):
        plan=self.load();source=self.stage/'unknown';source.write_bytes(b'original')
        signer=self.root/'ldid';signer.write_text('#!/bin/sh\nexit 42\n');signer.chmod(0o755)
        with self.assertRaisesRegex(ValueError,'signing source'):
            guest_write.sign(plan,[str(signer),'-S',str(source)])
        self.assertEqual(source.read_bytes(),b'original')

    def test_common_signing_function_emits_producer_evidence(self):
        from tests.test_component_signatures import signed_macho
        key=self.vm/'cfw_input/signcert.p12';key.parent.mkdir();key.write_bytes(b'fixture signing key')
        source=self.stage/'seputil';source.write_bytes(signed_macho())
        signed=self.root/'signed';signed.write_bytes(signed_macho(entitlements={'new':1}))
        signer=self.root/'ldid';signer.write_text('#!/bin/sh\nfor final; do :; done\n/bin/cp '+str(signed)+' "$final"\n');signer.chmod(0o755)
        env=dict(os.environ,PATH=str(self.root)+':'+os.environ['PATH'],PYTHON3=sys.executable,
                 SCRIPT_DIR=str(ROOT/'scripts'),VM_DIR=str(self.vm),CFW_INPUT='cfw_input',TEMP_DIR=str(self.stage))
        result=subprocess.run(['/bin/zsh','-c','set -euo pipefail\nsource "$SCRIPT_DIR/lib/cfw_common.sh"\nldid_sign "$TEMP_DIR/seputil" com.apple.seputil'],env=env,pass_fds=(self.lock_fd,),capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(self.evidence.exists(),'actual common signer emitted no producer evidence')
        row=json.loads(self.evidence.read_text().splitlines()[-1])
        self.assertEqual(row['effect']['operation'],'sign')
        self.assertEqual(row['effect']['signerArguments'],['-S','-M','-K'+str(self.vm/'cfw_input/signcert.p12'),'-Icom.apple.seputil',str(source)])

    def test_campo_patch_is_verified_as_final_embedded_entitlements(self):
        from patchers import component_effects as effects
        from tests.test_component_signatures import signed_macho
        _,digest=guest_write.target_table()
        self.entries.append(dict(id='system-campo-cfw-entitlements',disposition='guestUncovered',
            recordRules=[dict(literal='guest-target-map-v1:'+digest+':system-campo-cfw-entitlements',hexadecimalOffsetSuffix=False)]))
        self.publish();os.environ.update(VPHONE_FROZEN_PLAN_SHA256=self.digest,VPHONE_FROZEN_CONTEXT=json.dumps(self.context))
        source=self.stage/'Campo';source.write_bytes(signed_macho())
        ent=self.stage/'Campo.entitlements';ent.write_bytes(plistlib.dumps({'test':True}))
        with patch.object(sys,'argv',['cfw.py','patch-campo-entitlements',str(ent)]),contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaises(SystemExit) as result: cfw.main()
            self.assertEqual(result.exception.code,0)
        signed=self.root/'signed';signed.write_bytes(signed_macho(entitlements=plistlib.loads(ent.read_bytes())))
        signer=self.root/'ldid';signer.write_text('#!/bin/sh\nfor final; do :; done\n/bin/cat '+str(signed)+' > "$final"\n');signer.chmod(0o755)
        plan=self.load();guest_write.sign(plan,[str(signer),'-S'+str(ent),'-M',str(source)])
        target=self.mount/'mnt1/Applications/Campo.app/Campo';target.parent.mkdir(parents=True)
        guest_write.run(plan,['cp',str(source),str(target)])
        rows=[json.loads(line) for line in self.evidence.read_text().splitlines()]
        effects.verify_rows(plan,rows,{'system':self.mount/'mnt1'},self.evidence.parent/'effect-blobs')
        rows[1]['effect']['entitlementsSource']['path']=str(self.stage/'unrelated')
        with self.assertRaises(ValueError): effects.verify_rows(plan,rows,{'system':self.mount/'mnt1'},self.evidence.parent/'effect-blobs')

    def staged_signing_transaction(self, name='initial'):
        import cfw_disk_txn
        gate.require_write_context(self.load())
        original=self.vm/'Disk.img'
        if not original.exists(): original.write_bytes(b'original synthetic disk')
        staged=self.evidence.parent/'Disk.img';staged.write_bytes(b'staged synthetic disk')
        record={'version':2,'provenanceMode':'required','id':name,'status':'staged','vm':str(self.vm),
                'original':cfw_disk_txn.identity(original.stat()),'staged':cfw_disk_txn.identity(staged.stat())}
        (self.evidence.parent/'transaction.json').write_text(json.dumps(record))
        return name

    @contextlib.contextmanager
    def handed_back_staging_owner(self):
        # Safe ownership seam: hand_back_artifacts returns .cfw_temp to the
        # invoker; the next producer has a different effective uid. Host shell
        # hand-back selection itself runs in test_cfw_host_isolation.
        real=Path.lstat;stage=self.stage;foreign=os.geteuid()+1
        def observed(path,*args,**kwargs):
            info=real(path,*args,**kwargs)
            if path==stage:
                values=list(info);values[4]=foreign;return os.stat_result(values)
            return info
        with patch.object(Path,'lstat',observed): yield

    def test_v2_signature_after_host_handoff_and_failed_attempt_retry(self):
        from tests.test_component_signatures import signed_macho, SigningCommandSpaceTests
        from patchers import component_effects as effects
        self.plan['gates']['guestEnvironmentV2']=True;self.context['guestEnvironment']='v2';self.publish()
        plan=self.load();self.staged_signing_transaction()
        target=self.mount/'mnt1/sbin/launchd';target.parent.mkdir()
        initial, text = SigningCommandSpaceTests.signed_injection_input()
        target.write_bytes(initial)
        original=target.read_bytes()
        with self.handed_back_staging_owner():
            for attempt in ('initial','retry'):
                with self.subTest(attempt=attempt):
                    try:
                        with guest_write.signing_directory(plan,transaction_id=json.loads((self.evidence.parent/'transaction.json').read_text())['id']) as directory:
                            source=directory/'launchd'
                            guest_write.run(plan,['cp',str(target),str(source)])
                            guest_write.inject_v2(plan,source)
                            def signer(argv):
                                if attempt=='initial': raise subprocess.CalledProcessError(9,argv)
                                import struct
                                body=bytearray(source.read_bytes()[:4096]);body.extend(b'\0'*(4096-len(body)))
                                count,size=struct.unpack_from('<II',body,16)
                                struct.pack_into('<II',body,16,count+1,size+16)
                                tail=signed_macho()[4096:]
                                struct.pack_into('<IIII',body,32+size,0x1d,16,4096,len(tail))
                                data=body+tail;data[4168:4200]=hashlib.sha256(data[:4096]).digest();source.write_bytes(data)
                            if attempt=='initial':
                                with self.assertRaises(subprocess.CalledProcessError):
                                    guest_write.sign(plan,['ldid','-S',str(source)],execute=signer)
                            else:
                                guest_write.sign(plan,['ldid','-S',str(source)],execute=signer)
                                guest_write.run(plan,['cp',str(source),str(target)])
                    except ValueError as error:
                        self.fail('normal handed-back staging blocked v2 producer: '+str(error))
                    if attempt=='initial': self.assertEqual(target.read_bytes(),original)
                    else:
                        self.assertIn(b'/vh',target.read_bytes())
                        self.assertEqual(target.read_bytes()[text:4096],original[text:4096])
                        self.assertIn(b'uuid-preserved!!',target.read_bytes())
                if attempt=='initial':
                    # A host retry gets a fresh staged transaction and evidence.
                    self.evidence=self.vm/'.cfw_disk.retry/guest-changes.jsonl'
                    os.environ['VPHONE_GUEST_EVIDENCE']=str(self.evidence)
                    self.staged_signing_transaction('retry')
        rows=[json.loads(line) for line in self.evidence.read_text().splitlines()]
        effects.verify_rows(plan,rows,{'system':self.mount/'mnt1'},self.evidence.parent/'effect-blobs')

    def test_v2_signing_uses_registered_private_directory(self):
        from tests.test_component_signatures import signed_macho
        self.plan['gates']['guestEnvironmentV2']=True;self.context['guestEnvironment']='v2';self.publish()
        plan=self.load();self.staged_signing_transaction()
        signer=self.root/'ldid';signer.write_text('#!/bin/sh\nexit 0\n');signer.chmod(0o755)
        with guest_write.signing_directory(plan,transaction_id=json.loads((self.evidence.parent/'transaction.json').read_text())['id']) as directory:
            source=directory/'launchd';source.write_bytes(signed_macho())
            guest_write.sign(plan,[str(signer),'-S',str(source)])
            for mode in [0o770,0o777]:
                directory.chmod(mode)
                with self.assertRaises(ValueError): guest_write.sign(plan,[str(signer),'-S',str(source)])
            directory.chmod(0o700)
            self.evidence.parent.chmod(0o777)
            with self.assertRaises(ValueError): guest_write.sign(plan,[str(signer),'-S',str(source)])
            self.evidence.parent.chmod(0o700)
            with patch.object(os,'geteuid',return_value=os.geteuid()+1):
                with self.assertRaises(ValueError): guest_write.sign(plan,[str(signer),'-S',str(source)])
            nested=directory/'nested';nested.mkdir();(nested/'launchd').write_bytes(signed_macho())
            with self.assertRaises(ValueError): guest_write.sign(plan,[str(signer),'-S',str(nested/'launchd')])
            external=self.root/'external-launchd';external.write_bytes(source.read_bytes());source.unlink();source.symlink_to(external)
            with self.assertRaises(ValueError): guest_write.sign(plan,[str(signer),'-S',str(source)])
            source.unlink();source.write_bytes(external.read_bytes())
            wrong=directory/'seputil';wrong.write_bytes(signed_macho())
            with self.assertRaises(ValueError): guest_write.sign(plan,[str(signer),'-S',str(wrong)])
        fake=self.evidence.parent/'.vphone-launchd-abcdefgh';fake.mkdir(mode=0o700)
        source=fake/'launchd';source.write_bytes(signed_macho())
        with self.assertRaises(ValueError): guest_write.sign(plan,[str(signer),'-S',str(source)])

    def test_v2_signer_cannot_switch_work_root_during_execution(self):
        from tests.test_component_signatures import signed_macho
        self.plan['gates']['guestEnvironmentV2']=True;self.context['guestEnvironment']='v2';self.publish()
        plan=self.load();transaction_id=self.staged_signing_transaction()
        other=self.vm/'.cfw_disk.other';other.mkdir(mode=0o700)
        with guest_write.signing_directory(plan,transaction_id=transaction_id) as directory:
            source=directory/'launchd';source.write_bytes(signed_macho())
            def signer(_): os.environ['VPHONE_GUEST_EVIDENCE']=str(other/'guest-changes.jsonl')
            with self.assertRaises(ValueError): guest_write.sign(plan,['ldid','-S',str(source)],execute=signer)
        self.assertFalse((other/'guest-changes.jsonl').exists())

    def test_v2_registration_requires_current_staged_transaction_and_private_work_root(self):
        import cfw_disk_txn
        self.plan['gates']['guestEnvironmentV2']=True;self.context['guestEnvironment']='v2';self.publish()
        plan=self.load();transaction_id=self.staged_signing_transaction()
        record_path=self.evidence.parent/'transaction.json';original=record_path.read_bytes()
        record=json.loads(original)
        cases=[dict(record,status='published'),dict(record,id='another'),dict(record,vm=str(self.root)),
               dict(record,staged=dict(record['staged'],ino=record['staged']['ino']+1)),
               dict(record,original=dict(record['original'],ino=record['original']['ino']+1))]
        for value in cases:
            with self.subTest(record=value):
                record_path.write_text(json.dumps(value))
                with self.assertRaises((ValueError,cfw_disk_txn.Refused)):
                    with guest_write.signing_directory(plan,transaction_id=transaction_id): self.fail('unqualified transaction admitted')
        record_path.write_bytes(original)
        with self.assertRaises(ValueError):
            with guest_write.signing_directory(plan): self.fail('missing transaction ID admitted')
        work=self.evidence.parent
        for mode in (0o755,0o770,0o777):
            work.chmod(mode)
            with self.assertRaises(ValueError):
                with guest_write.signing_directory(plan,transaction_id=transaction_id): self.fail('nonprivate work admitted')
        work.chmod(0o700)
        with patch.object(os,'geteuid',return_value=os.geteuid()+1):
            with self.assertRaises(ValueError):
                with guest_write.signing_directory(plan,transaction_id=transaction_id): self.fail('foreign work admitted')
        actual=self.vm/'.cfw_disk.actual';work.rename(actual);work.symlink_to(actual,target_is_directory=True)
        try:
            with self.assertRaises(ValueError):
                with guest_write.signing_directory(plan,transaction_id=transaction_id): self.fail('linked work admitted')
        finally: work.unlink();actual.rename(work)
        with patch.dict(os.environ,{'VPHONE_GUEST_EVIDENCE':str(self.stage/'guest-changes.jsonl')}):
            with self.assertRaises(ValueError):
                with guest_write.signing_directory(plan,transaction_id=transaction_id): self.fail('old staging root admitted')

    def test_v2_registered_source_rechecks_transaction_and_directory_before_injection(self):
        from tests.test_component_signatures import signed_macho
        self.plan['gates']['guestEnvironmentV2']=True;self.context['guestEnvironment']='v2';self.publish()
        plan=self.load();transaction_id=self.staged_signing_transaction()
        record_path=self.evidence.parent/'transaction.json';original=record_path.read_bytes()
        with guest_write.signing_directory(plan,transaction_id=transaction_id) as directory:
            source=directory/'launchd';source.write_bytes(signed_macho());before=source.read_bytes()
            record=json.loads(original);record['status']='aborted';record_path.write_text(json.dumps(record))
            with self.assertRaises(ValueError): guest_write.inject_v2(plan,source)
            record_path.write_bytes(original)
            with patch.object(os,'geteuid',return_value=os.geteuid()+1):
                with self.assertRaises(ValueError): guest_write.inject_v2(plan,source)
            directory.chmod(0o777)
            with self.assertRaises(ValueError): guest_write.inject_v2(plan,source)
            directory.chmod(0o700)
            self.assertEqual(source.read_bytes(),before)
            renamed=directory.with_name(directory.name+'-original');directory.rename(renamed)
            directory.mkdir(mode=0o700);(directory/'launchd').write_bytes(before)
            try:
                with self.assertRaises(ValueError): guest_write.inject_v2(plan,source)
                self.assertEqual(source.read_bytes(),before)
            finally:
                (directory/'launchd').unlink();directory.rmdir();renamed.rename(directory)
        for parent in (self.stage,self.evidence.parent):
            fake=parent/'.vphone-launchd-abcdefgh';fake.mkdir(mode=0o700);source=fake/'launchd';source.write_bytes(before)
            with self.assertRaises(ValueError): guest_write.inject_v2(plan,source)
            self.assertEqual(source.read_bytes(),before)

    def test_v2_reinstallation_writes_have_final_effects(self):
        from tests.test_cfw_env_install import InstallTests
        from tests.test_cfw_env_update import macho, LC_LOAD_WEAK_DYLIB, LC_LOAD_DYLIB
        from patchers import component_effects as effects
        import shutil
        fixture=InstallTests();fixture.setUp();self.addCleanup(fixture.doCleanups)
        self.plan['gates']['guestEnvironmentV2']=True;self.context['guestEnvironment']='v2';self.publish()
        self.assertEqual(fixture.install(),0)
        shutil.copytree(fixture.vm/'.create-checkpoint',self.vm/'.create-checkpoint')
        system=self.mount/'mnt1'
        shutil.copytree(fixture.system,system,dirs_exist_ok=True,symlinks=True)
        shutil.copytree(fixture.vm/'cfw_input',self.vm/'cfw_input',dirs_exist_ok=True)
        plan=self.load();gate.require_write_context(plan)
        code=fixture.installer.install_mounted(system,self.vm,fixture.stage,fixture.daemon,self.root/'v2-report.json',
             variant='regular',owner=(os.getuid(),os.getgid()),runner=fixture.runner,frozen_plan=plan)
        self.assertEqual(code,0,(self.root/'v2-report.json').read_text())
        rows=[json.loads(line) for line in self.evidence.read_text().splitlines()]
        self.assertTrue(rows)
        effects.verify_rows(plan,rows,{'system':system},self.evidence.parent/'effect-blobs')

    def test_archive_two_real_moves_and_consumption_preserve_required_member(self):
        from patchers import component_effects as effects
        import tarfile
        table=json.loads(json.dumps(guest_write.target_table()[0]))
        names=['var','var/jb','var/jb/usr','var/jb/usr/bin','var/jb/usr/bin/apt']
        table['archives']['bootstrap-iphoneos-arm64.tar']={name:table['archives']['bootstrap-iphoneos-arm64.tar'][name] for name in names}
        digest=hashlib.sha256(gate.canonical(table)).hexdigest()
        declaration='preboot-jb-bootstrap-install'
        self.entries[:]=[dict(id=declaration,disposition='guestUncovered',recordRules=[dict(literal='guest-target-map-v1:'+digest+':'+declaration,hexadecimalOffsetSuffix=False)])]
        self.plan.update(variant='jb');self.plan['gates']['variant']='jb';self.context['variant']='jb';self.publish()
        boot='A'*96;base=self.mount/'mnt5'/boot/'jb-vphone';base.mkdir(parents=True)
        source=self.stage/'bootstrap-iphoneos-arm64.tar'
        with tarfile.open(source,'w') as archive:
            for name in names:
                member=tarfile.TarInfo(name);member.mode=0o755
                if name.endswith('/apt'):
                    member.size=8;archive.addfile(member,io.BytesIO(b'required'))
                else: member.type=tarfile.DIRTYPE;archive.addfile(member)
        archive_path=base.parent/source.name
        with patch.object(guest_write,'target_table',return_value=(table,digest)):
            plan=self.load()
            guest_write.run(plan,['cp',str(source),str(archive_path)])
            guest_write.run(plan,['tar','-xf',str(archive_path),'-C',str(base)])
            lines=(ROOT/'scripts/cfw_install_jb.sh').read_text().splitlines()
            moves=[line for line in lines if 'cfw_guest_write' in line and 'mv ' in line and '/procursus' in line]
            for line in moves:
                emit='cfw_guest_write() { '+sys.executable+" -c 'import json,sys;print(json.dumps(sys.argv[1:]))' \"$@\"; }\n"
                result=subprocess.run(['/bin/zsh','-c',emit+line.removesuffix(' 2>/dev/null || true')],
                    env=dict(os.environ,MNT5=str(self.mount/'mnt5'),BOOT_HASH=boot,JB_DIR_NAME='jb-vphone'),capture_output=True,text=True)
                self.assertEqual(result.returncode,0,result.stderr)
                guest_write.run(plan,json.loads(result.stdout))
            guest_write.run(plan,['rm','-rf',str(base/'procursus/jb')])
            guest_write.run(plan,['rm','-f',str(archive_path)])
            rows=[json.loads(line) for line in self.evidence.read_text().splitlines()]
            effects.verify_rows(plan,rows,{'preboot':self.mount/'mnt5'},self.evidence.parent/'effect-blobs')
            guest_write.run(plan,['rm','-f',str(base/'procursus/usr/bin/apt')])
            rows=[json.loads(line) for line in self.evidence.read_text().splitlines()]
            with self.assertRaises(ValueError):effects.verify_rows(plan,rows,{'preboot':self.mount/'mnt5'},self.evidence.parent/'effect-blobs')

    def test_cryptex_image_member_effects_before_and_after_tree_copy_compose(self, hardlinked=False, build_version=False):
        from patchers import component_effects as effects, cryptex_source
        from tests.test_component_signatures import signed_macho
        import struct
        import shutil
        def cache(code):
            data=bytearray(signed_macho(code));data[:16]=b'dyld_v1 arm64e'.ljust(16,b' ')
            struct.pack_into('<QQ',data,0x28,4096,len(data)-4096)
            data[4168:4200]=hashlib.sha256(data[:4096]).digest();return data
        _,digest=guest_write.target_table()
        declarations=['system-cryptex-boot-install','dyld-exp-hv_vmm','dyld-cfw-camera']
        if build_version:
            declarations.append('system-systemversion-cfw-build_version');self.context['spoofBuild']='23Z999999'
        for declaration in declarations:
            self.entries.append(dict(id=declaration,disposition='guestUncovered',recordRules=[dict(literal='guest-target-map-v1:'+digest+':'+declaration,hexadecimalOffsetSuffix=False)]))
        self.plan['variant']='exp';self.plan['gates']['variant']='exp';self.context['variant']='exp';self.publish()
        if build_version:
            os.environ.update(VPHONE_CFW_VARIANT='exp',VPHONE_FROZEN_PLAN_SHA256=self.digest,
                              VPHONE_FROZEN_CONTEXT=json.dumps(self.context))
        plan=self.load();gate.require_write_context(plan);store=self.evidence.parent/'effect-blobs'
        relative=Path('System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e')
        earlier=self.mount/'mnt_sysos_hv_vmm'/relative;earlier.parent.mkdir(parents=True)
        image=self.stage/'CryptexSystemOS.dmg';image.write_bytes(b'image association fixture')
        original=self.vm/'.firmware-generations'/self.context['generationID']/'originals/SystemOS.dmg'
        original.parent.mkdir(parents=True);original.write_bytes(b'original fixture')
        initial=cryptex_source.observation(image)
        binding=dict(schemaVersion=1,generationID=self.context['generationID'],planDigest=plan.record['planSHA256'],source=str(original),sourceSHA256=cryptex_source.file_sha(original),cacheSHA256=initial['sha256'],imageBefore=initial)
        earlier.write_bytes(cache(b'00000000'));before=effects.capture_input(earlier,store);observed=gate.snapshot(earlier)
        (self.mount/'mnt_sysos_hv_vmm'/'required-sibling').write_bytes(b'unchanged sibling')
        if build_version:
            version_relative=Path('System/Library/CoreServices/SystemVersion.plist')
            version_source=self.mount/'mnt_sysos_hv_vmm'/version_relative
            version_source.parent.mkdir(parents=True)
            version_source.write_bytes(plistlib.dumps({'ProductBuildVersion':'23A341','ProductVersion':'26.0'}))
            version_original=effects.capture_input(version_source,store)
        if hardlinked:
            os.link(self.mount/'mnt_sysos_hv_vmm/required-sibling',
                    self.mount/'mnt_sysos_hv_vmm/required-sibling-alias')
        binding['baselineTree']=cryptex_source.tree(self.mount/'mnt_sysos_hv_vmm')
        cryptex_source.marker(image).write_bytes(gate.canonical(binding))
        earlier.write_bytes(cache(b'10000000'))
        gate.append_evidence(plan,'dyld-exp-hv_vmm','dsc:/'+earlier.name,earlier,observed,gate.snapshot(earlier),source_image=image,source_binding=cryptex_source.proof(plan,image),effect=effects.capture_change(before,earlier,store))
        image.write_bytes(b'changed image fixture')
        with patch.object(cryptex_source.subprocess,'check_output',return_value=plistlib.dumps({'images':[]})):
            cryptex_source.refresh(plan,image)
        source=self.mount/'mnt_sysos';shutil.copytree(self.mount/'mnt_sysos_hv_vmm',source)
        (source/'required-sibling').write_bytes(b'unchanged sibling')
        if hardlinked:
            (source/'required-sibling-alias').unlink()
            os.link(source/'required-sibling',source/'required-sibling-alias')
        destination=self.mount/'mnt1/System/Cryptexes/OS';destination.mkdir(parents=True)
        info=plistlib.dumps({'images':[{'image-path':str(image),'system-entities':[{'mount-point':str(source)}]}]})
        from contextlib import nullcontext
        require_readonly=effects.regular.require_readonly
        def source_mount_is_readonly(reader):
            if source in reader.path.parents:
                self.assertTrue(reader.readonly_source)
                return
            return require_readonly(reader)
        # Only the mount's readonly flag and hdiutil table are fixtures;
        # source traversal, actual cp, effects and final verification run.
        readonly_fixture=(patch.object(effects.regular,'require_readonly',source_mount_is_readonly)
                          if hardlinked else nullcontext())
        with patch.object(cryptex_source.subprocess,'check_output',return_value=info), readonly_fixture:
            guest_write.run(plan,['cp','-R',str(source)+'/.',str(destination)])
        if hardlinked:
            self.assertEqual((destination/'required-sibling').stat().st_nlink,1)
            self.assertEqual((destination/'required-sibling-alias').stat().st_nlink,1)
        final=destination/relative;before=effects.capture_input(final,store);observed=gate.snapshot(final)
        final.write_bytes(cache(b'10000001'))
        gate.append_evidence(plan,'dyld-cfw-camera','dsc:/'+final.name,final,observed,gate.snapshot(final),effect=effects.capture_change(before,final,store))
        if build_version:
            version_final=destination/version_relative;version_stage=self.stage/'version.plist'
            guest_write.run(plan,['cp',str(version_final),str(version_stage)])
            with patch.object(sys,'argv',['cfw.py','patch-build-version',str(version_stage),'23Z999999']):
                with self.assertRaises(SystemExit) as result:cfw.main()
                self.assertEqual(result.exception.code,0)
            guest_write.run(plan,['cp',str(version_stage),str(version_final)])
        rows=[json.loads(line) for line in self.evidence.read_text().splitlines()]
        roots={'system':self.mount/'mnt1','dsc':final.parent}
        outputs=effects.verify_rows(plan,rows,roots,store)
        if build_version:
            from patchers import file_undo
            version_target='system:/System/Cryptexes/OS/'+str(version_relative)
            entries=file_undo.build(plan,rows,outputs,store,{'members':{
                version_target:{'state':version_original,'kind':'data'}}})
            self.assertEqual(len(entries),1)
            self.assertEqual(entries[0]['target'],version_target)
            self.assertEqual(entries[0]['originalSHA256'],version_original['sha256'])
            self.assertEqual(entries[0]['finalSHA256'],effects.digest(version_final))
            self.assertEqual({op['declarationID'] for op in entries[0]['operations']},
                             {'system-systemversion-cfw-build_version'})
        import copy
        forged=copy.deepcopy(rows);forged[1]['sourceImageProof']['image']['sha256']='0'*64
        with self.assertRaises(ValueError): effects.verify_rows(plan,forged,roots,store)
        forged=copy.deepcopy(rows);forged[1]['sourceImageProof']['bindingSHA256']=forged[0]['sourceImageProof']['bindingSHA256']
        with self.assertRaises(ValueError): effects.verify_rows(plan,forged,roots,store)
        (destination/'required-sibling').unlink()
        with self.assertRaises(ValueError): effects.verify_rows(plan,rows,roots,store)

    def test_exp_cryptex_hardlinks_survive_transform_copy_and_effect_verification(self):
        self.test_cryptex_image_member_effects_before_and_after_tree_copy_compose(hardlinked=True)

    def test_exp_tree_copy_then_staged_build_version_keeps_original_and_effects(self):
        self.test_cryptex_image_member_effects_before_and_after_tree_copy_compose(hardlinked=True,build_version=True)

    def test_later_unrelated_copy_cannot_discard_installed_content(self):
        from patchers import component_effects as effects
        plan=self.load();source=self.stage/'dropbear.plist'
        target=self.mount/'mnt1/System/Library/LaunchDaemons/dropbear.plist';target.parent.mkdir(parents=True)
        source.write_bytes(b'required first installation');guest_write.run(plan,['cp',str(source),str(target)])
        source.write_bytes(b'unrelated replacement');guest_write.run(plan,['cp',str(source),str(target)])
        rows=[json.loads(line) for line in self.evidence.read_text().splitlines()]
        with self.assertRaises(ValueError): effects.verify_rows(plan,rows,{'system':self.mount/'mnt1'},self.evidence.parent/'effect-blobs')

    def test_actual_jb_daemon_injection_preserves_earlier_plist_changes(self):
        from patchers import component_effects as effects
        self.plan['variant']='jb';self.plan['gates']['variant']='jb';self.context['variant']='jb'
        self.entries[:]=[e for e in self.entries if e['id']!='system-launchdaemons-boot-environment'];self.publish()
        os.environ.update(VPHONE_FROZEN_PLAN_SHA256=self.digest,VPHONE_FROZEN_CONTEXT=json.dumps(self.context))
        plan=self.load();target=self.mount/'mnt1/System/Library/xpc/launchd.plist';target.parent.mkdir(parents=True)
        target.write_bytes(plistlib.dumps({'LaunchDaemons':{'existing':{'Label':'existing'}}}))
        source=self.stage/'launchd.plist'
        for name,resource in [('jb-setup','vphone_jb_setup.plist'),('sshd','vphone_sshd.plist')]:
            guest_write.run(plan,['cp',str(target),str(source)])
            with patch.object(sys,'argv',['cfw.py','inject-jb-daemon',str(source),str(ROOT/'scripts'/resource),'/System/Library/LaunchDaemons/com.vphone.'+name+'.plist']):
                cfw.main()
            guest_write.run(plan,['cp',str(source),str(target)])
        rows=[json.loads(line) for line in self.evidence.read_text().splitlines()]
        effects.verify_rows(plan,rows,{'system':self.mount/'mnt1'},self.evidence.parent/'effect-blobs')
        self.assertEqual(len(plistlib.loads(target.read_bytes())['LaunchDaemons']),3)

    def test_production_final_reader_qualifies_staged_image_and_mounts(self):
        from patchers import final_guest, component_effects as effects
        import cfw_disk_txn
        plan=self.load();source=self.stage/'dropbear.plist';source.write_bytes(b'required')
        target=self.mount/'mnt1/System/Library/LaunchDaemons/dropbear.plist';target.parent.mkdir(parents=True)
        guest_write.run(plan,['cp',str(source),str(target)])
        work=self.evidence.parent;image=work/'Disk.img';image.write_bytes(b'staged fixture')
        (work/'transaction.json').write_text(json.dumps({'version':2,'provenanceMode':'required','status':'staged','vm':str(self.vm),'staged':cfw_disk_txn.identity(image.stat())}))
        readonly=True
        def query(argv):
            if argv in (['/usr/sbin/diskutil','info','-plist','/dev/disk42s1'],
                        ['/usr/sbin/diskutil','info','-plist',str(self.mount/'mnt1')]):
                return plistlib.dumps({'DeviceIdentifier':'disk42s1','MountPoint':str(self.mount/'mnt1'),'ReadOnlyVolume':readonly})
            if argv==['/usr/bin/hdiutil','info','-plist']:
                return plistlib.dumps({'images':[{'image-path':str(image),'system-entities':[{'dev-entry':'/dev/disk41'}]}]})
            if argv==['/usr/sbin/diskutil','apfs','list','-plist']:
                return plistlib.dumps({'Containers':[{'ContainerReference':'disk42','PhysicalStores':[{'DeviceIdentifier':'disk41s1'}],
                    'Volumes':[{'DeviceIdentifier':'disk42s1','MountPoint':str(self.mount/'mnt1')}]}]})
            self.fail(str(argv))
        with patch.object(final_guest.subprocess,'check_output',side_effect=query) as observed:
            result=final_guest.run(plan)
            self.assertEqual(result['operationsSHA256'],effects.digest(self.evidence))
            observed.assert_any_call(['/usr/sbin/diskutil','info','-plist',str(self.mount/'mnt1')])
            target.write_bytes(b'overwritten')
            with self.assertRaises(ValueError): final_guest.run(plan)
            target.write_bytes(b'required')
            readonly=False
            with patch.object(final_guest.subprocess,'run'):
                with self.assertRaises(ValueError): final_guest.run(plan)
            with patch.object(final_guest.subprocess,'run',side_effect=subprocess.CalledProcessError(1,['umount'])):
                with self.assertRaises(subprocess.CalledProcessError): final_guest.run(plan)
            # Simulate the filesystem visibility change at the mount seam.
            # These are directory renames; no real mount command is executed.
            root=self.mount/'mnt1';hidden=self.mount/'hidden-system';commands=[]
            def remount(argv,**kwargs):
                nonlocal readonly
                commands.append(argv)
                if argv[0]=='/sbin/umount': root.rename(hidden)
                else:
                    root.rmdir();hidden.rename(root);readonly=True
            with patch.object(final_guest.subprocess,'run',side_effect=remount):
                final_guest.run(plan)
            self.assertEqual(commands,[['/sbin/umount',str(root)],
                ['/sbin/mount_apfs','-o','rdonly','/dev/disk42s1',str(root)]])
            readonly=True
        with patch.object(final_guest.subprocess,'check_output',return_value=plistlib.dumps({'images':[]})):
            with self.assertRaises(ValueError): final_guest.run(plan)
        replacement=work/'replacement';replacement.write_bytes(image.read_bytes());replacement.replace(image)
        with patch.object(final_guest.subprocess,'check_output',side_effect=query):
            with self.assertRaises((ValueError,cfw_disk_txn.Refused)): final_guest.run(plan)

    def test_actual_tree_preparation_and_final_member_readback(self):
        from patchers import component_effects as effects
        helper,plan,source,mounted,target,info=self.cryptex_fixture()
        (target/'obsolete').write_bytes(b'old tree')
        with patch.object(helper.subprocess,'check_output',return_value=info):
            guest_write.run(plan,['rm','-rf',str(target)])
            guest_write.run(plan,['mkdir','-p',str(target)])
            guest_write.run(plan,['chmod','0755',str(target)])
            guest_write.run(plan,['cp','-R',str(mounted)+'/.',str(target)])
        rows=[json.loads(line) for line in self.evidence.read_text().splitlines()]
        effects.verify_rows(plan,rows,{'system':self.mount/'mnt1'},self.evidence.parent/'effect-blobs')

    def test_v2_initial_install_actual_loader_producer_and_controlled_signer(self):
        from tests.test_cfw_env_install import InstallTests
        from tests.test_cfw_host_isolation import HostIsolationTests
        # Execute the actual host cleanup/hand-back shell against command
        # doubles on this same disposable VM before the v2 ownership seam.
        host=HostIsolationTests();host.setUp();self.addCleanup(host.doCleanups)
        fcntl.flock(self.lock_fd,fcntl.LOCK_UN)
        try:
            _vm,process=host.start(str(self.vm),variant='regular',**host.sudo_invoker())
            status,output=host.finish(process)
            self.assertEqual(status,0,output)
            self.assertIn(str(self.stage.resolve()),host.chowned_paths())
        finally: fcntl.flock(self.lock_fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        from tests.test_component_signatures import signed_macho
        from patchers import component_effects as effects, component_signatures as signatures
        import shutil
        import struct
        fixture=InstallTests();fixture.setUp();self.addCleanup(fixture.doCleanups)
        _, digest = guest_write.target_table()
        self.entries.append(dict(id='system-vphoned-boot-install',disposition='guestUncovered',
            recordRules=[dict(literal='guest-target-map-v1:'+digest+':system-vphoned-boot-install',hexadecimalOffsetSuffix=False)]))
        self.plan['gates']['guestEnvironmentV2']=True;self.context['guestEnvironment']='v2';self.publish()
        os.environ.update(VPHONE_FROZEN_PLAN_SHA256=self.digest,VPHONE_FROZEN_CONTEXT=json.dumps(self.context))
        shutil.copytree(fixture.vm/'.create-checkpoint',self.vm/'.create-checkpoint')
        system=self.mount/'mnt1';shutil.copytree(fixture.system,system,dirs_exist_ok=True,symlinks=True)
        shutil.copytree(fixture.vm/'cfw_input',self.vm/'cfw_input',dirs_exist_ok=True)
        launchd=system/'sbin/launchd';launchd.write_bytes(signed_macho(entitlements={'original-entitlement':True}))
        def runner(args):
            args=list(map(str,args))
            if Path(args[0]).name=='insert_dylib':
                return subprocess.run(args,capture_output=True,check=True)
            elif '-e' in args:
                return subprocess.CompletedProcess(args,0,plistlib.dumps(signatures.entitlements(args[-1])[0]),b'')
            else:
                path=Path(args[-1]);body=bytearray(path.read_bytes()[:4096]);body.extend(b'\0'*(4096-len(body)))
                count,size=struct.unpack_from('<II',body,16)
                struct.pack_into('<II',body,16,count+1,size+16)
                tail=signed_macho(entitlements={'original-entitlement':True})[4096:]
                struct.pack_into('<IIII',body,32+size,0x1d,16,4096,len(tail))
                data=body+tail;data[4168:4200]=hashlib.sha256(data[:4096]).digest();path.write_bytes(data)
            return subprocess.CompletedProcess(args,0,b'',b'')
        plan=self.load();gate.require_write_context(plan)
        boot_plist=(system/'System/Library/xpc/launchd.plist').resolve();store=self.evidence.parent/'effect-blobs'
        old=gate.snapshot(boot_plist);before=effects.capture_input(boot_plist,store)
        value=plistlib.loads(boot_plist.read_bytes());value['LaunchDaemons']['preserved-boot-job']={'Label':'preserved-boot-job'}
        boot_plist.write_bytes(plistlib.dumps(value))
        gate.append_evidence(plan,'system-launchdaemons-boot-install','system:/System/Library/xpc/launchd.plist',boot_plist,old,gate.snapshot(boot_plist),effect=effects.capture_change(before,boot_plist,store))
        # Run the actual base API staging function before v2. Its preflight
        # is a candidate-check double; emitted write commands use the real gate.
        guest = self.root/'base-guest';(guest/'api').mkdir(parents=True)
        (guest/'api/vphoned').write_bytes(signed_macho())
        (guest/'api/vphoned.plist').write_bytes((ROOT/'sources/VPhoneDaemon/Configuration/vphoned.plist').read_bytes())
        checks = self.root/'base-checker';checks.mkdir()
        (checks/'check_guest_api.py').write_text('pass\n')
        import shlex
        emit = shlex.quote(sys.executable) + " -B -c 'import json,sys;print(\"COMMAND \"+json.dumps(sys.argv[1:]))' \"$@\""
        shell = 'source "$1"; cfw_guest_write() { ' + emit + '; }; cfw_stage_api "$2"'
        result = subprocess.run(['/bin/zsh','-c',shell,'fixture',str(ROOT/'scripts/lib/cfw_common.sh'),str(guest)],
            env=dict(os.environ,SCRIPT_DIR=str(checks),VPHONE_PYTHON=sys.executable,
                     VPHONE_GUEST_ENVIRONMENT='v2',MNT1=str(system.resolve())),capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        for line in result.stdout.splitlines():
            if line.startswith('COMMAND '): guest_write.run(plan,json.loads(line.removeprefix('COMMAND ')))
        # Cached classic API jobs must also be excluded from the base merge.
        jobs=self.vm/'cfw_input/jb/LaunchDaemons';jobs.mkdir(parents=True)
        (jobs/'vphoned-api.plist').write_bytes((guest/'api/vphoned.plist').read_bytes())
        base_plist=self.stage/'launchd.plist'
        guest_write.run(plan,['cp',str(boot_plist),str(base_plist)])
        with patch.object(sys,'argv',['cfw.py','inject-daemons',str(base_plist),str(jobs)]):
            cfw.main()
        guest_write.run(plan,['cp',str(base_plist),str(boot_plist)])
        transaction_id=self.staged_signing_transaction()
        with self.handed_back_staging_owner():
            code=fixture.installer.install_mounted(system,self.vm,fixture.stage,fixture.daemon,self.root/'v2-initial-report.json',
                 variant='regular',owner=(os.getuid(),os.getgid()),runner=runner,transaction_id=transaction_id,frozen_plan=plan)
        self.assertEqual(code,0,(self.root/'v2-initial-report.json').read_text())
        rows=[json.loads(line) for line in self.evidence.read_text().splitlines()]
        effects.verify_rows(plan,rows,{'system':system},self.evidence.parent/'effect-blobs')
        self.assertTrue(any(row['effect']['operation']=='sign' for row in rows))

    def test_unknown_transport_operation_does_not_gain_proof(self):
        from patchers import component_effects as effects
        plan=self.load();source=self.stage/'dropbear.plist';source.write_bytes(b'payload')
        target=self.mount/'mnt1/System/Library/LaunchDaemons/dropbear.plist';target.parent.mkdir(parents=True)
        guest_write.run(plan,['cp',str(source),str(target)])
        rows=[json.loads(line) for line in self.evidence.read_text().splitlines()]
        rows[0]['effect']['command']='unrecognized'
        with self.assertRaises(ValueError): effects.verify_rows(plan,rows,{'system':self.mount/'mnt1'},self.evidence.parent/'effect-blobs')

    def test_regular_v2_boot_plist_copy_keeps_exact_boot_owner(self):
        self.plan['gates']['guestEnvironmentV2']=True;self.context['guestEnvironment']='v2';self.publish()
        plan=self.load();source=self.stage/'launchd.plist';source.write_bytes(plistlib.dumps({'LaunchDaemons':{}}))
        target=self.mount/'mnt1/System/Library/xpc/launchd.plist';target.parent.mkdir(parents=True)
        guest_write.run(plan,['cp',str(source),str(target)])
        row=json.loads(self.evidence.read_text().splitlines()[-1])
        self.assertEqual(row['declarationID'],'system-launchdaemons-boot-install')

    def test_v2_boot_copy_cannot_choose_the_environment_owner_when_boot_writer_is_missing(self):
        self.plan['gates']['guestEnvironmentV2']=True;self.context['guestEnvironment']='v2'
        self.entries[:]=[entry for entry in self.entries if entry['id']!='system-launchdaemons-boot-install'];self.publish()
        source=self.stage/'launchd.plist';source.write_bytes(b'unknown copy')
        target=self.mount/'mnt1/System/Library/xpc/launchd.plist';target.parent.mkdir(parents=True);target.write_bytes(b'preserve')
        with self.assertRaises(ValueError): guest_write.run(self.load(),['cp',str(source),str(target)])
        self.assertEqual(target.read_bytes(),b'preserve')


class ExpectedCoreBindingTests(unittest.TestCase):
    def test_expected_binding_is_rechecked_before_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            vm = Path(directory)
            binding = vm / 'launchpad.json'
            raw = json.dumps({'bundle': '2.6.2', 'guestEnvironment': '2.6.1'}).encode()
            binding.write_bytes(raw)
            expected = {'VPHONE_EXPECTED_BINDING_SHA256': hashlib.sha256(raw).hexdigest(),
                        'VPHONE_EXPECTED_CORE_BUNDLE': '2.6.2'}
            with patch.dict(os.environ, expected):
                gate.verify_expected_binding(vm)
                binding.write_text(json.dumps({'bundle': '2.6.3'}))
                with self.assertRaisesRegex(ValueError, 'binding changed'):
                    gate.verify_expected_binding(vm)
            binding.write_bytes(raw)
            with patch.dict(os.environ, {**expected, 'VPHONE_EXPECTED_CORE_BUNDLE': ''}):
                with self.assertRaisesRegex(ValueError, 'incomplete'):
                    gate.verify_expected_binding(vm)
            with patch.dict(os.environ, {**expected, 'VPHONE_EXPECTED_BINDING_SHA256': 'bad'}):
                with self.assertRaisesRegex(ValueError, 'incomplete'):
                    gate.verify_expected_binding(vm)
            binding.unlink()
            binding.symlink_to(vm / 'untrusted')
            (vm / 'untrusted').write_bytes(raw)
            with patch.dict(os.environ, expected):
                with self.assertRaises(OSError):
                    gate.verify_expected_binding(vm)
