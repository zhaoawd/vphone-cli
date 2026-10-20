"""Publish two real v4 journals and Undo using the actual Swift plan verifier.

APFS queries, the DSC patch output and raw-image flush use fixtures. Disk inode
swaps, plan validation, source indexes, checkpoints and archives run real code.
"""
import contextlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import sys
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT))
sys.path.insert(0,str(ROOT/'scripts'))
import cfw_disk_txn as txn
from patchers import cfw, cryptex_source, final_guest, guest_undo, guest_write, plan_gate as gate
from tests.test_undo_provenance import cache

vm = Path(sys.argv[1])


def publish(index):
    work = vm/f'.cfw_disk.identity{index}'; work.mkdir(mode=0o700)
    mount = vm/f'.cfw_mount.identity{index}'; (mount/'mnt1').mkdir(parents=True)
    os.environ.update(VPHONE_GUEST_EVIDENCE=str(work/'guest-changes.jsonl'),CFW_HOST_MNT=str(mount))
    fd = os.open(vm/'Disk.img',os.O_RDONLY)
    args = SimpleNamespace(vm=vm,work=work,fd=fd,owner_pid=os.getpid(),guest_evidence=True,exit_code=0,retain_staged=False)

    def query(argv):
        root = str(mount/'mnt1')
        if argv[0] == '/usr/bin/hdiutil':
            return plistlib.dumps({'images':[{'image-path':str(work/'Disk.img'),'system-entities':[{'dev-entry':'/dev/disk41'}]}]})
        if argv[1:3] == ['apfs','list']:
            return plistlib.dumps({'Containers':[{'ContainerReference':'disk42','PhysicalStores':[{'DeviceIdentifier':'disk41s1'}],
                'Volumes':[{'DeviceIdentifier':'disk42s1','MountPoint':root}]}]})
        return plistlib.dumps({'ReadOnlyVolume':True,'DeviceIdentifier':'disk42s1','MountPoint':root})

    try:
        with patch.object(txn,'holders',return_value=[]), contextlib.redirect_stdout(io.StringIO()):
            txn.stage(args)
            plan = gate.from_environment()
            stage = vm/'.cfw_temp'; stage.mkdir(exist_ok=True)
            source = stage/'dropbear.plist'; source.write_bytes(plistlib.dumps({'ProgramArguments':['dropbear']}))
            target = mount/'mnt1/System/Library/LaunchDaemons/dropbear.plist'; target.parent.mkdir(parents=True)
            guest_write.run(plan,['cp',str(source),str(target)])
            original = next((vm/'.firmware-generations'/plan.context['generationID']/'originals').glob('*Restore/SystemOS.dmg'))
            source_image = vm/original.relative_to(vm/'.firmware-generations'/plan.context['generationID']/'originals')
            image = stage/'CryptexSystemOS.dmg'
            source_mount = mount/'mnt_sysos'; source_mount.mkdir()
            dsc = source_mount/guest_undo.undo.DSC_MEMBER/'dyld_shared_cache_arm64e'
            dsc.parent.mkdir(parents=True); dsc.write_bytes(cache(b'initial'))
            dsc.with_name('dyld_shared_cache_arm64e.33.dylddata').write_bytes(cache(b'original companion'))
            dsc.with_name('dyld_shared_cache_arm64e.34.dyldreadonly').write_bytes(cache(b'original readonly'))
            dsc.with_name('dyld_shared_cache_arm64e.35.dyldlinkedit').write_bytes(cache(b'original linkedit'))
            dsc.with_name('dyld_shared_cache_arm64e.atlas').write_bytes(b'AA01 original atlas')
            def source_query(argv):
                if argv[0] == '/usr/sbin/diskutil':
                    return plistlib.dumps({'ReadOnlyVolume':True,'MountPoint':str(source_mount)})
                return plistlib.dumps({'images':[{'image-path':str(image),'system-entities':[{'mount-point':str(source_mount)}]}]})
            import cache_systemos
            with patch.object(cache_systemos,'cache_systemos',side_effect=shutil.copyfile):
                cryptex_source.prepare(plan,'systemos',source_image,image)
            with patch.object(cryptex_source.subprocess,'run'), patch.object(cryptex_source.subprocess,'check_output',side_effect=source_query):
                cryptex_source.attach(plan,image,source_mount)
            with patch.object(cryptex_source.subprocess,'check_output',side_effect=source_query):
                destination = mount/'mnt1/System/Cryptexes/OS'; destination.mkdir(parents=True)
                guest_write.run(plan,['cp','-R',str(source_mount)+'/.',str(destination)])
            installed = destination/guest_undo.undo.DSC_MEMBER/'dyld_shared_cache_arm64e'
            with patch.object(sys,'argv',['cfw.py','patch-camera-dsc',str(installed.parent),str(installed)]), \
                 patch.object(cfw,'_dispatch',side_effect=lambda:installed.write_bytes(cache(b'changed'))):
                cfw.main()
            with patch.object(final_guest.subprocess,'check_output',side_effect=query), patch.object(sys,'argv',['plan_gate.py','verify-final']):
                gate.main()
            txn.seal(args); txn.publish(args); txn.finish(args)
        return plan.context['generationID'], mount
    finally: os.close(fd)


for index in (1,2):
    generation, previous_mount = publish(index)
    with (vm/'Disk.img').open('r+b') as stream:
        stream.seek(0); stream.write(bytes([64 + index])); stream.flush(); os.fsync(stream.fileno())

# Exercise the actual writer after two real plan-verifier inode handoffs.
work = vm/'.cfw_disk.identity3'; work.mkdir(mode=0o700)
mount = vm/'.cfw_mount.identity3'; mount.mkdir()
shutil.copytree(previous_mount/'mnt1',mount/'mnt1',copy_function=shutil.copy2)
os.environ.update(VPHONE_GUEST_EVIDENCE=str(work/'guest-changes.jsonl'),CFW_HOST_MNT=str(mount))
fd = os.open(vm/'Disk.img',os.O_RDONLY)
args = SimpleNamespace(vm=vm,work=work,fd=fd,owner_pid=os.getpid(),guest_evidence=True,exit_code=0,retain_staged=False,
    generation=generation,declaration=['dyld-cfw-camera'])
readonly = False
def undo_query(argv):
    root = str(mount/'mnt1')
    if argv[0] == '/usr/bin/hdiutil':
        return plistlib.dumps({'images':[{'image-path':str(work/'Disk.img'),'system-entities':[{'dev-entry':'/dev/disk41'}]}]})
    if argv[1:3] == ['apfs','list']:
        return plistlib.dumps({'Containers':[{'ContainerReference':'disk42','PhysicalStores':[{'DeviceIdentifier':'disk41s1'}],
            'Volumes':[{'DeviceIdentifier':'disk42s1','MountPoint':root}]}]})
    return plistlib.dumps({'ReadOnlyVolume':readonly,'DeviceIdentifier':'disk42s1','MountPoint':root})
try:
    with patch.object(txn,'holders',return_value=[]),contextlib.redirect_stdout(io.StringIO()):
        txn.stage(args); guest_undo.prepare(args)
        with patch.object(final_guest.subprocess,'check_output',side_effect=undo_query): guest_undo.apply(args)
        target = mount/'mnt1/System/Cryptexes/OS'/guest_undo.undo.DSC_MEMBER/'dyld_shared_cache_arm64e'
        assert target.read_bytes() == cache(b'initial')
        (work/'Disk.img').write_bytes(target.read_bytes())
        readonly = True
        with patch.object(final_guest.subprocess,'check_output',side_effect=undo_query),patch.object(sys,'argv',['plan_gate.py','verify-final']):
            gate.main()
        txn.seal(args); txn.publish(args); txn.finish(args)
    with (vm/'Disk.img').open('r+b') as stream:
        stream.seek(0); stream.write(b'R'); stream.flush(); os.fsync(stream.fileno())
    print(json.dumps({'state':'committed','generationID':generation}))
finally: os.close(fd)
