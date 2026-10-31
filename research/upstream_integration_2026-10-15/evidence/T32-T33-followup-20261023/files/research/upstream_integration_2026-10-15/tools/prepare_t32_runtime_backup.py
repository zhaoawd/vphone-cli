#!/usr/bin/env python3
"""Preserve stopped T32 boot state before proposing a new runtime observation."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'scripts'))
import cfw_verify_effects as audit
import cfw_disk_txn as transaction
import cfw_guest_evidence as evidence
VM=ROOT/'vm-t32-t33-dsc-20261018'
WORK=ROOT/'.build/t32-t33-followup-20261023'
BACKUP=WORK/'pre-runtime-backup'


def main():
    baseline=json.loads((WORK/'readonly-baseline.json').read_text())
    observed=json.loads((WORK/'actual-audit-final.json').read_text())
    publication=json.loads((WORK/'publication-targets.json').read_text())
    if not publication['passed'] or observed['state']!='installed-effect-mismatch':
        raise ValueError('Preserve prior audit results before preparing another phase')
    with audit.locked_vm(VM):
        transaction.require_unheld(VM/'Disk.img',os.getpid(),'backup disk')
        BACKUP.mkdir(mode=0o700)
        records={}
        # Preserve every root regular file except diagnostic locks/runtime.
        # Generation inputs and CFW history remain untouched at their original
        # paths; the report records references and grants no restore authority.
        for source in sorted(VM.iterdir()):
            if source.name in ('.vphone-runtime.json','.firmware-desired.lock','.vphone-online-operation.lock'):continue
            if source.is_symlink():raise ValueError('Linked root input: '+source.name)
            if not source.is_file():continue
            target=BACKUP/source.name
            fd=os.open(source,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
            try:
                before=os.fstat(fd)
                if source.name=='Disk.img':
                    if evidence.image_identity(before)!=observed['imageIdentity']:
                        raise ValueError('Current disk changed since readonly audit')
                    transaction.clone_file(fd,target)
                else:shutil.copy2(source,target)
                digest=evidence.digest(target)
                expected=(observed['currentImageSHA256'] if source.name=='Disk.img' else evidence.digest(source))
                if digest!=expected:raise ValueError('Backup digest differs: '+source.name)
                evidence.unchanged(source,fd,before)
                records[source.name]=dict(sha256=digest,bytes=before.st_size,
                    sourceIdentity=evidence.image_identity(before),mode=before.st_mode&0o7777,
                    uid=before.st_uid,gid=before.st_gid)
            finally:os.close(fd)
        for name in ['Disk.img','config.plist','SEPStorage','nvram.bin','AVPBooter.vresearch1.bin','AVPSEPBooter.vresearch1.bin']:
            if name not in records:raise ValueError('Missing complete boot-state member: '+name)
        report=dict(schemaVersion=1,state='verified-backup',vm=str(VM),backup=str(BACKUP),
                    generationID=observed['generationID'],transactionID=observed['transactionID'],files=records,
                    runtimeStarted=False,securityWindowStarted=False,restoreAuthorized=False)
        evidence.write_new(WORK/'runtime-backup.json',json.dumps(report,indent=2).encode()+b'\n')
    print(json.dumps(dict(state='verified-backup',files=len(records),diskSHA256=records['Disk.img']['sha256'])))


if __name__=='__main__':main()
