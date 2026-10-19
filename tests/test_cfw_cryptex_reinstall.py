"""Run the real regular installer to the DSC boundary on disposable trees."""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

from tests.test_cfw_host_isolation import HostDriverFixture
from tests import test_patch_plan_gate as gate_fixtures
from patchers import guest_write


class CryptexReinstallDriverTests(HostDriverFixture):
    def run_driver(self, options=(), variant='regular', **environment):
        vm=self.root/'vm'; vm.mkdir(exist_ok=True)
        disk=vm/'Disk.img'
        if not disk.exists(): disk.write_bytes(b'original')
        env=dict(self.env, TEST_MOUNTS=str(vm/'mount-table'), VPHONE_CFW_VARIANT=variant, **environment)
        child=subprocess.run(['/bin/zsh',str(self.driver),'--variant',variant,*options,str(vm)],
                             env=env,capture_output=True,timeout=30)
        return vm,child

    def test_explicit_option_reaches_installer_and_ambient_value_does_not_enable_it(self):
        for options,ambient,wanted in [(('--reinstall-cryptex',),'0','1'),((),'1','0')]:
            with self.subTest(options=options):
                vm,child=self.run_driver(options,VPHONE_REINSTALL_CRYPTEX=ambient)
                self.assertEqual(child.returncode,0,(child.stdout+child.stderr).decode())
                self.assertEqual((vm/'cryptex-reinstall-env').read_text().strip(),wanted)

    def test_unsupported_modes_and_profiles_refuse_before_staging(self):
        cases=[(('--reinstall-cryptex',),v) for v in ['dev','jb','exp']]
        cases += [(('--reinstall-cryptex','--guest-environment','v2'),'regular'),
                  (('--reinstall-cryptex','--update-environment'),'regular'),
                  (('--reinstall-cryptex','--generation','0'*64,'--undo-declaration','camera'),'regular')]
        for options,variant in cases:
            with self.subTest(options=options,variant=variant):
                vm,child=self.run_driver(options,variant)
                self.assertNotEqual(child.returncode,0)
                self.assertIn(b'--reinstall-cryptex requires regular/classic CFW installation',child.stderr)
                self.assertEqual((vm/'Disk.img').read_bytes(),b'original')
                self.assertFalse(list(vm.glob('.cfw_disk.*')))

    def test_sudo_reexec_preserves_the_explicit_option(self):
        original=self.driver.with_name('original-driver.sh')
        shutil.copyfile(ROOT/'scripts/cfw_install_host.sh',original)
        sudo=self.root/'.tools/bin/sudo'
        sudo.write_text('#!/bin/zsh\nprint -r -- "$*" > "$TEST_SUDO_CALL"\n')
        sudo.chmod(0o755)
        calls=self.root/'sudo-call'
        env=dict(self.env, PATH=str(sudo.parent)+':/usr/bin:/bin:/usr/sbin:/sbin',TEST_SUDO_CALL=str(calls))
        child=subprocess.run(['/bin/zsh',str(original),'--variant','regular','--reinstall-cryptex',str(self.root/'unused-vm')],env=env,capture_output=True,timeout=10)
        self.assertEqual(child.returncode,0,(child.stdout+child.stderr).decode())
        self.assertIn('--variant regular --reinstall-cryptex',calls.read_text())


class CryptexReinstallTests(unittest.TestCase):
    def run_installer(self, reinstall, *, existing_symlinks=False):
        tmp = tempfile.TemporaryDirectory(prefix='cfw cryptex reinstall ')
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name); scripts = root/'scripts'; (scripts/'lib').mkdir(parents=True)
        shutil.copyfile(ROOT/'scripts/cfw_install.sh', scripts/'cfw_install.sh')
        vm=root/'vm'; vm.mkdir(); mount=root/'mount'; mount.mkdir()
        system=mount/'mnt1'; (system/'System/Library/CoreServices').mkdir(parents=True)
        (system/'System/Library/Caches').mkdir()
        (system/'System/DriverKit/System/Library').mkdir(parents=True)
        (system/'System/Library/CoreServices/SystemVersion.plist').write_bytes(plistlib.dumps({'ProductVersion':'26.0'}))
        for name in ['OS','App']:
            old=system/'System/Cryptexes'/name; old.mkdir(parents=True); (old/'old-member').write_bytes(b'existing')
            source=root/('source-'+name); source.mkdir(); (source/'new-member').write_bytes(b'generation original')
            if name == 'OS':
                for tree in [old, source]:
                    (tree/'System/Library/Caches/com.apple.dyld').mkdir(parents=True)
                    (tree/'System/DriverKit/System/Library/dyld').mkdir(parents=True)
        if existing_symlinks:
            (system/'System/Library/Caches/com.apple.dyld').symlink_to(
                '../../../System/Cryptexes/OS/System/Library/Caches/com.apple.dyld')
            (system/'System/DriverKit/System/Library/dyld').symlink_to(
                '../../../../System/Cryptexes/OS/System/DriverKit/System/Library/dyld')
        restore=vm/'restore'; restore.mkdir()
        for name in ['SystemOS.dmg','AppOS.dmg']: (restore/name).write_bytes(b'bound source standin')
        runtime=root/'python'; runtime.write_text('''#!/bin/zsh
print -r -- "$*" >> "$TEST_CALLS"
if [[ "$1" == */cfw.py && "$2" == cryptex-paths ]]; then
  print SystemOS.dmg; print AppOS.dmg
elif [[ "$1" == */plan_gate.py && "$2" == mount-cryptex ]]; then
  local_name=App; [[ "$3" == *SystemOS* ]] && local_name=OS
  /bin/cp -R "$TEST_ROOT/source-$local_name/." "$4"
elif [[ "$1" == */cfw.py && "$2" == patch-iomfb-swapend ]]; then
  exit 75
fi
'''); runtime.chmod(0o755)
        bins=root/'bin'; bins.mkdir(); (bins/'ldid').symlink_to('/usr/bin/true')
        (scripts/'lib/cfw_common.sh').write_text('''
TAR=/usr/bin/tar
PYTHON3="$VPHONE_PYTHON"
cfw_require_runtime_and_lock() { :; }
cfw_guest_resources() { print -r -- "$TEST_ROOT/resources"; }
cfw_init_mounts() { MNT1="$CFW_HOST_MNT/mnt1"; MNT3="$CFW_HOST_MNT/mnt3"; }
check_prereqs() { :; }
find_restore_dir() { print -r -- "$VM_DIR/restore"; }
cfw_extract_input() { mkdir -p "$VM_DIR/cfw_input"; }
cleanup_on_exit() { :; }
mount_vol() { :; }
cfw_guest_write() { "$@"; }
cfw_cache_systemos() { /bin/cp "$1" "$2"; }
cfw_cache_appos() { /bin/cp "$1" "$2"; }
cfw_detach_with() { :; }
assert_mount_under_vm() { :; }
die() { print -u2 -r -- "$*"; exit 1; }
''')
        env=dict(os.environ, VPHONE_PYTHON=str(runtime), CFW_HOST_MNT=str(mount),
                 TEST_ROOT=str(root), TEST_CALLS=str(root/'calls'),
                 _VPHONE_PATH=str(bins)+':/usr/bin:/bin:/usr/sbin:/sbin')
        env.pop('VPHONE_REINSTALL_CRYPTEX',None)
        if reinstall is not None: env['VPHONE_REINSTALL_CRYPTEX']=reinstall
        child=subprocess.run(['/bin/zsh',str(scripts/'cfw_install.sh'),str(vm)],env=env,capture_output=True,timeout=10)
        return child, system, (root/'calls').read_text()

    def test_default_preserves_existing_cryptex_skip(self):
        child, system, calls=self.run_installer(None)
        self.assertEqual(child.returncode,75,child.stderr.decode())
        self.assertTrue((system/'System/Cryptexes/OS/old-member').exists())
        self.assertNotIn('mount-cryptex',calls)

    def test_explicit_reinstall_reads_sources_and_replaces_both_trees(self):
        child, system, calls=self.run_installer('1')
        self.assertEqual(child.returncode,75,child.stderr.decode())
        self.assertEqual(calls.count(' mount-cryptex '),2)
        for name in ['OS','App']:
            tree=system/'System/Cryptexes'/name
            self.assertFalse((tree/'old-member').exists())
            self.assertEqual((tree/'new-member').read_bytes(),b'generation original')

    def test_invalid_reinstall_value_refuses_before_guest_writes(self):
        child, system, calls=self.run_installer('unexpected')
        self.assertNotEqual(child.returncode,75)
        self.assertIn(b'invalid Cryptex reinstall setting',child.stderr)
        self.assertTrue((system/'System/Cryptexes/OS/old-member').exists())
        self.assertNotIn('mount-cryptex',calls)

    def test_existing_directory_symlinks_do_not_modify_cryptex_members(self):
        for reinstall in (None, '1'):
            with self.subTest(reinstall=reinstall):
                child, system, _ = self.run_installer(reinstall, existing_symlinks=True)
                self.assertEqual(child.returncode, 75, child.stderr.decode())
                for relative in ('System/Library/Caches/com.apple.dyld',
                                 'System/DriverKit/System/Library/dyld'):
                    link = system/relative
                    self.assertTrue(link.is_symlink())
                    self.assertEqual(list(link.resolve().iterdir()), [])


class GuestSymlinkWriteTests(unittest.TestCase):
    setUp = gate_fixtures.FrozenGateTests.setUp
    publish = gate_fixtures.FrozenGateTests.publish
    load = gate_fixtures.FrozenGateTests.load

    def link_target(self):
        _, digest = guest_write.target_table()
        self.entries.append(dict(id='system-cryptex-boot-install', disposition='guestUncovered',
            recordRules=[dict(literal='guest-target-map-v1:'+digest+':system-cryptex-boot-install',
                              hexadecimalOffsetSuffix=False)]))
        self.publish()
        target = self.mount/'mnt1/System/Library/Caches/com.apple.dyld'
        target.parent.mkdir(parents=True)
        directory = self.mount/'mnt1/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld'
        directory.mkdir(parents=True)
        relative = '../../../System/Cryptexes/OS/System/Library/Caches/com.apple.dyld'
        return target, directory, relative

    def test_following_directory_symlink_refuses_before_write(self):
        target, directory, relative = self.link_target()
        target.symlink_to(relative)
        for flags, suffix in (('-sf', ''), ('-sfn', '/')):
            with self.subTest(flags=flags, suffix=suffix):
                with self.assertRaisesRegex(ValueError, 'guest link command follows target directory'):
                    guest_write.run(self.load(), ['ln', flags, relative, str(target)+suffix])
                self.assertEqual(list(directory.iterdir()), [])

    def test_nofollow_link_replaces_exact_symlink_and_records_output(self):
        target, directory, relative = self.link_target()
        target.symlink_to(relative)
        guest_write.run(self.load(), ['ln', '-sfn', relative, str(target)])
        self.assertTrue(target.is_symlink())
        self.assertEqual(os.readlink(target), relative)
        self.assertEqual(list(directory.iterdir()), [])
        import json
        rows = [json.loads(line) for line in self.evidence.read_bytes().splitlines()]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['target'], 'system:/System/Library/Caches/com.apple.dyld')
        self.assertEqual(rows[0]['effect']['after']['link'], relative)

    def test_actual_directory_target_refuses_before_write(self):
        target, _, relative = self.link_target()
        target.mkdir()
        with self.assertRaisesRegex(ValueError, 'guest link command follows target directory'):
            guest_write.run(self.load(), ['ln', '-sfn', relative, str(target)])
        self.assertEqual(list(target.iterdir()), [])
