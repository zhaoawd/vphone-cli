"""Reuse exact signing artifacts only from this disk's sealed publication chain.

This preserves producer output bytes. It grants neither firmware-original nor
publisher-origin authority, and never upgrades a legacy signing observation.
"""
import json
import os
from pathlib import Path
import shutil
import stat

from . import component_effects as effects, component_signatures as signatures, plan_gate as gate
import cfw_guest_evidence as evidence


def inputs(plan, argv, before):
    executable=shutil.which(argv[0]) if not Path(argv[0]).is_absolute() else argv[0]
    if executable is None:raise FileNotFoundError('Signing executable unavailable')
    executable=Path(executable).resolve(strict=True)
    signer=effects.state(executable,False)
    if signer['kind']!='file':raise ValueError('Signing executable is not a regular file')
    arguments=[]
    for arg in argv[1:-1]:
        if arg.startswith(('-K','-S')) and len(arg)>2:
            path=Path(arg[2:])
            value=effects.state(path,False)
            if value['kind']!='file':raise ValueError('Signing option has no regular input')
            arguments.append(dict(option=arg[:2],input=value))
        else:arguments.append(dict(option=arg))
    return dict(schemaVersion=1,generationID=plan.context['generationID'],
        planDigest=plan.record['planSHA256'],variant=plan.context['variant'],
        guestEnvironment=plan.context['guestEnvironment'],verifierSHA256=plan.context['verifierSHA256'],
        input=before,signer=signer,arguments=arguments)


def candidate(plan, work, declaration, target, wanted):
    import cfw_disk_txn as transaction
    vm=Path(plan.context['vmDirectory']).resolve(strict=True)
    work=Path(work).resolve(strict=True)
    current=transaction.committed_guest_evidence(vm,ignore_work=work)
    seen=set()
    for _ in range(1024):
        if current is None:return None
        archive,record,checkpoint,_final=current
        if archive in seen:raise ValueError('Cyclic signing publication ancestry')
        seen.add(archive)
        if checkpoint['generationID']!=wanted['generationID']:return None
        rows=[json.loads(line) for line in evidence.read(archive/evidence.OPERATIONS).splitlines() if line]
        for row in reversed(rows):
            proof=row.get('effect',{})
            if (row.get('declarationID')!=declaration or row.get('target')!=target
                    or proof.get('operation')!='sign' or proof.get('signingInputs')!=wanted):continue
            if (row.get('generationID')!=wanted['generationID'] or row.get('planDigest')!=wanted['planDigest']
                    or proof['before']!=wanted['input']):raise ValueError('Signing artifact qualification differs')
            if any(proof['after'].get(key)!=proof['before'].get(key) for key in ('mode','uid','gid')):
                continue
            original=effects.blob(archive/evidence.STORE,proof['before']['sha256'])
            signed=effects.blob(archive/evidence.STORE,proof['after']['sha256'])
            signatures.verify_signing(original,signed)
            signatures.verify_artifact(signed,require_cms=any(arg['option']=='-K' for arg in wanted['arguments']))
            return signed,dict(transactionID=record['id'],checkpointSHA256=record['guestEvidenceSHA256'],
                operationSHA256=gate.sha(gate.canonical(row)),outputSHA256=proof['after']['sha256'])
        # Only the retained previous image establishes ancestry. Unrelated
        # histories, version labels and matching filenames never qualify.
        previous=record.get('previous_disk')
        if previous not in (transaction.DISK,transaction.PREVIOUS):
            raise ValueError('Signing ancestry has no exact retained previous disk')
        current=transaction.committed_guest_evidence(vm,image=archive/previous,ignore_work=work)
    raise ValueError('Signing publication ancestry exceeds bound')


def restore(source, artifact, before):
    """Write only the already-authorized staging file, preserving its metadata."""
    if effects.state(source,False)!=before:raise ValueError('Signing input changed before artifact reuse')
    fd=os.open(source,os.O_WRONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        held=os.fstat(fd);named=Path(source).lstat()
        if (not stat.S_ISREG(held.st_mode) or held.st_nlink!=1
                or (held.st_dev,held.st_ino)!=(named.st_dev,named.st_ino)):
            raise ValueError('Signing reuse target changed or shared')
        with effects.regular(artifact) as stream:
            length=0
            while chunk:=stream.read(effects.CHUNK):
                data=memoryview(chunk)
                while data:
                    count=os.write(fd,data)
                    if count<=0:raise OSError('Signing artifact write made no progress')
                    data=data[count:];length+=count
        os.ftruncate(fd,length);os.fsync(fd)
    finally:os.close(fd)

