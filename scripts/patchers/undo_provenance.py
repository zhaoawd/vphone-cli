"""Generation-backed DSC preimages; qualification is not permission to migrate.

Whole-member originals and each operation's immediate preimage are separate.
No installed guest bytes are promoted to first originals. The final reader
rebuilds this index from source observations and the complete effect chain;
the disk transaction binds and rechecks its digest before publication.
"""
import hashlib
import json
import os
from pathlib import Path
import stat

from . import component_effects as effects
from . import plan_gate as gate
from .volume_state import volume_read_only

FILENAME = 'guest-undo-provenance.json'
DSC_MEMBER = 'System/Library/Caches/com.apple.dyld/'
DSC_TARGET = 'system:/System/Cryptexes/OS/' + DSC_MEMBER


def tree_digest(path):
    """FirmwareGeneration.treeDigest encoding, including file/directory tags."""
    path = Path(path); before = path.lstat()
    digest = hashlib.sha256()
    if stat.S_ISDIR(before.st_mode):
        names = sorted(os.listdir(path)); digest.update(b'directory\0')
        for name in names:
            digest.update((name+'\0'+tree_digest(path/name)+'\0').encode())
        after = path.lstat()
        if (before.st_dev, before.st_ino, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_mtime_ns) or names != sorted(os.listdir(path)):
            raise ValueError('generation original directory changed')
    else:
        digest.update(b'file\0')
        with effects.regular(path) as stream:
            while block := stream.read(effects.CHUNK): digest.update(block)
    return digest.hexdigest()


def qualify_source(plan, source):
    """Re-read the manifest-bound top-level original, not a self-described hash."""
    source = Path(source)
    generation = Path(plan.context['vmDirectory'])/'.firmware-generations'/plan.context['generationID']
    root = generation/'originals'
    if not source.is_absolute() or root not in source.parents or '..' in source.parts:
        raise ValueError('Undo source is outside current generation originals')
    current = source
    while current != Path(plan.context['vmDirectory']):
        if current.is_symlink(): raise ValueError('linked Undo source path')
        current = current.parent
    raw = gate.strict_bytes(generation/'manifest.json'); manifest = json.loads(raw)
    if (manifest.get('schemaVersion') != 1 or manifest.get('id') != plan.context['generationID']
            or gate.sha(gate.canonical(manifest['content'])) != manifest['id']):
        raise ValueError('Undo generation manifest differs from verified generation')
    name = source.relative_to(root).parts[0]
    matches = [item for item in manifest['content']['originals'] if item.get('name') == name]
    if len(matches) != 1 or tree_digest(root/name) != matches[0]['sha256']:
        raise ValueError('Undo source differs from manifest original tree')
    from .cryptex_source import observation
    observed = observation(source)
    if gate.strict_bytes(generation/'manifest.json') != raw:
        raise ValueError('Undo generation manifest changed during qualification')
    return {'manifestSHA256':gate.sha(raw), 'originalName':name,
            'originalTreeSHA256':matches[0]['sha256'], 'source':observed}


def implementation():
    """Observed producer source fingerprint, not a toolchain attestation."""
    root = Path(__file__).parent
    files = {path.name:effects.digest(path) for path in sorted(root.glob('*.py'))}
    return {'schemaVersion':1, 'kind':'python-patchers-source', 'sha256':gate.sha(gate.canonical(files))}


def capture_baseline(plan, root, cache, binding):
    """Called only after mounting an unchanged generation-derived image readonly."""
    from .cryptex_source import observation, mounted
    import plistlib
    import subprocess
    root = Path(root); cache = Path(cache)
    def readonly():
        info = plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil','info','-plist',str(root)]))
        if not volume_read_only(info) or info.get('MountPoint') != str(root):
            raise ValueError('Undo baseline requires exact readonly Cryptex volume')
    readonly()
    if mounted(plan,root) != cache: raise ValueError('Undo baseline mount differs from source cache')
    image = observation(cache)
    if image['sha256'] != binding['cacheSHA256'] or binding.get('transition'):
        raise ValueError('Undo baseline cannot use a transformed image')
    source = qualify_source(plan,binding['source'])
    if source['source']['sha256'] != binding['sourceSHA256']:
        raise ValueError('Undo source observation differs from image binding')
    directory = root/DSC_MEMBER
    members = {}
    if directory.exists():
        current = directory
        while current != root:
            if current.is_symlink(): raise ValueError('linked original DSC directory')
            current = current.parent
        for path in sorted(directory.iterdir()):
            if path.name.startswith('dyld_shared_cache_arm64e') and not path.name.endswith('.map'):
                members[path.name] = effects.content(effects.state(path,False))
                if members[path.name]['kind'] != 'file': raise ValueError('original DSC member is not regular')
    readonly()
    if mounted(plan,root) != cache: raise ValueError('Undo baseline mount changed')
    if observation(cache) != image: raise ValueError('Undo baseline image changed during read')
    return {'schemaVersion':1, 'readOnly':True, 'image':image, 'generationSource':source, 'members':members}


def build(plan, rows, outputs, store):
    """Consume already verified effects and qualify only complete sourced chains."""
    from .component_transport import expanded, image_bindings
    bindings = image_bindings(rows,store,plan)
    nodes = {}; unavailable = set(); qualified_sources = {}
    for row in rows:
        if row.get('generationID') != plan.context['generationID'] or row.get('planDigest') != plan.record['planSHA256'] or row.get('desiredSHA256') != plan.raw_sha256:
            raise ValueError('Undo effect chain mixes generation or plan')
        identifier = gate.sha(gate.canonical(row))
        for member in expanded(row):
            target = member['target']; proof = member['effect']; path = member['path']
            is_dsc = target.startswith('dsc:/') or target.startswith(DSC_TARGET)
            if not is_dsc or proof['after']['kind'] != 'file': continue
            if proof['operation'] == 'copy' and target.startswith(DSC_TARGET):
                binding = bindings.get(id(row)); baseline = None if binding is None else binding.get('originalDSC')
                name = target.removeprefix(DSC_TARGET)
                if baseline is None:
                    nodes.pop(path,None); continue
                if baseline.get('schemaVersion') != 1 or baseline.get('readOnly') is not True or binding.get('transition'):
                    raise ValueError('Undo baseline has no original readonly source')
                binding_sha = row['sourceImageProof']['bindingSHA256']
                if binding_sha not in qualified_sources:
                    actual = qualify_source(plan,binding['source'])
                    if actual != baseline['generationSource'] or actual['source']['sha256'] != binding['sourceSHA256']:
                        raise ValueError('Undo source no longer matches original observation')
                    qualified_sources[binding_sha] = actual
                if row['sourceImageProof']['image'] != baseline['image'] or baseline['image']['sha256'] != binding['cacheSHA256']:
                    raise ValueError('Undo copy does not consume the original image')
                if baseline['members'].get(name) != effects.content(proof['source']) or effects.content(proof['source']) != effects.content(proof['after']):
                    raise ValueError('Undo copy member differs from readonly baseline')
                nodes[path] = {'target':target, 'originalSHA256':proof['after']['sha256'],
                               'sourceBindingSHA256':binding_sha, 'copyRowSHA256':identifier,
                               'current':proof['after'], 'operations':[]}
                continue
            if proof['operation'] != 'change':
                if path in nodes: raise ValueError('unsupported Undo member transport')
                continue
            node = nodes.get(path)
            if node is None:
                unavailable.add(target); continue
            if proof['before'] != node['current']: raise ValueError('Undo effect chain is incomplete')
            node['current'] = proof['after']; node['target'] = target
            if proof['before']['sha256'] == proof['after']['sha256']: continue
            stamp = proof.get('implementation')
            if (not isinstance(stamp,dict) or set(stamp) != {'schemaVersion','kind','sha256'}
                    or stamp['schemaVersion'] != 1 or stamp['kind'] != 'python-patchers-source'
                    or not gate.DIGEST.fullmatch(stamp.get('sha256',''))):
                raise ValueError('Undo operation has no implementation fingerprint')
            before = effects.blob(store,proof['before']['sha256']); after = effects.blob(store,proof['after']['sha256'])
            if before.stat().st_size != after.stat().st_size:
                raise ValueError('Undo does not support size-changing DSC effects')
            node['operations'].append({'declarationID':row['declarationID'], 'rowSHA256':identifier,
                'implementation':stamp, 'beforeSHA256':proof['before']['sha256'],
                'afterSHA256':proof['after']['sha256'], 'ranges':effects.ranges(before,after)})
    entries = []
    for node in nodes.values():
        if not node['operations']: continue
        original = effects.blob(store,node['originalSHA256'])
        matches = [item for item in outputs if item['target'] == node['target']]
        if len(matches) != 1 or matches[0]['state'] != node['current']:
            raise ValueError('Undo final member has no verified output')
        expected = node['originalSHA256']
        for operation in node['operations']:
            if operation['beforeSHA256'] != expected: raise ValueError('Undo byte chain does not reach first original')
            expected = operation['afterSHA256']
        if expected != node['current']['sha256']: raise ValueError('Undo chain final digest differs')
        entries.append({key:value for key,value in node.items() if key != 'current'} |
                       {'finalSHA256':expected, 'size':original.stat().st_size})
    return {'schemaVersion':1, 'state':'qualified-preimages-not-migration-authority',
            'generationID':plan.context['generationID'], 'planSHA256':plan.record['planSHA256'],
            'desiredSHA256':plan.raw_sha256, 'entries':sorted(entries,key=lambda item:item['target']),
            'unqualifiedTargets':sorted(unavailable)}


def recheck_sources(plan, rows, store):
    from .component_transport import image_bindings
    seen = set()
    for binding in image_bindings(rows,store,plan).values():
        baseline = binding.get('originalDSC')
        if baseline is None or binding['source'] in seen: continue
        seen.add(binding['source'])
        if qualify_source(plan,binding['source']) != baseline['generationSource']:
            raise ValueError('Undo generation source changed during qualification')


def persist(plan, rows, outputs, work):
    index = build(plan,rows,outputs,work/'effect-blobs')
    path = work/FILENAME
    data = gate.canonical(index)
    if path.exists() or path.is_symlink():
        if gate.strict_bytes(path) != data: raise ValueError('existing Undo index differs from current qualification')
        return gate.sha(data)
    fd = os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'wb') as stream: stream.write(data); stream.flush(); os.fsync(stream.fileno())
    if gate.strict_bytes(path) != data: raise ValueError('Undo index readback differs')
    return gate.sha(data)


def seal(work, proof):
    import cfw_disk_txn as transaction
    record = transaction.staged_record(work)
    transaction.require_staged(work,record['staged'])
    record['undoProvenance'] = {'indexSHA256':proof['undoProvenanceSHA256'],
        'finalProofSHA256':effects.digest(work/'guest-effects-final.json'),
        'operationsSHA256':effects.digest(work/'guest-changes.jsonl')}
    transaction.save_record(work,record)


def verify_publication(work, record):
    if record.get('version') not in (2, 3, 4) or record.get('provenanceMode') != 'required':
        raise ValueError('publication requires a new provenance-qualified transaction; old records permit recovery only')
    anchor = record.get('undoProvenance')
    if anchor is None:
        raise ValueError('required Undo index/final proof has no staged journal binding')
    plan = gate.from_environment()
    if (record.get('vm') != plan.context['vmDirectory'] or work.parent != Path(record['vm'])
            or gate.private_path(plan,work) != work
            or Path(os.environ['VPHONE_GUEST_EVIDENCE']) != work/'guest-changes.jsonl'):
        raise ValueError('Undo publication belongs to another VM or execution evidence directory')
    index_raw = gate.strict_bytes(work/FILENAME)
    proof_raw = gate.strict_bytes(work/'guest-effects-final.json')
    rows_raw = gate.strict_bytes(work/'guest-changes.jsonl')
    proof = json.loads(proof_raw)
    if (anchor != {'indexSHA256':gate.sha(index_raw), 'finalProofSHA256':gate.sha(proof_raw), 'operationsSHA256':gate.sha(rows_raw)}
            or proof['undoProvenanceSHA256'] != gate.sha(index_raw) or proof['operationsSHA256'] != gate.sha(rows_raw)
            or proof['generationID'] != plan.context['generationID'] or proof['planDigest'] != plan.record['planSHA256']
            or proof['desiredSHA256'] != plan.raw_sha256 or proof['stagedImage'] != str(work/'Disk.img')
            or any(proof['stagedIdentity'][k] != record['staged'][k] for k in ('dev','ino'))):
        raise ValueError('Undo publication differs from final proof or journal')
    rebuilt = build(plan,[json.loads(line) for line in rows_raw.splitlines()],proof['outputs'],work/'effect-blobs')
    recheck_sources(plan,[json.loads(line) for line in rows_raw.splitlines()],work/'effect-blobs')
    if gate.canonical(rebuilt) != index_raw: raise ValueError('Undo index differs from recomputed source/effects')
    if gate.strict_bytes(work/FILENAME) != index_raw or gate.strict_bytes(work/'guest-effects-final.json') != proof_raw or gate.strict_bytes(work/'guest-changes.jsonl') != rows_raw:
        raise ValueError('Undo publication evidence changed during verification')
