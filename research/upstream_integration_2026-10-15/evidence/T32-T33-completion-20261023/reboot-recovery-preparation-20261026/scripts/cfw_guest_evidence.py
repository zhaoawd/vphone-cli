"""Durable guest-effect evidence bound to one CFW journal and image.

This is publication evidence, not pristine-original or runtime authority. The
qualified final reader owns APFS/effect verification; this module freezes its
result and the observed input blobs before the disk transaction may publish.
"""
import hashlib
import errno
import json
import os
from pathlib import Path
import re
import stat
import tempfile

CHECKPOINT = 'guest-publication.json'
PLAN = 'guest-plan.json'
CONTEXT = 'guest-context.json'
OPERATIONS = 'guest-changes.jsonl'
FINAL = 'guest-effects-final.json'
UNDO = 'guest-undo-provenance.json'
STORE = 'effect-blobs'
POSTIMAGE = 'guest-postimage.img'
DIGEST = re.compile(r'[0-9a-f]{64}\Z')
CHUNK = 1 << 20


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try: os.fsync(fd)
    finally: os.close(fd)


def read(path, maximum=64 << 20):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > maximum:
            raise ValueError('evidence input is not a bounded private regular file')
        data = bytearray()
        while block := os.read(fd, min(CHUNK, maximum + 1 - len(data))):
            data.extend(block)
            if len(data) > maximum: raise ValueError('evidence input exceeds bound')
        unchanged(path, fd, before)
        return bytes(data)
    finally: os.close(fd)


def unchanged(path, fd, before):
    keys = ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns', 'st_nlink')
    after, named = os.fstat(fd), Path(path).lstat()
    if any(getattr(before, k) != getattr(after, k) or getattr(after, k) != getattr(named, k) for k in keys):
        raise ValueError('guest evidence changed during read')


def digest(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise ValueError('guest blob is not a private regular file')
        h = hashlib.sha256()
        while block := os.read(fd, CHUNK): h.update(block)
        unchanged(path, fd, before)
        return h.hexdigest()
    finally: os.close(fd)


def write_new(path, data):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(data); stream.flush(); os.fsync(stream.fileno())
    sync_directory(Path(path).parent)


def write_final(path, data):
    """Replace this invocation's earlier readback with its post-snapshot one."""
    try: read(path)
    except FileNotFoundError: pass
    fd, name = tempfile.mkstemp(prefix='.guest-final-', dir=Path(path).parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data); stream.flush(); os.fsync(stream.fileno())
        os.replace(name, path)
        sync_directory(Path(path).parent)
    finally:
        if os.path.exists(name): os.unlink(name)


def blob_index(work, rows):
    store = work / STORE
    info = store.lstat()
    if not stat.S_ISDIR(info.st_mode): raise ValueError('linked guest evidence store')
    result = {}
    for path in sorted(store.iterdir()):
        if not DIGEST.fullmatch(path.name) or digest(path) != path.name:
            raise ValueError('invalid or corrupt guest evidence blob')
        result[path.name] = path.stat().st_size
    after = store.lstat()
    if any(getattr(info, k) != getattr(after, k) for k in ('st_dev', 'st_ino', 'st_mtime_ns', 'st_ctime_ns')):
        raise ValueError('guest evidence store changed during read')
    required = set()
    for row in rows:
        proof = row.get('effect')
        if not isinstance(proof, dict) or proof.get('schemaVersion') != 1:
            raise ValueError('guest row lacks durable effect evidence')
        for key in ('before', 'after', 'source'):
            value = proof.get(key, {})
            if value.get('kind') == 'file': required.add(value['sha256'])
        if 'sourceImageProof' in row: required.add(row['sourceImageProof']['bindingSHA256'])
        if 'sourceArchive' in proof: required.add(proof['sourceArchive']['archiveSHA256'])
        if 'entitlementsSource' in proof:
            required.add(proof['entitlementsSource']['state']['sha256'])
    if not required.issubset(result): raise ValueError('guest evidence is missing a preserved input/output blob')
    return result


def image_identity(info):
    return {key: getattr(info, 'st_' + key) for key in ('dev', 'ino', 'size', 'mtime_ns')}


def runtime_identity(info):
    # Python exposes Darwin birth time as seconds. Keep that representation in
    # the checkpoint; it supplements dev/inode and is never effect authority.
    return dict(dev=info.st_dev, ino=info.st_ino, size=info.st_size, birthtime=info.st_birthtime)


def preserve_postimage(work, image, image_sha256):
    """Retain the detached publication image independently of runtime writes."""
    import cfw_disk_txn as transaction
    fd = os.open(image, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        destination = work / POSTIMAGE
        try: transaction.clone_file(fd, destination)
        except OSError as error:
            if error.errno == errno.EEXIST: raise
            if transaction.copy_file(fd, destination, before.st_size) != image_sha256:
                raise ValueError('publication postimage copy differs')
        out = os.open(destination, os.O_RDONLY | os.O_NOFOLLOW)
        try: os.fsync(out)
        finally: os.close(out)
        unchanged(image, fd, before)
        if transaction.checked_image_digest(destination) != image_sha256:
            raise ValueError('publication postimage differs from staged image')
        sync_directory(work)
        return image_identity(destination.lstat())
    finally: os.close(fd)


def prepare(work, record, plan, image_sha256):
    """The caller keeps the inherited VM lock and qualifies the live plan."""
    raw = read(work / OPERATIONS)
    rows = [json.loads(line) for line in raw.splitlines() if line]
    final_raw = read(work / FINAL)
    final = json.loads(final_raw)
    empty_file_undo=record['version']==5 and record.get('operation')=='guest-component-undo-v2'
    if (not rows and not empty_file_undo) or final.get('schemaVersion') != 1 or final.get('transactionID') != record['id'] or not final.get('outputs'):
        raise ValueError('missing final guest effect verification')
    context, desired = plan.context, plan.record
    qualification = {'generationID': context['generationID'], 'planDigest': desired['planSHA256'],
                     'desiredSHA256': plan.raw_sha256}
    if any(final.get(k) != v or any(row.get(k) != v for row in rows) for k, v in qualification.items()):
        raise ValueError('final guest evidence differs from qualified plan')
    if final.get('operationsSHA256') != hashlib.sha256(raw).hexdigest():
        raise ValueError('final guest operation digest differs')
    image = work / 'Disk.img'
    actual = image_identity(image.lstat())
    if (final.get('stagedImage') != str(image) or
            any(final.get('stagedIdentity', {}).get(k) != v for k, v in actual.items())):
        raise ValueError('final guest readback does not describe the final staged image')
    for name, data in [(PLAN, plan.record_json), (CONTEXT, plan.context_json)]:
        write_new(work / name, data)
    extra = ()
    if record.get('operation') is not None:
        from patchers import guest_undo
        if record['operation'] not in guest_undo.OPERATIONS: raise ValueError('unknown guest journal operation')
        write_new(work / guest_undo.RECEIPTS, canonical(guest_undo.receipts(work, record, final, image_sha256)))
        extra = guest_undo.FILES
    if record['version'] == 5 and record.get('operation') is None:
        from patchers import guest_receipts
        from patchers import guest_origin
        origin=guest_origin.verify(work,record,qualification,require_attestation=False)
        write_new(work / guest_receipts.FILENAME, canonical(guest_receipts.build(record, final, rows, image_sha256,
            source=origin[0] if origin else None)))
        extra = (guest_receipts.FILENAME,)
        if record.get('guestOriginInvalidationSHA256') is not None:
            guest_origin.verify_invalidation(work,record,before=True)
            extra=extra+(guest_origin.INVALIDATION,)
        if origin is not None:
            guest_origin.attest(work,record,dict(qualification,imageSHA256=image_sha256))
            extra=extra+(guest_origin.SOURCE,guest_origin.TRANSITION,guest_origin.ATTESTATION)
    if record.get('fileOriginalsSHA256') is not None:
        from patchers.file_originals import FILENAME
        if digest(work/FILENAME)!=record['fileOriginalsSHA256']:raise ValueError('File originals differ from journal')
        extra=extra+(FILENAME,)
    if record.get('operation') is not None:
        from patchers import guest_undo
        observed = json.loads(read(work / guest_undo.APPLIED))
        if observed.get('schemaVersion') == 2 and observed['recoverySource']['sourceImageSHA256'] != image_sha256:
            raise ValueError('Recovered disk differs from the preserved complete Undo image')
    files = {name: digest(work / name) for name in (PLAN, CONTEXT, OPERATIONS, FINAL, UNDO) + extra}
    verify_undo_binding(record, final, files)
    if files[PLAN] != plan.raw_sha256: raise ValueError('preserved desired plan digest differs')
    blobs = blob_index(work, rows)
    checkpoint = dict(schemaVersion=1, transactionID=record['id'], vmDirectory=record['vm'],
        **qualification, imageIdentity=actual, imageSHA256=image_sha256, files=files, blobs=blobs)
    if record['version'] in (4, 5):
        checkpoint.update(schemaVersion=3 if record['version'] == 5 else 2, runtimeIdentity=runtime_identity(image.lstat()),
                          postimageIdentity=preserve_postimage(work, image, image_sha256))
    write_new(work / CHECKPOINT, canonical(checkpoint))
    return digest(work / CHECKPOINT)


def verify(work, record, image, image_sha256, *, check_operation=True, allow_runtime=False):
    expected = record.get('guestEvidenceSHA256')
    if not isinstance(expected, str) or not DIGEST.fullmatch(expected):
        raise ValueError('guest publication has no sealed evidence checkpoint')
    raw = read(work / CHECKPOINT)
    if hashlib.sha256(raw).hexdigest() != expected: raise ValueError('guest checkpoint differs from journal')
    value = json.loads(raw)
    version = record['version']
    if (value.get('schemaVersion') != (3 if version == 5 else 2 if version == 4 else 1) or value.get('transactionID') != record['id']
            or value.get('vmDirectory') != record['vm']):
        raise ValueError('guest checkpoint image or transaction differs')
    from cfw_reboot_identity import matches_historical
    if version in (4, 5):
        continuity = value.get('runtimeIdentity', {})
        if (not matches_historical(image, runtime_identity(image.lstat()), continuity) or
                any(continuity.get(k) != value.get('imageIdentity', {}).get(k) for k in ('dev', 'ino', 'size'))):
            raise ValueError('guest runtime image identity differs')
        post = work / POSTIMAGE
        import cfw_disk_txn as transaction
        if (not matches_historical(post, image_identity(post.lstat()), value.get('postimageIdentity'))
                or transaction.checked_image_digest(post) != value['imageSHA256']):
            raise ValueError('sealed guest postimage differs')
    if not (allow_runtime and version in (4, 5)):
        if not matches_historical(image, image_identity(image.lstat()), value.get('imageIdentity')) or value.get('imageSHA256') != image_sha256:
            raise ValueError('guest checkpoint image or transaction differs')
    if any(value['imageIdentity'][k] != record.get('staged', {}).get(k) for k in ('dev', 'ino')):
        raise ValueError('guest checkpoint does not describe the journal staged inode')
    expected_files = {PLAN, CONTEXT, OPERATIONS, FINAL, UNDO}
    if record.get('operation') is not None:
        from patchers import guest_undo
        if record['operation'] not in guest_undo.OPERATIONS: raise ValueError('unknown guest journal operation')
        expected_files.update(guest_undo.FILES)
    if version == 5 and record.get('operation') is None:
        from patchers import guest_receipts
        expected_files.add(guest_receipts.FILENAME)
        if record.get('guestOriginInvalidationSHA256') is not None:
            from patchers import guest_origin
            guest_origin.verify_invalidation(work,record)
            expected_files.add(guest_origin.INVALIDATION)
        if any(key in record for key in ('guestOriginSourceSHA256','guestOriginTransitionSHA256')):
            from patchers import guest_origin
            expected_files.update((guest_origin.SOURCE,guest_origin.TRANSITION,guest_origin.ATTESTATION))
    if record.get('fileOriginalsSHA256') is not None:
        from patchers.file_originals import FILENAME
        expected_files.add(FILENAME)
        if value.get('files',{}).get(FILENAME)!=record['fileOriginalsSHA256']:
            raise ValueError('File originals differ from sealed journal')
    if set(value.get('files', {})) != expected_files:
        raise ValueError('guest checkpoint file set differs')
    for name, wanted in value['files'].items():
        if digest(work / name) != wanted: raise ValueError('sealed guest evidence changed: ' + name)
    plan, context, final = [json.loads(read(work / name)) for name in (PLAN, CONTEXT, FINAL)]
    verify_undo_binding(record, final, value['files'])
    if version == 5 and record.get('operation') is None:
        from patchers import guest_receipts
        from patchers import guest_origin
        origin=guest_origin.verify(work,record,value)
        receipt_rows = [json.loads(line) for line in read(work / OPERATIONS).splitlines() if line]
        receipt = guest_receipts.build(record, final, receipt_rows, value['imageSHA256'],source=origin[0] if origin else None)
        if read(work / guest_receipts.FILENAME) != canonical(receipt):
            raise ValueError('guest component receipt differs from sealed effects')
    if (value.get('desiredSHA256') != value['files'][PLAN] or
            any(plan.get(k) != value.get(v) or context.get(k) != value.get(v)
                for k, v in [('generationID', 'generationID'), ('planSHA256', 'planDigest')]) or
            context.get('vmDirectory') != value['vmDirectory'] or final.get('transactionID') != record['id'] or
            any(final.get(k) != value.get(k) for k in ('generationID', 'planDigest', 'desiredSHA256')) or
            final.get('operationsSHA256') != value['files'][OPERATIONS]):
        raise ValueError('sealed guest qualification differs from saved plan/readback')
    rows = [json.loads(line) for line in read(work / OPERATIONS).splitlines() if line]
    if blob_index(work, rows) != value.get('blobs'): raise ValueError('sealed guest blob set changed')
    if record.get('operation') is not None and check_operation:
        from patchers import guest_undo
        receipt = json.loads(read(work / guest_undo.RECEIPTS))
        if receipt != guest_undo.receipts(work, record, final, value['imageSHA256']):
            raise ValueError('guest receipt differs from actual committed effects')
    if record.get('operation') is not None:
        from patchers import guest_undo
        observed = json.loads(read(work / guest_undo.APPLIED))
        if observed.get('schemaVersion') == 2 and observed['recoverySource']['sourceImageSHA256'] != value['imageSHA256']:
            raise ValueError('Recovered checkpoint differs from its complete source image')
    if allow_runtime and version in (4, 5):
        value = dict(value, currentImageSHA256=image_sha256, runtimeImageChanged=image_sha256 != value['imageSHA256'])
    return value


def verify_undo_binding(record, final, files):
    if (final.get('undoProvenanceSHA256') != files[UNDO] or record.get('undoProvenance') != {
            'indexSHA256': files[UNDO], 'finalProofSHA256': files[FINAL], 'operationsSHA256': files[OPERATIONS]}):
        raise ValueError('sealed Undo provenance differs from final proof or journal')
