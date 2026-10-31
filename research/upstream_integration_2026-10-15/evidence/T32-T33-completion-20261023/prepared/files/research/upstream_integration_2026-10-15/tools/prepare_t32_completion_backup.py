#!/usr/bin/env python3
"""Create a fresh complete stopped-VM backup; no restore or VM mutation."""
import json
import os
from pathlib import Path
import shutil
import sys

ROOT=Path(__file__).resolve().parents[3];sys.path.insert(0,str(ROOT/'scripts'))
import cfw_verify_effects as audit
import cfw_guest_evidence as evidence
import cfw_disk_txn as txn
WORK=ROOT/'.build/t32-t33-completion-20261023';VM=ROOT/'vm-t32-t33-dsc-20261018'
BACKUP=WORK/'pre-acceptance-backup'
EXPECTED='d17da7ea1734a1edeb92ee474a878b92d0e6717241f87df7c45732ddffcc8282'


def main():
    with audit.locked_vm(VM):
        txn.require_unheld(VM/'Disk.img',os.getpid(),'backup disk')
        if evidence.digest(VM/'Disk.img')!=EXPECTED:raise ValueError('Stopped disk changed after original comparison')
        BACKUP.mkdir(mode=0o700);files={}
        for source in sorted(VM.iterdir()):
            if source.name in ('.vphone-runtime.json','.firmware-desired.lock','.vphone-online-operation.lock'):continue
            if source.is_symlink():raise ValueError('Linked VM root input')
            if not source.is_file():continue
            target=BACKUP/source.name;fd=os.open(source,os.O_RDONLY|os.O_NOFOLLOW)
            try:
                before=os.fstat(fd)
                if before.st_uid!=os.geteuid() or before.st_gid!=os.getegid():
                    raise ValueError('Backup cannot preserve input ownership without separate authentication')
                if source.name=='Disk.img':txn.clone_file(fd,target);shutil.copystat(source,target)
                else:shutil.copy2(source,target)
                expected=EXPECTED if source.name=='Disk.img' else evidence.digest(source)
                if evidence.digest(target)!=expected:raise ValueError('Complete backup digest differs')
                evidence.unchanged(source,fd,before)
                files[source.name]=dict(sha256=expected,bytes=before.st_size,sourceIdentity=evidence.image_identity(before),
                    mode=before.st_mode&0o7777,uid=before.st_uid,gid=before.st_gid)
            finally:os.close(fd)
        for required in ('Disk.img','config.plist','SEPStorage','nvram.bin','AVPBooter.vresearch1.bin','AVPSEPBooter.vresearch1.bin'):
            if required not in files:raise ValueError('Incomplete boot-state backup')
        report=dict(schemaVersion=1,state='verified-backup',vm=str(VM),backup=str(BACKUP),files=files,
            restoreAuthorized=False,VMWritten=False,VMStarted=False,securityWindowStarted=False)
        evidence.write_new(WORK/'acceptance-backup.json',json.dumps(report,indent=2).encode()+b'\n')
    print(json.dumps(dict(state='verified-backup',files=len(files),imageSHA256=EXPECTED)))


if __name__=='__main__':main()
