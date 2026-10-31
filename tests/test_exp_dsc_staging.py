"""Exercise EXP/base shell ordering on private staged-guest directory fixtures."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]


class EXPDSCStagingTests(unittest.TestCase):
    def run_stage(self,variant='exp',fail=''):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);scripts=root/'scripts';(scripts/'lib').mkdir(parents=True)
            for name in ('cfw_install.sh','cfw_install_exp.sh','patch_hv_vmm_userland.sh','patch_camera_userland.sh'):
                shutil.copy2(ROOT/'scripts'/name,scripts/name)
            vm=root/'vm';restore=vm/'iPhone_Test_Restore';restore.mkdir(parents=True)
            for name in ('SystemOS.dmg','AppOS.dmg'):(restore/name).write_bytes(b'bound image fixture')
            mount=root/'mount';system=mount/'mnt1'
            (system/'System/Library/CoreServices').mkdir(parents=True)
            (system/'System/Library/CoreServices/SystemVersion.plist').write_bytes(plistlib.dumps({'ProductVersion':'26.0'}))
            (system/'System/Library/Caches').mkdir()
            (system/'System/DriverKit/System/Library').mkdir(parents=True)
            relative='System/Library/Caches/com.apple.dyld'
            for name in ('OS','App'):
                source=root/('source-'+name);source.mkdir()
                if name=='OS':
                    dsc=source/relative;dsc.mkdir(parents=True)
                    (dsc/'dyld_shared_cache_arm64e').write_bytes(b'original header')
                    (dsc/'dyld_shared_cache_arm64e.42').write_bytes(b'original DSC')
            overlay=scripts/'resources/cfw_dev';overlay.mkdir(parents=True)
            (overlay/'rpcserver_ios').write_bytes(b'overlay fixture')
            bins=root/'bin';bins.mkdir();(bins/'ldid').symlink_to('/usr/bin/true')
            runtime=root/'python-fixture'
            runtime.write_text('#!'+sys.executable+'\n'+r'''
import json,os,pathlib,shutil,sys
a=sys.argv[1:];root=pathlib.Path(os.environ['STAGE_ROOT'])
with (root/'calls.jsonl').open('a') as f:f.write(json.dumps(a)+'\n')
if a[0].endswith('dev_overlay.py'):
    assert pathlib.Path(a[1]).read_bytes()==b'archive fixture'
    assert pathlib.Path(a[2]).read_bytes()==b'overlay fixture'
elif a[0].endswith('cfw.py') and a[1]=='cryptex-paths':print('SystemOS.dmg\nAppOS.dmg')
elif a[0].endswith('plan_gate.py') and a[1]=='mount-cryptex':
    target=pathlib.Path(a[3])
    if target.name=='mnt_sysos_hv_vmm':
        print('writable source image is unstable',file=sys.stderr);sys.exit(88)
    name='OS' if target.name=='mnt_sysos' else 'App'
    target.mkdir(exist_ok=True);shutil.copytree(root/('source-'+name),target,dirs_exist_ok=True)
elif a[0].endswith('cfw.py') and a[1].startswith('patch-'):
    command=a[1];target=pathlib.Path(a[2])
    expected=root/'mount/mnt1/System/Cryptexes/OS/System/Library/Caches/com.apple.dyld'
    assert target==expected, str(target)
    file=target/'dyld_shared_cache_arm64e.42'
    if command=='patch-iomfb-swapend':sys.exit(75) # Stop before unrelated base stages.
    wanted='patch-hv-vmm-dsc' if os.environ['STAGE_FAIL']=='hv' else 'patch-camera-dsc'
    if os.environ['STAGE_FAIL'] and command==wanted:sys.exit(19)
    value=file.read_bytes()
    if command=='patch-hv-vmm-dsc':assert value==b'original DSC';file.write_bytes(value+b'|hv')
    elif command=='patch-camera-dsc':assert value==b'original DSC|hv';file.write_bytes(value+b'|camera')
    else:raise AssertionError(command)
''')
            runtime.chmod(0o755)
            (scripts/'lib/cfw_common.sh').write_text('''
TAR=/usr/bin/tar
PYTHON3="$VPHONE_PYTHON"
cfw_require_runtime_and_lock() { :; }
cfw_guest_resources() { print -r -- "$STAGE_ROOT/resources"; }
cfw_init_mounts() { MNT1="$CFW_HOST_MNT/mnt1"; MNT3="$CFW_HOST_MNT/mnt3"; }
check_prereqs() { :; }
find_restore_dir() { print -r -- "$VM_DIR/iPhone_Test_Restore"; }
cfw_extract_input() { mkdir -p "$VM_DIR/cfw_input/jb"; print -rn -- 'archive fixture' > "$VM_DIR/cfw_input/jb/iosbinpack64.tar"; }
cleanup_on_exit() { :; }
mount_vol() { :; }
cfw_guest_write() { "$@"; }
cfw_cache_systemos() { /bin/cp "$1" "$2"; }
cfw_cache_appos() { /bin/cp "$1" "$2"; }
cfw_detach_with() { :; }
assert_mount_under_vm() { :; }
die() { print -u2 -- "$*"; exit 1; }
''')
            env=dict(os.environ,PATH=str(bins)+':/usr/bin:/bin:/usr/sbin:/sbin',STAGE_ROOT=str(root),
                STAGE_FAIL=fail,VPHONE_PYTHON=str(runtime),CFW_HOST_MNT=str(mount),VPHONE_CFW_VARIANT=variant)
            entry=scripts/('cfw_install_exp.sh' if variant=='exp' else 'cfw_install.sh')
            result=subprocess.run(['/bin/zsh',str(entry),str(vm)],env=env,capture_output=True,text=True)
            calls=[json.loads(line) for line in (root/'calls.jsonl').read_text().splitlines()]
            destination=system/'System/Cryptexes/OS'/relative/'dyld_shared_cache_arm64e.42'
            return result,calls,destination.read_bytes() if destination.exists() else None,(root/'source-OS'/relative/'dyld_shared_cache_arm64e.42').read_bytes()

    def test_exp_patches_staged_guest_after_copy_before_iomfb(self):
        result,calls,installed,source=self.run_stage()
        self.assertEqual(result.returncode,75,result.stdout+result.stderr)
        commands=[a[1] for a in calls if a[0].endswith('cfw.py') and a[1].startswith('patch-')]
        self.assertEqual(commands,['patch-hv-vmm-dsc','patch-camera-dsc','patch-iomfb-swapend'])
        self.assertEqual(installed,b'original DSC|hv|camera');self.assertEqual(source,b'original DSC')
        self.assertFalse(any(a[1]=='mount-cryptex' and a[3].endswith('mnt_sysos_hv_vmm') for a in calls if len(a)>3))

    def test_regular_keeps_original_dsc_before_iomfb(self):
        result,calls,installed,source=self.run_stage('regular')
        self.assertEqual(result.returncode,75,result.stdout+result.stderr)
        self.assertEqual(installed,source)
        self.assertFalse(any(a[1] in ('patch-hv-vmm-dsc','patch-camera-dsc') for a in calls if len(a)>1))

    def test_exp_producer_error_stops_before_iomfb(self):
        for fail in ('hv','camera'):
            with self.subTest(fail=fail):
                result,calls,_,source=self.run_stage(fail=fail)
                self.assertEqual(result.returncode,19,result.stdout+result.stderr)
                self.assertFalse(any(a[1]=='patch-iomfb-swapend' for a in calls if len(a)>1))
                self.assertEqual(source,b'original DSC')


if __name__=='__main__':unittest.main()
