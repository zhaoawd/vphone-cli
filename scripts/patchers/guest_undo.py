"""Qualified DSC suffix Undo from a committed disk publication.

Only complete trailing operations can be removed without replaying retained
producers. Preview uses preserved signed preimages. Staged writes require a
live frozen plan, full readback and a new disk journal; guest origin is unknown.
"""
from dataclasses import dataclass
import base64
import contextvars
import json
import os
from pathlib import Path
import stat
import tempfile

from . import component_effects as effects
from . import component_signatures as signatures
from . import component_transport as transport
from . import plan_gate as gate
from . import undo_provenance as undo
import cfw_guest_evidence as evidence

OPERATION = 'guest-dsc-undo-v1'
REQUEST = 'guest-undo-request.json'
APPLIED = 'guest-undo-applied.json'
RECEIPTS = 'guest-component-receipts.json'
FILES = (REQUEST, APPLIED, RECEIPTS)
_ANCESTRY = contextvars.ContextVar('guest_undo_ancestry', default=())


@dataclass(frozen=True)
class SavedPlan:
    # Deliberately has no live plan path or writer capability.
    raw_sha256: str
    record: dict
    context: dict


def saved_plan(archive, generation):
    raw = evidence.read(archive / evidence.PLAN)
    context = json.loads(evidence.read(archive / evidence.CONTEXT))
    record = json.loads(raw)
    if (set(record) != {'schemaVersion', 'upstreamTarget', 'catalogSHA256', 'planSHA256', 'generationID', 'identity', 'plan'}
            or record['schemaVersion'] != 1 or record['upstreamTarget'] != gate.TARGET or gate.canonical(record) != raw
            or record['generationID'] != generation or context['schemaVersion'] != 1
            or context['vmDirectory'] != str(archive.parent.parent)
            or any(record[key] != context[key] for key in ('upstreamTarget', 'catalogSHA256', 'planSHA256', 'generationID', 'identity'))
            or gate.sha(gate.canonical(record['plan'])) != record['planSHA256']):
        raise ValueError('saved guest plan differs from committed qualification')
    return SavedPlan(gate.sha(raw), record, context)


def member_name(target):
    prefixes = ('dsc:/', undo.DSC_TARGET)
    for prefix in prefixes:
        if target.startswith(prefix):
            name = target.removeprefix(prefix)
            if name.startswith('dyld_shared_cache_arm64e') and '/' not in name and name not in ('.', '..'):
                return name
    raise ValueError('Undo preview supports qualified DSC members only')


def verify_code_pages(path):
    layouts = signatures.layouts(path)
    directories = signatures.directories(path)
    if (len(layouts) != 1 or layouts[0]['identity'] != 'dsc' or not directories
            or any(cd['count'] == 0 for cd in directories)):
        raise ValueError('Undo candidate has no DSC CodeDirectory')
    signatures.verify_slots(path, [dict(identity=cd['identity'], slot=cd['slot'], pages=range(cd['count']))
                                   for cd in directories])
    return sum(cd['count'] for cd in directories)


def selected_suffix(entry, selected):
    operations = entry['operations']
    positions = [index for index, operation in enumerate(operations) if operation['declarationID'] in selected]
    if not positions: return None
    start = positions[0]
    if any(operation['declarationID'] not in selected for operation in operations[start:]):
        raise ValueError('Undo selection retains later operations; producer replay is required')
    return operations[start:]


def preview(vm, generation, declarations, *, image=None, ignore_work=None, _committed=None):
    import cfw_disk_txn as transaction
    if not isinstance(generation, str) or not gate.DIGEST.fullmatch(generation):
        raise ValueError('Undo preview requires an expected generation digest')
    if (not declarations or any(not isinstance(item, str) or not item for item in declarations)
            or len(set(declarations)) != len(declarations)):
        raise ValueError('Undo preview requires unique declaration IDs')
    selected = set(declarations)
    committed = _committed if _committed is not None else transaction.committed_guest_evidence(vm, image=image, ignore_work=ignore_work)
    if committed is None: raise ValueError('no committed guest checkpoint; Undo is unavailable')
    archive, record, checkpoint, final = committed
    if checkpoint['generationID'] != generation: raise ValueError('Undo generation differs from committed guest')
    plan = saved_plan(archive, generation)
    store = archive / evidence.STORE
    rows = [json.loads(line) for line in evidence.read(archive / evidence.OPERATIONS).splitlines() if line]
    raw = evidence.read(archive / evidence.UNDO)
    index = undo.build(plan, rows, final['outputs'], store)
    if gate.canonical(index) != raw: raise ValueError('committed Undo index differs from rebuilt source/effects')
    available = {operation['declarationID'] for entry in index['entries'] for operation in entry['operations']}
    if not selected.issubset(available): raise ValueError('selected declaration has no qualified DSC Undo')
    covered = {(operation['rowSHA256'], member_name(entry['target']))
               for entry in index['entries'] for operation in entry['operations']}
    # A tree operation may also touch an unqualified member. Never return a
    # partial result for a declaration whose complete effects cannot be undone.
    for row in rows:
        if row['declarationID'] not in selected: continue
        for member in transport.expanded(row):
            proof = member['effect']
            if proof['before'] == proof['after']: continue
            if (gate.sha(gate.canonical(row)), member_name(member['target'])) not in covered:
                raise ValueError('selected declaration has an unqualified Undo effect')
    result = []
    for entry in index['entries']:
        current = effects.blob(store, entry['finalSHA256'])
        verify_code_pages(current)
        suffix = selected_suffix(entry, selected)
        if suffix is None: continue
        cursor = entry['finalSHA256']; reversed_operations = []
        for operation in reversed(suffix):
            if operation['afterSHA256'] != cursor: raise ValueError('reverse Undo chain differs from current member')
            candidate = effects.blob(store, operation['beforeSHA256'])
            if candidate.stat().st_size != entry['size']: raise ValueError('Undo preimage size differs')
            reversed_operations.append(operation)
            cursor = operation['beforeSHA256']
        restored = effects.blob(store, cursor)
        result.append(dict(target=entry['target'], currentSHA256=entry['finalSHA256'], restoredSHA256=cursor,
            restoresFirstOriginal=cursor == entry['originalSHA256'], verifiedCodePages=verify_code_pages(restored),
            reversedOperations=reversed_operations,
            remainingDeclarations=[op['declarationID'] for op in entry['operations'][:-len(suffix)]]))
    undo.recheck_sources(plan, rows, store)
    if evidence.read(archive / evidence.UNDO) != raw:
        raise ValueError('committed guest evidence changed during Undo preview')
    if _committed is None and transaction.committed_guest_evidence(vm, image=image, ignore_work=ignore_work) != committed:
        raise ValueError('committed guest evidence changed during Undo preview')
    return dict(schemaVersion=1, state='undo-preview', transactionID=record['id'], generationID=generation,
        imageSHA256=checkpoint['imageSHA256'], declarations=sorted(selected), entries=result,
        writeAuthorized=False, runtimeValidated=False)


def origin_snapshot(vm):
    path = vm / 'launchpad.json'
    try: raw = evidence.read(path, maximum=65536)
    except FileNotFoundError: return dict(before=None, after=None, metadata=None)
    value = json.loads(raw)
    if (not isinstance(value, dict) or not set(value).issubset({'bundle','guestEnvironment','kernel','bootChain'})
            or not isinstance(value.get('bundle'), str)
            or any(item is not None and not isinstance(item, str) for item in value.values())):
        raise ValueError('guest Undo requires a readable machine binding')
    info = path.lstat()
    value.pop('guestEnvironment', None)
    # Undo changes installed effects without a fresh trusted producer. The
    # affected origin becomes unknown; other layer selections are preserved.
    return dict(before=base64.b64encode(raw).decode(), after=base64.b64encode(gate.canonical(value)).decode(),
                metadata=dict(mode=stat.S_IMODE(info.st_mode), uid=info.st_uid, gid=info.st_gid))


def check_origin(vm, origin, *, published=False):
    try: current = evidence.read(vm / 'launchpad.json', maximum=65536)
    except FileNotFoundError: current = None
    before, after = [base64.b64decode(origin[key], validate=True) if origin[key] is not None else None for key in ('before','after')]
    if current not in ((after,) if published else (before, after)):
        raise ValueError('guest origin changed outside the recorded transaction')
    if current is not None and effects.metadata(vm/'launchpad.json') != origin['metadata']:
        raise ValueError('guest origin ownership or mode changed outside the transaction')
    return current, before, after


def publish_origin(work, record):
    if record.get('operation') != OPERATION: return
    request = json.loads(evidence.read(work / REQUEST))
    vm = Path(record['vm'])
    current, before, after = check_origin(vm, request['origin'])
    if current == after: return
    fd, name = tempfile.mkstemp(prefix='.cfw-origin-', dir=vm)
    try:
        with os.fdopen(fd, 'wb') as stream:
            info = os.fstat(stream.fileno()); meta = request['origin']['metadata']
            if (info.st_uid, info.st_gid) != (meta['uid'], meta['gid']): os.fchown(stream.fileno(), meta['uid'], meta['gid'])
            os.fchmod(stream.fileno(), meta['mode'])
            stream.write(after); stream.flush(); os.fsync(stream.fileno())
        if evidence.read(vm / 'launchpad.json', maximum=65536) != before:
            raise ValueError('guest origin changed before atomic publication')
        os.replace(name, vm / 'launchpad.json'); evidence.sync_directory(vm)
    finally:
        if os.path.exists(name): os.unlink(name)


def request_for(work, record):
    raw = evidence.read(work / REQUEST)
    if gate.sha(raw) != record.get('guestUndoRequestSHA256'):
        raise ValueError('guest Undo request differs from journal')
    request = json.loads(raw)
    if (request.get('schemaVersion') != 1 or request.get('transactionID') != record['id']
            or request.get('vmDirectory') != record['vm'] or record.get('operation') != OPERATION):
        raise ValueError('guest Undo request belongs to another transaction')
    return request


def prepare(args):
    import cfw_disk_txn as transaction
    record = transaction.staged_record(args.work)
    if record.get('version') not in (3, 4) or record.get('operation') is not None:
        raise ValueError('guest Undo requires a new v3/v4 staged transaction')
    transaction.run_checks('pre-install', args, record)
    plan = transaction.current_guest_plan()
    parent = transaction.committed_guest_evidence(args.vm)
    selection = preview(args.vm, args.generation, args.declaration)
    archive, parent_record, checkpoint, parent_final = parent
    if evidence.read(archive / evidence.PLAN) != plan.record_json:
        raise ValueError('guest Undo write requires the same live plan as the applied journal')
    if transaction.checked_image_digest(args.work / 'Disk.img') != checkpoint.get('currentImageSHA256', checkpoint['imageSHA256']):
        raise ValueError('guest Undo clone differs from the committed parent disk')
    selected = set(args.declaration)
    rows = [json.loads(line) for line in evidence.read(archive / evidence.OPERATIONS).splitlines() if line]
    retained = [row for row in rows if row['declarationID'] not in selected]
    if not retained: raise ValueError('guest Undo has no retained source/effect evidence')
    store = args.work / evidence.STORE; store.mkdir(mode=0o700)
    for path in (archive / evidence.STORE).iterdir():
        if effects.persist(path, store) != path.name: raise ValueError('parent guest blob changed during copy')
    evidence.write_new(args.work / evidence.OPERATIONS, b''.join(gate.canonical(row)+b'\n' for row in retained))
    request = dict(schemaVersion=1, transactionID=record['id'], vmDirectory=str(args.vm),
        parentTransactionID=parent_record['id'], parentCheckpointSHA256=parent_record['guestEvidenceSHA256'],
        selection=selection, targetMetadata=selection_metadata(selection, parent_final),
        retainedOperationsSHA256=effects.digest(args.work / evidence.OPERATIONS),
        origin=origin_snapshot(args.vm))
    raw = gate.canonical(request); evidence.write_new(args.work / REQUEST, raw)
    record.update(operation=OPERATION, guestUndoRequestSHA256=gate.sha(raw))
    transaction.save_record(args.work, record)
    if transaction.committed_guest_evidence(args.vm) != parent:
        raise ValueError('guest Undo parent changed during preparation')


def target_at(root, name, volume_root):
    path = Path(root) / name
    current = path.parent
    while True:
        if current.is_symlink(): raise ValueError('linked guest Undo target parent')
        if current == volume_root: break
        if current == current.parent: raise ValueError('guest Undo target is outside its volume')
        current = current.parent
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ValueError('guest Undo target is not a private regular file')
    return path, info


def apply(args):
    import cfw_disk_txn as transaction
    from . import final_guest
    record = transaction.staged_record(args.work); request = request_for(args.work, record)
    transaction.run_checks('pre-install', args, record)
    if (args.work / APPLIED).exists(): raise ValueError('guest Undo was already applied')
    current_origin, before_origin, _ = check_origin(args.vm, request['origin'])
    if current_origin != before_origin: raise ValueError('guest origin changed before staged Undo')
    if preview(args.vm, request['selection']['generationID'], request['selection']['declarations']) != request['selection']:
        raise ValueError('guest Undo parent selection changed')
    plan = transaction.current_guest_plan()
    roots, mounted, identities = final_guest.mount_roots(plan, args.work / 'Disk.img', {'system'}, read_only=False)
    attachment = final_guest.writable_attachment_state(mounted)
    def check_mount():
        info = roots['system'].lstat()
        if ((info.st_dev,info.st_ino) != identities['system']
                or final_guest.writable_attachment_state(final_guest.attachments(args.work/'Disk.img')) != attachment):
            raise ValueError('guest Undo writable mount changed')
        final_guest.require_mount(roots['system'],mounted['ContainerReference']+'s1',False)
    targets = []
    for entry in request['selection']['entries']:
        path, info = target_at(roots['dsc'], member_name(entry['target']), roots['system'])
        source = effects.blob(args.work / evidence.STORE, entry['restoredSHA256'])
        if effects.digest(path) != entry['currentSHA256'] or info.st_size != source.stat().st_size:
            raise ValueError('guest Undo target differs from the committed member')
        if effects.metadata(path) != request['targetMetadata'][member_name(entry['target'])]:
            raise ValueError('guest Undo target metadata differs from the committed member')
        verify_code_pages(path); verify_code_pages(source)
        targets.append((entry, path, info, source))
    applied = []
    check_mount()
    for entry, path, before, source in targets:
        fd = os.open(path, os.O_WRONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            actual = os.fstat(fd)
            keys = ('st_dev','st_ino','st_size','st_mtime_ns','st_ctime_ns')
            if any(getattr(actual,k) != getattr(before,k) for k in keys): raise ValueError('guest Undo target changed before write')
            with effects.regular(source) as stream:
                while block := stream.read(effects.CHUNK):
                    data = memoryview(block)
                    while data:
                        count = os.write(fd, data)
                        if count <= 0: raise OSError('short guest Undo write')
                        data = data[count:]
            os.fsync(fd)
        finally: os.close(fd)
        if effects.digest(path) != entry['restoredSHA256']: raise ValueError('guest Undo write did not read back')
        verify_code_pages(path)
        applied.append(dict(target=entry['target'], beforeSHA256=entry['currentSHA256'], afterSHA256=entry['restoredSHA256'],
                            metadata=effects.metadata(path)))
    evidence.write_new(args.work / APPLIED, gate.canonical(dict(schemaVersion=1, transactionID=record['id'], entries=applied)))
    check_mount()
    transaction.run_checks('pre-install', args, record)


def parent_image(work, record):
    import cfw_disk_txn as transaction
    vm = Path(record['vm'])
    matches = [path for path in (vm/'Disk.img', work/'Disk.img', work/transaction.PREVIOUS)
               if transaction.is_same(path, record['original'])]
    if len(matches) != 1: raise ValueError('guest Undo parent has no unique retained disk')
    return matches[0]


def verify_operation(work, record, final):
    import cfw_disk_txn as transaction
    ancestry = _ANCESTRY.get()
    key = (record['vm'], record['id'])
    if key in ancestry or len(ancestry) >= 8: raise ValueError('guest Undo ancestry is cyclic or exceeds eight transactions')
    token = _ANCESTRY.set(ancestry + (key,))
    try:
        request = request_for(work, record); vm = Path(record['vm'])
        image = parent_image(work, record)
        parent = transaction.committed_guest_evidence(vm, image=image, ignore_work=work)
        if (parent is None or parent[1]['id'] != request['parentTransactionID']
                or parent[1]['guestEvidenceSHA256'] != request['parentCheckpointSHA256']):
            raise ValueError('guest Undo parent journal differs')
        selection = preview(vm, request['selection']['generationID'], request['selection']['declarations'],
                            image=image, ignore_work=work, _committed=parent)
        if selection != request['selection']: raise ValueError('guest Undo selection differs from qualified parent')
        if selection_metadata(selection, parent[3]) != request['targetMetadata']:
            raise ValueError('guest Undo target metadata differs from parent')
        rows = [json.loads(line) for line in evidence.read(parent[0]/evidence.OPERATIONS).splitlines() if line]
        kept = b''.join(gate.canonical(row)+b'\n' for row in rows if row['declarationID'] not in set(selection['declarations']))
        if (evidence.read(work/evidence.OPERATIONS) != kept or gate.sha(kept) != request['retainedOperationsSHA256']):
            raise ValueError('guest Undo retained effects differ from parent')
        applied = json.loads(evidence.read(work/APPLIED))
        if applied.get('schemaVersion') != 1 or applied.get('transactionID') != record['id']:
            raise ValueError('guest Undo application belongs to another journal')
        expected = []
        for entry in selection['entries']:
            matches = [item for item in final['outputs'] if member_name_or_none(item['target']) == member_name(entry['target'])]
            if len(matches) != 1 or matches[0]['state'].get('sha256') != entry['restoredSHA256']:
                raise ValueError('final guest Undo member differs from the restored candidate')
            verify_code_pages(effects.blob(work/evidence.STORE, entry['restoredSHA256']))
            state = matches[0]['state']
            if {k:state[k] for k in ('mode','uid','gid')} != request['targetMetadata'][member_name(entry['target'])]:
                raise ValueError('guest Undo changed target ownership or mode')
            expected.append(dict(target=entry['target'], beforeSHA256=entry['currentSHA256'], afterSHA256=entry['restoredSHA256'],
                                 metadata={k:state[k] for k in ('mode','uid','gid')}))
        if applied.get('entries') != expected: raise ValueError('guest Undo applied effects differ from final readback')
        # The parent was fully qualified above. Recheck its complete sealed
        # bytes without recursively replaying every ancestor a second time.
        transaction.verify_guest_evidence(parent[0], parent[1], image, check_operation=False, allow_runtime=True)
        if transaction.load_record(parent[0]) != parent[1]: raise ValueError('parent journal changed during Undo verification')
        if work.parent.name != '.cfw-history':
            check_origin(vm, request['origin'])
        elif not ancestry and (vm/'launchpad.json').exists():
            # Host selection can change after commit. Historical ancestors do
            # not own the current binding; the live Undo result retains unknown
            # guest origin until a later guest producer establishes one.
            if json.loads(evidence.read(vm/'launchpad.json', maximum=65536)).get('guestEnvironment') is not None:
                raise ValueError('committed Undo guest origin is not unknown')
        return request
    finally: _ANCESTRY.reset(token)


def member_name_or_none(target):
    try: return member_name(target)
    except ValueError: return None


def selection_metadata(selection, final):
    result = {}
    for entry in selection['entries']:
        name = member_name(entry['target'])
        matches = [item['state'] for item in final['outputs'] if member_name_or_none(item['target']) == name]
        if len(matches) != 1: raise ValueError('guest Undo member has no unique prior metadata')
        result[name] = {key:matches[0][key] for key in ('mode','uid','gid')}
    return result


def receipts(work, record, final, image_sha256):
    request = verify_operation(work, record, final)
    rows = [json.loads(line) for line in evidence.read(work/evidence.OPERATIONS).splitlines() if line]
    return dict(schemaVersion=1, transactionID=record['id'], scope='installed-component-effects',
        generationID=final['generationID'], planDigest=final['planDigest'], desiredSHA256=final['desiredSHA256'],
        imageSHA256=image_sha256, operation=OPERATION, removedDeclarations=request['selection']['declarations'],
        appliedDeclarations=sorted({row['declarationID'] for row in rows}),
        components=final['outputs'], guestOrigin=dict(state='unknown', reason='historical-undo-without-fresh-trusted-producer'),
        runtimeValidated=False)
