"""Guest source and origin transition sealed in the existing disk journal.

Only the live root-owned Store CLI can qualify a producer. Saved effect
inspection, caller-supplied version labels and legacy receipts grant no source.
"""
import base64
import json
import os
from pathlib import Path
import stat
import subprocess

import cfw_guest_evidence as evidence
from . import plan_gate as gate

SOURCE='guest-origin-source.json'
TRANSITION='guest-origin-transition.json'
ATTESTATION='guest-origin-attestation.json'
INVALIDATION='guest-origin-invalidation.json'
OWNER=0
ENV='VPHONE_CFW_ORIGIN_SOURCE'
STORE=Path('/Library/Application Support/vphone-launchpad/Bundles')
RESOURCES=Path(__file__).resolve().parents[2]


def invalidate(work,record):
    """An unqualified new install may only clear the affected Guest origin."""
    from .guest_undo import origin_snapshot
    origin=origin_snapshot(Path(record['vm']))
    if origin['before'] is None:return
    value=dict(schemaVersion=1,transactionID=record['id'],vmDirectory=record['vm'],origin=origin)
    evidence.write_new(work/INVALIDATION,gate.canonical(value))
    record['guestOriginInvalidationSHA256']=evidence.digest(work/INVALIDATION)


def verify_invalidation(work,record,*,before=False):
    if record.get('guestOriginInvalidationSHA256') is None:return None
    if record['version']!=5 or record.get('operation') is not None or 'guestOriginSourceSHA256' in record:
        raise ValueError('Guest origin invalidation belongs to another operation')
    raw=evidence.read(work/INVALIDATION)
    if gate.sha(raw)!=record['guestOriginInvalidationSHA256']:raise ValueError('Guest invalidation changed')
    value=json.loads(raw);origin=value.get('origin')
    if value!=dict(schemaVersion=1,transactionID=record['id'],vmDirectory=record['vm'],origin=origin):
        raise ValueError('Guest invalidation belongs to another transaction')
    if not isinstance(origin,dict) or set(origin)!={'before','after','metadata'}:
        raise ValueError('Invalid Guest origin invalidation')
    initial=json.loads(base64.b64decode(origin['before'],validate=True))
    final=json.loads(base64.b64decode(origin['after'],validate=True))
    if (not isinstance(initial,dict) or not set(initial).issubset({'bundle','guestEnvironment','kernel','bootChain'})
            or not isinstance(initial.get('bundle'),str)
            or any(item is not None and not isinstance(item,str) for item in initial.values())
            or final!={key:item for key,item in initial.items() if key!='guestEnvironment'}):
        raise ValueError('Guest invalidation changes unrelated origins')
    if before:
        from .guest_undo import check_origin
        current,original,_=check_origin(Path(record['vm']),origin)
        if current!=original:raise ValueError('Guest origin changed before disk publication')
    return origin


def native_verification(source, *, require_lease, attestation=None):
    executable=Path(source['executable'])
    current=executable
    while current!=STORE.parent:
        info=current.lstat()
        if current.is_symlink() or info.st_uid!=0 or stat.S_IMODE(info.st_mode)&0o022:
            raise ValueError('Guest producer Store path is linked or writable outside root')
        current=current.parent
    if evidence.digest(executable)!=source['executableSHA256']:
        raise ValueError('Guest producer executable changed')
    if require_lease:
        held=os.fstat(0);named=(STORE/'.store.lock').lstat()
        if (not stat.S_ISREG(held.st_mode) or held.st_nlink!=1 or held.st_uid!=0
                or (held.st_dev,held.st_ino)!=(named.st_dev,named.st_ino)):
            raise ValueError('Guest producer Store lease was not inherited')
    argv=[str(executable),'cfw','verify-origin-source',source['version']]
    if require_lease:argv.append('--require-lease')
    if attestation is not None:
        argv.extend(['--attestation',str(attestation[0]),'--attestation-sha256',attestation[1]])
    result=subprocess.run(argv,capture_output=True,timeout=120)
    if result.returncode or len(result.stdout)>65536 or json.loads(result.stdout)!=source:
        raise ValueError('Current verified Core Bundle producer differs')
    if evidence.digest(executable)!=source['executableSHA256']:
        raise ValueError('Guest producer changed during verification')


def verify_source(source, *, require_lease, attestation=None):
    if (not isinstance(source,dict) or set(source)!={'schemaVersion','producer','version','executable',
            'executableSHA256','resourceBase','archiveSHA256','cliCDHash'} or type(source['schemaVersion']) is not int or source['schemaVersion']!=1
            or source['producer']!='current-verified-core-bundle-cli'
            or not isinstance(source['version'],str) or len(source['version'])>64 or '/' in source['version'] or source['version'] in ('','.','..')
            or any(not isinstance(source[key],str) or not gate.DIGEST.fullmatch(source[key])
                   for key in ('executableSHA256','archiveSHA256'))
            or not isinstance(source['cliCDHash'],str) or len(source['cliCDHash'])!=40
            or any(c not in '0123456789abcdef' for c in source['cliCDHash'])):
        raise ValueError('Invalid guest producer qualification')
    bundle=STORE/source['version']/'VPhone.bundle/Contents'
    if source['executable']!=str(bundle/'MacOS/vphone-cli') or source['resourceBase']!=str(bundle/'Resources'):
        raise ValueError('Guest producer is outside the fixed Core Bundle Store')
    native_verification(source,require_lease=require_lease,attestation=attestation)
    return source


def live_source(plan):
    raw=os.environ.get(ENV)
    if raw is None:return None
    if os.geteuid()!=OWNER:raise ValueError('Guest producer qualification requires root')
    source=verify_source(json.loads(raw),require_lease=True)
    if (source['executable']!=plan.context['verifierPath']
            or source['executableSHA256']!=plan.context['verifierSHA256']
            or source['resourceBase']!=str(RESOURCES)):
        raise ValueError('Actual guest producer resources differ from the live Store source')
    return source


def prepare(work, record, plan):
    source=live_source(plan)
    if source is None:return
    if record['version']!=5 or record.get('operation') is not None:
        raise ValueError('Guest source qualification requires an ordinary new v5 install')
    from .guest_undo import origin_snapshot
    origin=origin_snapshot(Path(record['vm']))
    if origin['before'] is None:raise ValueError('Qualified guest producer requires a host binding')
    value=json.loads(base64.b64decode(origin['before'],validate=True))
    if value['bundle']!=source['version']:raise ValueError('Guest producer differs from selected host Bundle')
    value['guestEnvironment']=source['version']
    origin['after']=base64.b64encode(gate.canonical(value)).decode()
    evidence.write_new(work/SOURCE,gate.canonical(source))
    transition=dict(schemaVersion=1,transactionID=record['id'],vmDirectory=record['vm'],
        generationID=plan.context['generationID'],planDigest=plan.record['planSHA256'],
        desiredSHA256=plan.raw_sha256,sourceSHA256=evidence.digest(work/SOURCE),origin=origin)
    evidence.write_new(work/TRANSITION,gate.canonical(transition))
    record['guestOriginSourceSHA256']=evidence.digest(work/SOURCE)
    record['guestOriginTransitionSHA256']=evidence.digest(work/TRANSITION)


def attestation_value(work,record,qualification):
    names=[SOURCE,TRANSITION,evidence.PLAN,evidence.CONTEXT,evidence.OPERATIONS,evidence.FINAL,evidence.UNDO,
           'guest-install-receipts.json']
    if record.get('fileOriginalsSHA256') is not None:names.append('guest-file-originals.json')
    rows=[json.loads(line) for line in evidence.read(work/evidence.OPERATIONS).splitlines() if line]
    return dict(schemaVersion=1,transactionID=record['id'],vmDirectory=record['vm'],
        generationID=qualification['generationID'],planDigest=qualification['planDigest'],
        desiredSHA256=qualification['desiredSHA256'],imageSHA256=qualification['imageSHA256'],
        originalIdentity=record['original'],files={name:evidence.digest(work/name) for name in names},
        blobs=evidence.blob_index(work,rows))


def attest(work,record,qualification):
    if os.geteuid()!=OWNER:raise ValueError('Guest producer attestation requires root')
    if record.get('guestOriginSourceSHA256') is None:return
    verify(work,record,qualification,live=True,require_attestation=False)
    path=work/ATTESTATION
    evidence.write_new(path,gate.canonical(attestation_value(work,record,qualification)))
    os.chmod(path,0o444)
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    try:os.fsync(fd)
    finally:os.close(fd)
    evidence.sync_directory(work)
    record['guestOriginAttestationSHA256']=evidence.digest(path)


def verify(work, record, qualification, *, live=False, require_attestation=True):
    keys=('guestOriginSourceSHA256','guestOriginTransitionSHA256')
    present=[key in record for key in keys]
    if not any(present):
        if 'guestOriginAttestationSHA256' in record:raise ValueError('Guest attestation has no source transition')
        return None
    if not all(present) or record['version']!=5 or record.get('operation') is not None:
        raise ValueError('Guest source/transition journal association is incomplete')
    for key,name in zip(keys,(SOURCE,TRANSITION)):
        if evidence.digest(work/name)!=record[key]:raise ValueError('Sealed guest source/transition changed')
    attestation=None
    if require_attestation:
        path=work/ATTESTATION;info=path.lstat()
        if (not stat.S_ISREG(info.st_mode) or info.st_nlink!=1 or info.st_uid!=OWNER
                or stat.S_IMODE(info.st_mode)!=0o444 or evidence.digest(path)!=record.get('guestOriginAttestationSHA256')):
            raise ValueError('Guest producer attestation lacks immutable root ownership or differs')
        expected=attestation_value(work,record,qualification)
        if evidence.read(path)!=gate.canonical(expected):raise ValueError('Guest attestation describes another disk or effect set')
        attestation=(path,record['guestOriginAttestationSHA256'])
    source=verify_source(json.loads(evidence.read(work/SOURCE)),require_lease=live,attestation=attestation)
    transition=json.loads(evidence.read(work/TRANSITION))
    expected=dict(schemaVersion=1,transactionID=record['id'],vmDirectory=record['vm'],
        generationID=qualification['generationID'],planDigest=qualification['planDigest'],
        desiredSHA256=qualification['desiredSHA256'],sourceSHA256=record[keys[0]])
    if set(transition)!=set(expected)|{'origin'} or any(transition[key]!=value for key,value in expected.items()):
        raise ValueError('Guest source/transition belongs to another publication')
    origin=transition['origin']
    if set(origin)!={'before','after','metadata'}:raise ValueError('Unknown guest origin transition')
    before,after=[json.loads(base64.b64decode(origin[key],validate=True)) for key in ('before','after')]
    if (not isinstance(before,dict) or not set(before).issubset({'bundle','guestEnvironment','kernel','bootChain'})
            or any(value is not None and not isinstance(value,str) for value in before.values())
            or before.get('bundle')!=source['version']
            or after!=dict(before,guestEnvironment=source['version'])):
        raise ValueError('Guest source transition changes unrelated origins')
    return source,transition


def require_before(work,record,qualification,*,require_attestation=True):
    verify_invalidation(work,record,before=True)
    value=verify(work,record,qualification,live=True,require_attestation=require_attestation)
    if value is not None:
        from .guest_undo import check_origin
        current,before,_after=check_origin(Path(record['vm']),value[1]['origin'])
        if current!=before:raise ValueError('Guest origin changed before disk publication')


def publish(work,record,qualification):
    origin=verify_invalidation(work,record)
    if origin is not None:
        from .guest_undo import publish_snapshot
        publish_snapshot(Path(record['vm']),origin)
    value=verify(work,record,qualification,live=True)
    if value is not None:
        from .guest_undo import publish_snapshot
        publish_snapshot(Path(record['vm']),value[1]['origin'])
