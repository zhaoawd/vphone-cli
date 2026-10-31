#!/usr/bin/env python3
"""Read the authenticated retained postimage using the independent target reader."""
import hashlib
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT/'scripts'))
import cfw_verify_effects as audit
import cfw_disk_txn as transaction
import cfw_guest_evidence as evidence
from patchers import guest_undo, installed_effects, undo_provenance

VM = ROOT/'vm-t32-t33-dsc-20261018'
WORK = ROOT/'.build/t32-t33-followup-20261023'
OUTPUT = WORK/'publication-targets.json'


def main():
    # Both ends are immutable report inputs. The CLI's locked reader supplies
    # all checkpoint, postimage, generation and blob authentication.
    with audit.locked_vm(VM):
        committed=transaction.committed_guest_evidence(VM)
        if committed is None: raise ValueError('No qualified current publication')
        archive,record,checkpoint,final=committed
        if record['version'] != 4: raise ValueError('Independent retained postimage is required')
        image=archive/evidence.POSTIMAGE
        transaction.require_unheld(image,os.getpid(),'retained publication image')
        fd=os.open(image,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
        try:
            before=os.fstat(fd)
            wanted={row['target'].split(':',1)[0] for row in final['outputs']}
            wanted.discard('dsc');wanted.add('system')
            with audit.readonly_roots(image,wanted,WORK) as (roots,recheck):
                result=installed_effects.verify_targets(final['outputs'],roots)
                recheck()
            if transaction.committed_guest_evidence(VM)!=committed:
                raise ValueError('Publication changed during postimage read')
            evidence.unchanged(image,fd,before)
            result.update(schemaVersion=1,state='verified-publication-targets' if result['passed'] else 'publication-target-mismatch',
                          vm=str(VM),transactionID=record['id'],imageSHA256=checkpoint['imageSHA256'],
                          image=str(image),imageIdentity=evidence.image_identity(before),
                          publicationCheckpointSHA256=record['guestEvidenceSHA256'],
                          cleanup=dict(mountsReleased=True,imageDetached=True))
        finally:os.close(fd)
    evidence.write_new(OUTPUT,json.dumps(result,indent=2,sort_keys=True).encode()+b'\n')
    owner=WORK.stat();os.chown(OUTPUT,owner.st_uid,owner.st_gid)
    print(json.dumps(dict(passed=result['passed'],targets=len(result['targets']),report=str(OUTPUT))))
    return 0 if result['passed'] else 1


if __name__=='__main__':raise SystemExit(main())
