"""Create an observed Undo continuation from a preserved unsealed transaction.

No guest writer is called. Every input is tied to the qualified parent and an
explicit recovery plan. The original partial transaction is never modified.
"""
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import stat

import cfw_disk_txn as transaction
import cfw_guest_evidence as evidence
from . import component_effects as effects, guest_undo, plan_gate as gate, file_originals

KIND='observed-recovered-undo'
_SOURCE_FILES=(evidence.PLAN,evidence.CONTEXT,evidence.OPERATIONS,evidence.FINAL,evidence.UNDO,
               guest_undo.REQUEST,guest_undo.APPLIED,guest_undo.RECEIPTS)


_IMAGE_DIGESTS={}


def preserved_image_digest(path):
    """Reuse only preserved-source reads with a complete unchanged stat tuple.

    The held descriptor is checked before and after every call, including hits.
    Mutable target disks never use this cache. Restoring mtime cannot hide a
    changed source because ctime, inode, ownership and link count are included.
    """
    path=Path(path)
    if path.name!='Disk.img' or path.parent.parent.name!='.cfw-recovery-sources':
        raise ValueError('Digest reuse is limited to preserved recovery images')
    with effects.regular(path) as stream:
        info=os.fstat(stream.fileno())
        fields=('st_dev','st_ino','st_size','st_mtime_ns','st_ctime_ns','st_uid','st_gid','st_mode','st_nlink')
        key=(str(path),tuple(getattr(info,name) for name in fields))
        if key not in _IMAGE_DIGESTS:
            value=hashlib.file_digest(stream,'sha256').hexdigest()
            if len(_IMAGE_DIGESTS)>=16:_IMAGE_DIGESTS.pop(next(iter(_IMAGE_DIGESTS)))
            _IMAGE_DIGESTS[key]=value
        return _IMAGE_DIGESTS[key]


def source_directory(vm, name):
    if (not isinstance(name,str) or '/' in name or name in ('','.','..')):
        raise ValueError('Invalid preserved recovery transaction')
    source=Path(vm)/'.cfw-recovery-sources'/name
    if source.resolve(strict=True)!=source or not source.is_dir():
        raise ValueError('Recovery source must be an exact preserved VM directory')
    return source


def entries_for(selection):
    result=[]
    for entry in selection['entries']:
        if entry.get('kind') not in ('macho','data'):
            raise ValueError('Observed recovery currently requires complete file Undo')
        result.append(dict(target=entry['target'],beforeSHA256=entry['currentSHA256'],
            afterSHA256=entry['restoredSHA256'],
            metadata={key:entry['restoredState'][key] for key in ('mode','uid','gid')}))
    if not result:raise ValueError('Observed recovery has no authenticated restored file')
    return result


def source_files(source, record):
    names=['transaction.json',*_SOURCE_FILES]
    if record.get('fileOriginalsSHA256') is not None:names.append(file_originals.FILENAME)
    return {name:evidence.digest(source/name) for name in names}


def verify_source(vm, source, expected, selection, parent):
    source=source_directory(vm,source.name)
    record=transaction.load_record(source)
    if (record is None or record['version']!=5 or record.get('vm')!=str(vm)
            or record['id']!=source.name or record['status']!='staged'
            or record.get('operation')!=guest_undo.OPERATION or record.get('guestEvidenceSHA256')
            or (source/evidence.CHECKPOINT).exists()
            or evidence.digest(source/'transaction.json')!=expected['recordSHA256']):
        raise ValueError('Recovery source is not the exact unsealed file Undo')
    if not transaction.is_same(source/'Disk.img',record['staged']):
        raise ValueError('Preserved recovery disk identity differs')
    if preserved_image_digest(source/'Disk.img')!=expected['imageSHA256']:
        raise ValueError('Preserved recovery disk bytes differ')
    old_request=guest_undo.request_for(source,record)
    if (old_request['selection']!=selection or old_request['parentTransactionID']!=parent[1]['id']
            or old_request['parentCheckpointSHA256']!=parent[1]['guestEvidenceSHA256']
            or old_request['targetMetadata']!=guest_undo.selection_metadata(selection,parent[3])
            or evidence.read(source/evidence.PLAN)!=evidence.read(parent[0]/evidence.PLAN)):
        raise ValueError('Recovery source differs from the authenticated parent selection')
    applied=json.loads(evidence.read(source/guest_undo.APPLIED))
    if applied!=dict(schemaVersion=1,transactionID=record['id'],entries=entries_for(selection)):
        raise ValueError('Recovery source lacks the original completed Undo observation')
    rows=evidence.read(parent[0]/evidence.OPERATIONS)
    kept=b''.join(gate.canonical(row)+b'\n' for row in map(json.loads,rows.splitlines())
        if row['declarationID'] not in selection['declarations'])
    if (evidence.read(source/evidence.OPERATIONS)!=kept or
            old_request['retainedOperationsSHA256']!=gate.sha(kept)):
        raise ValueError('Recovery source has changed retained effects')
    file_originals.load(guest_undo.saved_plan(parent[0],selection['generationID']),source/evidence.STORE)
    return record,old_request,source_files(source,record)


def clone_private(source,destination,expected):
    with effects.regular(source) as stream:
        before=os.fstat(stream.fileno())
        transaction.clone_file(stream.fileno(),destination)
        if evidence.digest(destination)!=expected or evidence.digest(source)!=expected:
            raise ValueError('Independent recovery clone differs')
        if destination.stat().st_ino==before.st_ino:raise ValueError('Recovery clone shares its file identity')
    transaction.set_owner_and_mode(destination,transaction.identity(before))


def prepare_recovered(args, source, expected):
    """Requires a live frozen plan, inherited VM lock, and exact approved hashes."""
    if (set(expected)!={'recordSHA256','imageSHA256','parentImageSHA256','approvedPlanSHA256'}
            or any(not isinstance(value,str) or not gate.DIGEST.fullmatch(value) for value in expected.values())):
        raise ValueError('Exact approved recovery digests required')
    vm,work=args.vm,args.work
    source=Path(source)
    if source!=source_directory(vm,source.name):
        raise ValueError('Recovery source is outside its exact preserved path')
    transaction.require_lock(vm);transaction.require_free_space([vm,work])
    if (work.parent!=vm or work.resolve(strict=True)!=work or not work.name.startswith('.cfw_disk.')
            or not work.is_dir() or list(work.iterdir())):
        raise ValueError('Recovery requires a new empty private transaction directory')
    # A reviewed continuation can preallocate its ID so the root registration
    # names every allowed rename path before it grants any identity association.
    suffix=work.name.rsplit('.',1)[-1]
    record_id=getattr(args,'transaction_id',f'{datetime.datetime.now(datetime.timezone.utc):%Y%m%dT%H%M%SZ}-{suffix}')
    if (not isinstance(record_id,str) or not re.fullmatch(r'[0-9]{8}T[0-9]{6}Z-'+re.escape(suffix),record_id)
            or os.path.lexists(vm/'.cfw-history'/record_id) or record_id==source.name):
        raise ValueError('Recovery requires a unique preallocated transaction ID for this work directory')
    parent=transaction.committed_guest_evidence(vm)
    if parent is None or parent[2].get('currentImageSHA256',parent[2]['imageSHA256'])!=expected['parentImageSHA256']:
        raise ValueError('Recovery parent disk differs from the approved complete image')
    plan=transaction.current_guest_plan()
    if evidence.read(parent[0]/evidence.PLAN)!=plan.record_json:
        raise ValueError('Recovery live plan differs from the qualified parent')
    old=transaction.load_record(source)
    if old is None:raise ValueError('Missing preserved recovery journal')
    old_request=guest_undo.request_for(source,old)
    selection=guest_undo.preview(vm,plan.context['generationID'],old_request['selection']['declarations'],_committed=parent)
    old,old_request,files=verify_source(vm,source,expected,selection,parent)
    held=os.fstat(args.fd)
    if (held.st_dev,held.st_ino)!=(os.stat(vm/'Disk.img').st_dev,os.stat(vm/'Disk.img').st_ino):
        raise ValueError('Recovery does not hold the current parent disk')
    transaction.require_unheld(vm/'Disk.img',args.owner_pid,'recovery parent')
    transaction.require_unheld(source/'Disk.img',args.owner_pid,'preserved recovery source')
    record=dict(version=5,provenanceMode='required',guestEvidenceRequired=True,runtimeImageEvidenceRequired=True,
        id=record_id,
        vm=str(vm),started_at=transaction.now(),status='staging',original=transaction.identity(held),staged=None,
        checks=[],failure=None,method='recovered-clone',clone_error=None,copy=None)
    record['original']['sample']=transaction.sample_digest(args.fd,held.st_size)
    transaction.save_record(work,record)
    clone_private(source/'Disk.img',work/'Disk.img',expected['imageSHA256'])
    store=work/evidence.STORE;store.mkdir(mode=0o700)
    for path in sorted((source/evidence.STORE).iterdir()):
        if not gate.DIGEST.fullmatch(path.name):raise ValueError('Unexpected preserved effect artifact')
        clone_private(path,store/path.name,path.name)
    if old.get('fileOriginalsSHA256') is not None:
        catalog=json.loads(evidence.read(source/file_originals.FILENAME));catalog['transactionID']=record['id']
        evidence.write_new(work/file_originals.FILENAME,gate.canonical(catalog))
        record['fileOriginalsSHA256']=evidence.digest(work/file_originals.FILENAME)
    evidence.write_new(work/evidence.OPERATIONS,evidence.read(source/evidence.OPERATIONS))
    request=dict(old_request,transactionID=record['id'],origin=guest_undo.origin_snapshot(vm))
    raw=gate.canonical(request);evidence.write_new(work/guest_undo.REQUEST,raw)
    observation=dict(schemaVersion=1,sourceTransactionID=old['id'],sourceFiles=files,
        sourceImageSHA256=expected['imageSHA256'],approvedPlanSHA256=expected['approvedPlanSHA256'])
    applied=dict(schemaVersion=2,transactionID=record['id'],kind=KIND,recoverySource=observation,
        entries=entries_for(selection))
    evidence.write_new(work/guest_undo.APPLIED,gate.canonical(applied))
    record.update(operation=guest_undo.OPERATION,guestUndoRequestSHA256=gate.sha(raw),
        staged=transaction.identity((work/'Disk.img').stat()),status='staged')
    transaction.save_record(work,record)
    transaction.run_checks('pre-install',args,record)
    verify_observation(work,record,request,applied)
    return record


def verify_observation(work,record,request,applied):
    if (record['version']!=5 or record.get('operation')!=guest_undo.OPERATION
            or set(applied)!={'schemaVersion','transactionID','kind','recoverySource','entries'}
            or type(applied.get('schemaVersion')) is not int or applied['schemaVersion']!=2 or applied.get('kind')!=KIND
            or applied.get('transactionID')!=record['id']):
        raise ValueError('Invalid recovered Undo observation')
    source=applied['recoverySource']
    if (not isinstance(source,dict) or set(source)!={'schemaVersion','sourceTransactionID','sourceFiles',
            'sourceImageSHA256','approvedPlanSHA256'} or type(source['schemaVersion']) is not int or source['schemaVersion']!=1
            or any(not isinstance(source[key],str) or not gate.DIGEST.fullmatch(source[key])
                   for key in ('approvedPlanSHA256','sourceImageSHA256'))):
        raise ValueError('Recovery observation has no exact approved source')
    location=source_directory(Path(record['vm']),source['sourceTransactionID'])
    old=transaction.load_record(location)
    if old is None or source_files(location,old)!=source['sourceFiles']:
        raise ValueError('Preserved recovery evidence changed')
    old_request=guest_undo.request_for(location,old)
    old_applied=json.loads(evidence.read(location/guest_undo.APPLIED))
    if (not transaction.is_same(location/'Disk.img',old['staged'])
            or old.get('status')!='staged' or (location/evidence.CHECKPOINT).exists() or old.get('guestEvidenceSHA256') or old.get('operation')!=guest_undo.OPERATION
            or old['id']!=source['sourceTransactionID'] or old.get('vm')!=record['vm']
            or old_request['selection']!=request['selection']
            or old_request['parentTransactionID']!=request['parentTransactionID']
            or old_request['parentCheckpointSHA256']!=request['parentCheckpointSHA256']
            or old_applied!=dict(schemaVersion=1,transactionID=old['id'],entries=applied['entries'])
            or gate.canonical(applied['entries'])!=gate.canonical(entries_for(request['selection']))
            or preserved_image_digest(location/'Disk.img')!=source['sourceImageSHA256']):
        raise ValueError('Recovered observation differs from the preserved unsealed Undo')
    return source
