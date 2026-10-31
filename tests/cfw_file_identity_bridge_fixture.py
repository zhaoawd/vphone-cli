"""Real v5 whole-file publication/Undo with the actual Swift plan verifier."""
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

ROOT=Path(__file__).resolve().parents[1];sys.path[:0]=[str(ROOT),str(ROOT/'scripts')]
import cfw_disk_txn as txn
from patchers import cfw,file_originals,final_guest,guest_undo,guest_write,plan_gate as gate
from tests.test_component_signatures import signed_macho

vm=Path(sys.argv[1]);current=None;generation=None
for number in (1,2):
    work=vm/f'.cfw_disk.fileidentity{number}';work.mkdir(mode=0o700)
    mount=vm/f'.cfw_mount.fileidentity{number}';mount.mkdir()
    if current:shutil.copytree(current,mount/'mnt1')
    else:(mount/'mnt1').mkdir()
    os.environ.update(VPHONE_GUEST_EVIDENCE=str(work/'guest-changes.jsonl'),CFW_HOST_MNT=str(mount))
    fd=os.open(vm/'Disk.img',os.O_RDONLY);readonly=number==1
    args=SimpleNamespace(vm=vm,work=work,fd=fd,owner_pid=os.getpid(),guest_evidence=True,exit_code=0,retain_staged=False)
    def query(argv):
        root=str(mount/'mnt1')
        if argv[0]=='/usr/bin/hdiutil':return plistlib.dumps({'images':[{'image-path':str(work/'Disk.img'),'system-entities':[{'dev-entry':'/dev/disk41'}]}]})
        if argv[1:3]==['apfs','list']:
            return plistlib.dumps({'Containers':[{'ContainerReference':'disk42','PhysicalStores':[{'DeviceIdentifier':'disk41s1'}],
                'Volumes':[{'DeviceIdentifier':'disk42s1','MountPoint':root}]}]})
        return plistlib.dumps({'ReadOnlyVolume':readonly,'DeviceIdentifier':'disk42s1','MountPoint':root})
    try:
        with patch.object(txn,'holders',return_value=[]),contextlib.redirect_stdout(io.StringIO()):
            txn.stage(args);plan=gate.from_environment();generation=plan.context['generationID']
            target=mount/'mnt1/usr/libexec/seputil'
            if number==1:
                target.parent.mkdir(parents=True);target.write_bytes(signed_macho(b'original'));target.chmod(0o755)
                pristine=mount/'mnt_sysos_original_files';original=pristine/'usr/libexec/seputil'
                original.parent.mkdir(parents=True);shutil.copy2(target,original)
                @contextlib.contextmanager
                def native(image,workspace):yield pristine,lambda:None
                with patch('cache_systemos.cache_systemos',side_effect=shutil.copyfile),patch.object(file_originals,'mounted',side_effect=native):
                    file_originals.prepare(plan,work)
                stage=vm/'.cfw_temp';stage.mkdir()
                backup=target.with_name('seputil.bak');staged=stage/'seputil'
                guest_write.run(plan,['cp',str(target),str(backup)])
                guest_write.run(plan,['cp',str(backup),str(staged)])
                with patch.object(sys,'argv',['cfw.py','patch-seputil',str(staged)]), \
                     patch.object(cfw,'_dispatch',side_effect=lambda *,guest_environment:staged.write_bytes(signed_macho(b'patched'))):cfw.main()
                guest_write.run(plan,['cp',str(staged),str(target)])
            else:
                args.generation=generation;args.declaration=['system-seputil-boot-gigalocker_uuid']
                guest_undo.prepare(args)
                with patch.object(final_guest.subprocess,'check_output',side_effect=query):guest_undo.apply(args)
                assert target.read_bytes()==signed_macho(b'original')
                assert (work/'guest-changes.jsonl').read_bytes()==b''
                (work/'Disk.img').write_bytes(target.read_bytes());readonly=True
            with patch.object(final_guest.subprocess,'check_output',side_effect=query),patch.object(sys,'argv',['plan_gate.py','verify-final']):gate.main()
            txn.seal(args);txn.publish(args);txn.finish(args)
            current=mount/'mnt1'
    finally:os.close(fd)
print(json.dumps(dict(state='file-undo-committed',generationID=generation)))
