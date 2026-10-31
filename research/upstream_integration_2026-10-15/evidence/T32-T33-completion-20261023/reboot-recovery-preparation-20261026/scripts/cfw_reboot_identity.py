"""Compare explicitly requalified files across a host device-number change.

This module grants no publication, Undo, or origin authority. Callers must hold
an exclusive VM lock, authenticate the separate approved recovery record, and
retain all existing content, source, signature and publication checks. Historical
records remain byte-for-byte unchanged. No implicit filesystem-wide alias exists.
"""
import hashlib
import os
from pathlib import Path
import stat
import uuid

FIELDS=('dev','ino','size','mtime_ns')


def identity(info):
    return {name:getattr(info,'st_'+name) for name in FIELDS}


class RequalifiedIdentity:
    def __init__(self, root, volume_uuid, members):
        self.root=Path(root)
        if self.root.resolve(strict=True)!=self.root or not self.root.is_dir():
            raise ValueError('Exact recovery namespace required')
        self.volume_uuid=str(uuid.UUID(volume_uuid))
        self.members=[];self.verified=False;seen=set();paths=set()
        if not members:raise ValueError('Explicit recovered members required')
        for member in members:
            old=dict(member['recorded']);current=dict(member['current'])
            if (set(old)!=set(FIELDS) or set(current)!=set(FIELDS)
                    or any(type(v) is not int or v<0 for v in [*old.values(),*current.values()])
                    or old['dev']==current['dev']
                    or any(old[k]!=current[k] for k in FIELDS if k!='dev')):
                raise ValueError('Only the observed device number may differ')
            key=(current['dev'],current['ino'])
            if key in seen:raise ValueError('Ambiguous recovered inode')
            seen.add(key)
            digest=member['sha256']
            if not isinstance(digest,str) or len(digest)!=64 or any(c not in '0123456789abcdef' for c in digest):
                raise ValueError('Complete authenticated SHA-256 required')
            names=tuple(member['paths'])
            if not names:raise ValueError('Explicit paths required')
            for name in names:
                p=Path(name)
                if (not isinstance(name,str) or p.is_absolute() or not p.parts
                        or '..' in p.parts or str(p)!=name or name in paths):
                    raise ValueError('Ambiguous or escaping recovery path')
                paths.add(name)
            self.members.append(dict(recorded=old,current=current,sha256=digest,paths=names))

    def _info(self, path):
        path=Path(path);relative=path.relative_to(self.root)
        if '..' in relative.parts:raise ValueError('Escaping recovery path')
        cursor=path
        while cursor!=self.root:
            if cursor.is_symlink():raise ValueError('Linked recovery path')
            cursor=cursor.parent
        info=path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1:
            raise ValueError('Recovered file must be private and regular')
        return info

    def verify_files(self, current_volume_uuid):
        self.verified=False
        if str(uuid.UUID(current_volume_uuid))!=self.volume_uuid:
            raise ValueError('Recovery volume differs')
        for member in self.members:
            found=[self.root/name for name in member['paths'] if os.path.lexists(self.root/name)]
            if len(found)!=1:raise ValueError('Recovered inode has no unique recorded path')
            path=found[0];before=self._info(path)
            if identity(before)!=member['current']:raise ValueError('Recovered file metadata differs')
            fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
            try:
                with os.fdopen(fd,'rb',closefd=False) as source:
                    digest=hashlib.file_digest(source,'sha256').hexdigest()
                after=os.fstat(fd);named=self._info(path)
                keys=('st_dev','st_ino','st_size','st_mtime_ns','st_ctime_ns','st_nlink')
                if digest!=member['sha256'] or any(getattr(before,k)!=getattr(after,k) or
                        getattr(after,k)!=getattr(named,k) for k in keys):
                    raise ValueError('Recovered full bytes changed during readback')
            finally:os.close(fd)
        self.verified=True

    def matches(self, path, recorded, observed):
        if not self.verified:return False
        try:
            name=str(Path(path).relative_to(self.root));actual=identity(self._info(path))
        except (ValueError,OSError):return False
        return any(name in row['paths'] and recorded==row['recorded'] and
                   observed==row['current'] and actual==observed for row in self.members)


REGISTRATION='.cfw-reboot-identity.json'


def decode_registered(record, vm, generation):
    """Parse only; a caller-supplied object is never a trusted registration."""
    keys={'schemaVersion','kind','vmDirectory','generationID','approvedPlanSHA256','volumeUUID','members'}
    def digest(value):
        return isinstance(value,str) and len(value)==64 and all(c in '0123456789abcdef' for c in value)
    if (not isinstance(record,dict) or set(record)!=keys
            or type(record['schemaVersion']) is not int or record['schemaVersion']!=1
            or record['kind']!='explicit-reboot-requalification'
            or record['vmDirectory']!=str(vm)
            or not digest(generation) or record['generationID']!=generation
            or not digest(record['approvedPlanSHA256'])
            or not isinstance(record['members'],list)
            or any(not isinstance(row,dict) or set(row)!={'paths','recorded','current','sha256'}
                   for row in record['members'])):
        raise ValueError('Recovery registration differs from approved VM/generation scope')
    return RequalifiedIdentity(vm,record['volumeUUID'],record['members'])


def load_registered(vm, generation, current_volume_uuid):
    """Read a root-registered identity observation, retaining all content gates.

    Root registration performs full readback before exclusive publication. This
    reader authenticates its immutable carrier and checks live metadata; it does
    not repeat full disk reads for every identity comparison. Publication and
    Undo continue to verify all original content/signature/source proofs.
    """
    import json
    vm=Path(vm);path=vm/REGISTRATION
    if not os.path.lexists(path):return None
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    try:
        before=os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid!=0 or
                stat.S_IMODE(before.st_mode)!=0o444 or before.st_nlink!=1 or before.st_size>1<<20):
            raise ValueError('Recovery registration must be a root-owned immutable regular file')
        raw=os.read(fd,(1<<20)+1)
        named=path.lstat();after=os.fstat(fd)
        keys=('st_dev','st_ino','st_size','st_mtime_ns','st_ctime_ns','st_nlink','st_uid','st_mode')
        if len(raw)!=before.st_size or any(getattr(before,k)!=getattr(after,k) or
                getattr(after,k)!=getattr(named,k) for k in keys):
            raise ValueError('Recovery registration changed during read')
        binding=decode_registered(json.loads(raw),vm,generation)
        if str(uuid.UUID(current_volume_uuid))!=binding.volume_uuid:
            raise ValueError('Registered recovery volume differs')
        for row in binding.members:
            candidates=[vm/name for name in row['paths'] if os.path.lexists(vm/name)
                        and identity(binding._info(vm/name))==row['current']]
            if len(candidates)!=1:
                raise ValueError('Registered recovered file metadata differs')
        binding.verified=True
        return binding
    finally:os.close(fd)


def _volume_uuid(root):
    import plistlib
    import subprocess
    listing=subprocess.check_output(['/bin/df','-P',str(root)],text=True,timeout=15)
    rows=listing.splitlines()
    if len(rows)!=2 or not rows[-1].split()[0].startswith('/dev/'):
        raise ValueError('Recovery filesystem has no unique local device')
    device=rows[-1].split()[0]
    volume=plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil','info','-plist',device],timeout=15))
    return str(uuid.UUID(volume['VolumeUUID']))


def binding_for(path):
    """Locate only an explicitly root-registered VM; no registration means no alias."""
    import json
    path=Path(path).absolute()
    for root in path.parents:
        if not os.path.lexists(root/REGISTRATION):continue
        desired=root/'.firmware-desired-plan.json'
        fd=os.open(desired,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
        try:
            before=os.fstat(fd)
            if not stat.S_ISREG(before.st_mode) or before.st_nlink!=1 or before.st_size>1<<20:
                raise ValueError('Recovery generation must be a private regular plan')
            data=os.read(fd,(1<<20)+1)
            if len(data)!=before.st_size or identity(os.fstat(fd))!=identity(before) or identity(desired.lstat())!=identity(before):
                raise ValueError('Recovery generation changed during read')
        finally:os.close(fd)
        return load_registered(root,json.loads(data)['generationID'],_volume_uuid(root))
    return None


def matches_historical(path, observed, recorded):
    """Match physical identity only. Existing cryptographic verifiers still run."""
    if observed==recorded:return True
    if (not isinstance(recorded,dict) or set(observed)!=set(recorded) or 'dev' not in recorded
            or any(observed[k]!=recorded[k] for k in observed if k!='dev')):return False
    binding=binding_for(path)
    if binding is None:return False
    return any(recorded['dev']==row['recorded']['dev'] and observed['dev']==row['current']['dev']
               and binding.matches(path,row['recorded'],row['current']) for row in binding.members)


def register_requalification(vm, generation, approved_plan_sha256, members):
    """Publish one explicit root observation after its caller approves a frozen plan.

    This writes only the new registration. It neither edits old records nor
    starts, seals or publishes a disk transaction. Replacing a registration is
    deliberately unsupported; a second host restart needs a new reviewed scope.
    """
    import json
    import vm_lock
    if os.geteuid()!=0:raise ValueError('Explicit root registration required')
    vm=Path(vm);vm_lock.check_inherited(vm)
    volume=_volume_uuid(vm)
    record=dict(schemaVersion=1,kind='explicit-reboot-requalification',vmDirectory=str(vm),
        generationID=generation,approvedPlanSHA256=approved_plan_sha256,volumeUUID=volume,members=members)
    binding=decode_registered(record,vm,generation)
    binding.verify_files(volume)
    path=vm/REGISTRATION
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    try:
        info=os.fstat(fd)
        if info.st_uid!=0 or info.st_nlink!=1:raise ValueError('Recovery registration carrier is not private root data')
        raw=(json.dumps(record,sort_keys=True,separators=(',',':'),ensure_ascii=False)+'\n').encode()
        view=memoryview(raw)
        while view:
            count=os.write(fd,view)
            if count<=0:raise OSError('Short recovery registration write')
            view=view[count:]
        os.fsync(fd);os.fchmod(fd,0o444);os.fsync(fd)
    finally:os.close(fd)
    directory=os.open(vm,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:os.fsync(directory)
    finally:os.close(directory)
    if load_registered(vm,generation,volume) is None:raise ValueError('Root recovery registration did not read back')
    return hashlib.sha256(path.read_bytes()).hexdigest()
