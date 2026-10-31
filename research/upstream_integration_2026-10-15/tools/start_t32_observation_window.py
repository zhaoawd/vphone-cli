#!/usr/bin/python3
"""Start one independently supervised window only after new human approval."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT=Path(__file__).resolve().parents[3]
WORK=ROOT/'.build/t32-t33-followup-20261023'
sys.path.insert(0,str(Path(__file__).resolve().parent))
from t32_runtime_preflight import validate_control_socket


def main():
    if os.geteuid()!=0 or len(sys.argv)!=3 or sys.argv[1]!='--execute-approved-runtime-plan':
        raise ValueError('Administrator authentication and approved plan SHA required')
    raw=(WORK/'runtime-plan.json').read_bytes();expected=sys.argv[2]
    approval=json.loads((WORK/'runtime-approval.json').read_text())
    if (hashlib.sha256(raw).hexdigest()!=expected or approval.get('approved') is not True
            or approval.get('planSHA256')!=expected):raise ValueError('New human approval is required')
    plan=json.loads(raw)
    for path,digest in plan['frozenTools'].items():
        if hashlib.sha256(Path(path).read_bytes()).hexdigest()!=digest:raise ValueError('Frozen tool changed: '+path)
    if hashlib.sha256((WORK/'runtime-backup.json').read_bytes()).hexdigest()!=plan['backupManifestSHA256']:
        raise ValueError('Verified backup changed')
    validate_control_socket(plan['vm'])
    if (WORK/'boot-window/authorization-window.json').exists() or (WORK/'runtime-observation').exists():
        raise ValueError('Do not replay a prior runtime window')
    sys.path.insert(0,str(ROOT/'scripts'))
    import cfw_verify_effects as audit
    import cfw_disk_txn as transaction
    import cfw_guest_evidence as evidence
    vm=Path(plan['vm'])
    with audit.locked_vm(vm):
        transaction.require_unheld(vm/'Disk.img',os.getpid(),'approved runtime disk')
        if evidence.digest(vm/'Disk.img')!=plan['expectedCurrentImageSHA256']:
            raise ValueError('Current disk differs from the verified backup')
    with (WORK/'root-window-start.log').open('x') as log:
        subprocess.run(['/usr/bin/python3','-u',str(WORK/'boot-window/scoped-amfidont.py')],
                       stdout=log,stderr=subprocess.STDOUT,check=True)


if __name__=='__main__':main()
