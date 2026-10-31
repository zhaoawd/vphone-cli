#!/usr/bin/python3
"""Compare generation-derived rootfs originals with installed binaries/backups readonly."""
import contextlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[3]
WORK=ROOT/'.build/t32-t33-completion-20261023'
sys.path.insert(0,str(ROOT/'scripts'))
import cfw_verify_effects as audit
import cfw_disk_txn as transaction
import cfw_guest_evidence as evidence
from patchers import component_effects as effects,component_signatures as signatures
from patchers import guest_undo,undo_provenance,final_guest

MEMBERS=('usr/libexec/seputil','usr/libexec/launchd_cache_loader',
         'usr/libexec/mobileactivationd','sbin/launchd','System/Library/xpc/launchd.plist')


@contextlib.contextmanager
def source_mount(image):
    root=Path(tempfile.mkdtemp(prefix='original-rootfs-',dir=WORK));attached=False
    result=plistlib.loads(audit.run_tool(['/usr/bin/hdiutil','info','-plist']))
    if any(Path(r.get('image-path','')).absolute()==image for r in result.get('images',[])):
        raise ValueError('Source image already attached; preserve existing attachment')
    device=None
    try:
        info=plistlib.loads(audit.run_tool(['/usr/bin/hdiutil','attach','-readonly','-nobrowse',
                    '-owners','on','-mountpoint',str(root),'-plist',str(image)]));attached=True
        matches=[r for r in info['system-entities'] if r.get('mount-point')==str(root)]
        if len(matches)!=1:raise ValueError('Original image has no unique mounted root')
        device=matches[0]['dev-entry']
        def recheck():
            listing=plistlib.loads(audit.run_tool(['/usr/bin/hdiutil','info','-plist']))
            associated=[r for r in listing.get('images',[]) if Path(r.get('image-path','')).absolute()==image
                        and any(e.get('mount-point')==str(root) and e.get('dev-entry')==device
                                for e in r.get('system-entities',[]))]
            if len(associated)!=1:raise ValueError('Original image mount association changed')
            final_guest.require_mount(root,device.removeprefix('/dev/'),True)
            if not os.statvfs(root).f_flag&os.ST_RDONLY:raise ValueError('Original mount is writable')
        recheck();yield root,recheck;recheck()
    finally:
        if attached:
            audit.run_tool(['/sbin/umount',str(root)])
            audit.run_tool(['/usr/bin/hdiutil','detach',device if device is not None else str(image)])
        root.rmdir()


def main():
    if os.geteuid()!=0:raise ValueError('Readonly mounts require administrator authentication')
    prepared=json.loads((WORK/'file-original-source/source.json').read_text())
    vm=Path(prepared['vm']);cache=Path(prepared['cache'])
    plan=guest_undo.saved_plan(vm/'.cfw-history/20261020T145635Z-QBLOIoqy',prepared['generationID'])
    result=dict(state='failed',writeAuthorized=False,originQualified=False,runtimeValidated=False)
    with audit.locked_vm(vm):
        transaction.require_unheld(vm/'Disk.img',os.getpid(),'readonly file original comparison')
        before=evidence.image_identity((vm/'Disk.img').stat())
        if undo_provenance.qualify_source(plan,prepared['source'])!=prepared['generationSource']:
            raise ValueError('Original generation source changed')
        if evidence.digest(cache)!=prepared['cacheSHA256']:raise ValueError('Prepared source image changed')
        copies=WORK/'file-original-source/members';copies.mkdir(mode=0o700)
        with source_mount(cache) as (original,recheck):
            with audit.readonly_roots(vm/'Disk.img',{'system'},WORK) as (roots,check_current):
                rows=[]
                for name in MEMBERS:
                    source=original/name
                    original_state=effects.state(source,False,readonly_source=True)
                    current=effects.state(roots['system']/name,False)
                    backup=effects.state(roots['system']/(name+'.bak'),False)
                    pages=None;error=None
                    if original_state['kind']=='file':
                        saved=copies/Path(name).name
                        with saved.open('xb') as out,effects.regular(source,readonly_source=True) as stream:
                            while block:=stream.read(effects.CHUNK):out.write(block)
                        os.chmod(saved,0o600);os.chown(saved,501,20)
                        if effects.digest(saved)!=original_state['sha256']:raise ValueError('Original file copy differs')
                        if name.endswith('.plist'):pass
                        else:
                            try:
                                directories=signatures.directories(saved)
                                if not directories:raise ValueError('Original Mach-O has no CodeDirectory')
                                signatures.verify_slots(saved,[dict(identity=cd['identity'],slot=cd['slot'],pages=range(cd['count'])) for cd in directories])
                                pages=sum(cd['count'] for cd in directories)
                            except (OSError,ValueError) as e:error=str(e)
                    rows.append(dict(target='system:/'+name,original=original_state,current=current,backup=backup,
                        backupContentMatchesOriginal=effects.content(backup)==effects.content(original_state),
                        currentContentMatchesOriginal=effects.content(current)==effects.content(original_state),
                        originalCodePages=pages,signatureError=error))
                recheck();check_current()
                result.update(state='observed',members=rows,generationSource=prepared['generationSource'],sourceCacheSHA256=prepared['cacheSHA256'])
        if evidence.image_identity((vm/'Disk.img').stat())!=before:raise ValueError('VM image changed during readonly comparison')
        result.update(imageIdentityStable=True,mountsReleased=True)
    destination=WORK/'file-originals-readonly.json'
    evidence.write_new(destination,evidence.canonical(result));os.chown(destination,501,20)
    print(json.dumps(result))


if __name__=='__main__':main()
