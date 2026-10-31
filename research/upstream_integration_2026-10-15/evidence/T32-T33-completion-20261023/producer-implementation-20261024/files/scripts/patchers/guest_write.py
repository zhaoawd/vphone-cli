"""Exact local guest target ownership and guarded shell filesystem operations."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import tarfile
import contextlib
import tempfile
import uuid
from . import plan_gate as gate


_cached_table = None

def target_table():
    global _cached_table
    path = Path(__file__).with_name('guest-targets.json')
    info=path.lstat()
    key=(info.st_dev,info.st_ino,info.st_size,info.st_mtime_ns,info.st_ctime_ns)
    if _cached_table is not None and _cached_table[0]==key: return _cached_table[1]
    raw = gate.strict_bytes(Path(__file__).with_name('guest-targets.json'))
    value = json.loads(raw)
    if value.get('schemaVersion') != 1:
        raise ValueError('unknown guest target rule schema')
    result=(value, hashlib.sha256(raw).hexdigest())
    _cached_table=(key,result)
    return result


def normalized(target):
    if not isinstance(target, str) or '..' in PurePosixPath(target.split(':', 1)[-1]).parts:
        raise ValueError('invalid guest target')
    slots=target_table()[0]['slots']
    target = re.sub(slots['preboot'], 'preboot:/<boot-hash>/', target)
    if re.fullmatch(slots['hardware'], target):
        return 'hardware:/<gigalocker>.gl'
    if re.fullmatch(slots['dsc'], target):
        return 'dsc:/<chunk>'
    return target


def logical(path):
    path = Path(os.path.abspath(path))
    root = Path(os.environ['CFW_HOST_MNT'])
    for base_root in (root,root.resolve()):
        for directory, volume in [('mnt1', 'system'), ('mnt3', 'hardware'), ('mnt5', 'preboot')]:
            base = base_root / directory
            if path == base or base in path.parents:
                return volume + ':/' + str(path.relative_to(base)) if path != base else volume + ':/'
    return None


def no_link_parents(path):
    root = Path(os.environ['CFW_HOST_MNT'])
    current = Path(os.path.abspath(path)).parent
    while current != root and root in current.parents:
        if current.is_symlink():
            raise ValueError('linked guest target parent: ' + str(current))
        current = current.parent


def walk(path):
    path = Path(path)
    yield path
    if path.is_dir() and not path.is_symlink():
        for child in sorted(path.iterdir()):
            yield from walk(child)


def owner(plan, target, hint=None):
    table, _ = target_table()
    allowed = table['owners'].get(normalized(target), [])
    active = {entry['id'] for entry in plan.record['plan']['guestUncovered']}
    allowed = [item for item in allowed if item in active]
    if hint:
        if hint not in allowed: raise ValueError('wrong guest declaration for target: ' + target)
        selected = hint
    else:
        # Shared launchd input/output has an explicit writer relationship. The
        # injected command itself separately records the hook/environment effect.
        preferred = {'system:/System/Library/xpc/launchd.plist':'system-launchdaemons-boot-install',
                     'system:/System/Library/xpc/launchd.plist.bak':'system-launchdaemons-boot-install',
                     'system:/sbin/launchd':'system-launchd-boot-jetsam_panic_guard_bypass',
                     'system:/usr/libexec/vphoned-api':'system-vphoned-boot-install',
                     'system:/System/Library/LaunchDaemons/vphoned-api.plist':'system-vphoned-boot-install'}
        if target in ('system:/System/Library/xpc/launchd.plist','system:/System/Library/xpc/launchd.plist.bak') and preferred[target] not in allowed:
            raise ValueError('exact shell boot plist writer is not selected')
        selected = preferred.get(target) if preferred.get(target) in allowed else None
        if selected is None:
            if len(allowed) != 1: raise ValueError('unknown or ambiguous guest target: ' + target)
            selected = allowed[0]
    gate.authorize(plan, selected, target)
    return selected


def state(path):
    path = Path(path)
    if logical(path) in {'system:/System/Cryptexes/OS','system:/System/Cryptexes/App'}:
        return gate.snapshot(path)
    if path.is_dir() and not path.is_symlink():
        info = path.lstat()
        return gate.canonical({'kind':'directory','mode':stat.S_IMODE(info.st_mode),'uid':info.st_uid,'gid':info.st_gid})
    return gate.snapshot(path)


def archive_targets(path, destination):
    """Reject any new/changed archive member name/type/link before extraction."""
    table, _ = target_table()
    name = Path(path).name
    expected = table['archives'].get(name)
    if expected is None: raise ValueError('undeclared guest archive: ' + name)
    targets, actual = [], {}
    with tarfile.open(path) as archive:
        for member in archive:
            member_name = str(PurePosixPath(member.name))
            if member_name == '.': continue
            if member_name.startswith('/') or '..' in PurePosixPath(member_name).parts:
                raise ValueError('archive member escapes guest target')
            if member_name in actual: raise ValueError('duplicate guest archive member')
            row = {'type':member.type.decode(),'link':member.linkname}
            if row != expected.get(member_name):
                raise ValueError('undeclared or changed guest archive member: ' + member_name)
            if not (member.isfile() or member.isdir() or member.issym()):
                raise ValueError('unsupported guest archive member type')
            actual[member_name] = row
            targets.append(Path(destination) / member_name)
    if actual != expected:
        raise ValueError('guest archive member table incomplete')
    # Absolute guest symlinks may be shipped as inert symlinks, but an archive
    # may never write through one (including a link introduced by this archive).
    links = {name for name,row in actual.items() if row['type'] in ('1','2')}
    for name in actual:
        if any(str(parent) in links for parent in PurePosixPath(name).parents):
            raise ValueError('guest archive writes through a link')
    return targets


def copy_targets(source, destination):
    contents = str(source).endswith('/.')
    source, destination = Path(source), Path(destination)
    if source.is_dir() and not source.is_symlink():
        # cp source/. copies children; cp -R source copies its basename.
        base = destination if contents or not destination.exists() else destination/source.name
        return [base / item.relative_to(source) for item in walk(source)]
    return [destination/source.name if destination.is_dir() else destination]


def run(plan, argv):
    gate.require_write_context(plan)
    command = Path(argv[0]).name
    if plan.context['variant']=='less':
        return less_metadata(plan,argv)
    if command not in {'cp','mv','rm','mkdir','chmod','chown','ln','gtar','tar','find'}:
        raise ValueError('unsupported guarded guest command: ' + command)
    args = argv[1:]
    flags = {
        'cp': {'-R', '-r', '-p'}, 'mv': set(), 'rm': {'-rf', '-f', '-r'},
        'mkdir': {'-p'}, 'chmod': {'-R'}, 'chown': {'-R'}, 'ln': {'-sf', '-sfn'},
        'tar': {'-xf', '-f', '-C', '--preserve-permissions', '--no-overwrite-dir', '--warning=no-unknown-keyword'},
        'gtar': {'-xf', '-f', '-C', '--preserve-permissions', '--no-overwrite-dir', '--warning=no-unknown-keyword'},
        'find': {'-name', '-delete'},
    }
    if any(arg.startswith('-') and arg not in flags[command] for arg in args):
        raise ValueError('unsupported guarded guest command option')
    # Shell options used by the shipped installers take no operand except
    # chmod/chown's mode/owner, ln's source, and tar's -f/-C.
    operands = [a for a in args if not a.startswith('-')]
    outputs = operands[-1:] if command in {'cp','mv','ln'} else operands[1:] if command in {'chmod','chown'} else operands if command in {'rm','mkdir'} else []
    if command in {'tar','gtar'}:
        if '-C' not in args: raise ValueError('tar requires explicit private or guest destination')
        outputs = [args[args.index('-C')+1]]
    if command == 'find':
        if '-delete' not in args or '-name' not in args or args[args.index('-name')+1] != '._*':
            raise ValueError('unsupported guest find operation')
        outputs = operands[:1]
    for output in outputs:
        if not logical(output): gate.private_path(plan, output)
    if command == 'mv':
        for source in operands[:-1]:
            if not logical(source): gate.private_path(plan, source)
    targets = []
    staged_targets={}
    copy_sources = {}
    cryptex_copies = []
    source_images = {}
    source_bindings = {}
    if command in {'cp','mv'} and len(operands)>=2:
        destination=operands[-1]
        for source in operands[:-1]:
            if logical(destination):
                if logical(destination) in {'system:/System/Cryptexes/OS','system:/System/Cryptexes/App'} and Path(source).is_dir():
                    expected_mount = Path(os.environ['CFW_HOST_MNT']) / target_table()[0]['treeTargets'][logical(destination)]['sourceMount']
                    if Path(source) != expected_mount: raise ValueError('Cryptex source differs from invocation-local image mount')
                    from .cryptex_source import mounted, tree, proof
                    source_images[Path(destination)]=mounted(plan, expected_mount)
                    source_bindings[Path(destination)]=proof(plan,source_images[Path(destination)])
                    if any(Path(destination).iterdir()): raise ValueError('Cryptex replacement destination is not empty')
                    cryptex_copies.append((Path(destination),tree(source,readonly_source=True)))
                    # Inspect the complete source member table before its whole-image
                    # copy. Parent links are inert data, never followed by cp -R.
                    for member in walk(source):
                        if not (member.is_file() or member.is_dir() or member.is_symlink()): raise ValueError('unsupported Cryptex member')
                    targets.append(Path(destination))
                    copy_sources[Path(destination)] = Path(source)
                else:
                    copied = copy_targets(source,destination)
                    targets += copied
                    source_path = Path(source)
                    source_items = list(walk(source_path)) if source_path.is_dir() and not source_path.is_symlink() else [source_path]
                    copy_sources.update(zip(copied,source_items))
            elif logical(source) and command=='cp':
                copied=copy_targets(source,destination)
                originals=list(walk(source)) if Path(source).is_dir() and not Path(source).is_symlink() else [Path(source)]
                targets+=copied
                copy_sources.update(zip(copied,originals))
                staged_targets.update({target:logical(original) for target,original in zip(copied,originals)})
            if command=='mv' and logical(source): targets += list(walk(source))
    elif command in {'chmod','chown'}:
        for path in operands[1:]:
            if logical(path): targets += list(walk(path)) if '-R' in args else [Path(path)]
    elif command in {'rm','mkdir'}:
        for path in operands:
            if logical(path): targets += list(walk(path)) if command=='rm' and logical(path) not in {'system:/System/Cryptexes/OS','system:/System/Cryptexes/App'} else [Path(path)]
    elif command=='ln' and len(operands)>=2:
        if logical(operands[-1]): targets=[Path(operands[-1])]
    elif command in {'tar','gtar'}:
        if '-C' not in args: raise ValueError('guest tar requires explicit destination')
        destination=args[args.index('-C')+1]
        if logical(destination):
            flag=next((i for i,a in enumerate(args) if a in ('-xf','-f')),None)
            if flag is None: raise ValueError('unsupported guest tar flags')
            targets=archive_targets(args[flag+1],destination)
    elif command=='find':
        if '-delete' in args and operands and logical(operands[0]):
            targets=[item for item in walk(operands[0]) if item.name.startswith('._')]
    # A private staging command remains a normal process operation. The caller
    # already validated its frozen input; it grants no guest target authority.
    targets=list(dict.fromkeys(targets))
    if command == 'mkdir' and '-p' in args:
        targets=[p for p in targets if logical(p) not in {'system:/','preboot:/','hardware:/'}]
    from . import component_effects
    effect_store = Path(os.environ['VPHONE_GUEST_EVIDENCE']).parent / 'effect-blobs'
    effect_store.mkdir(mode=0o700,exist_ok=True)
    if effect_store.is_symlink(): raise ValueError('linked effect store')
    source_states = {target: component_effects.capture_input(source,effect_store,
        logical(target) in {'system:/System/Cryptexes/OS','system:/System/Cryptexes/App'},
        readonly_source=target in source_images)
        for target,source in copy_sources.items()}
    archive_associations = {}
    if command in {'tar','gtar'} and targets:
        flag=next(i for i,a in enumerate(args) if a in ('-xf','-f'))
        archive_path=Path(args[flag+1]);archive_digest=component_effects.persist(archive_path,effect_store)
        destination=Path(args[args.index('-C')+1])
        with tarfile.open(archive_path) as archive:
            for member in archive:
                name=str(PurePosixPath(member.name))
                if name=='.': continue
                target=destination/name
                source_state={'mode':member.mode,'uid':member.uid,'gid':member.gid}
                if member.isfile():
                    fd,temporary=tempfile.mkstemp(prefix='.archive-member-',dir=effect_store)
                    try:
                        with os.fdopen(fd,'wb') as out,archive.extractfile(member) as source:
                            while block:=source.read(1<<20): out.write(block)
                        key=component_effects.persist(temporary,effect_store)
                    finally: os.unlink(temporary)
                    source_state.update(kind='file',sha256=key)
                elif member.issym(): source_state.update(kind='symlink',link=member.linkname)
                elif member.isdir(): source_state.update(kind='directory')
                else: raise ValueError('unsupported archive effect member')
                source_states[target]=source_state
                archive_associations[target]={'archiveSHA256':archive_digest,'archivePath':str(archive_path),'archiveTarget':logical(archive_path),'archiveName':archive_path.name,'destination':logical(destination),'member':name}
        if component_effects.digest(archive_path)!=archive_digest: raise ValueError('archive changed during source capture')
    observations=[]
    for path in targets:
        if logical(path) in {'system:/System/Cryptexes/OS','system:/System/Cryptexes/App'}:
            from .cryptex_source import mounted
            mounted(plan,Path(os.environ['CFW_HOST_MNT'])/('mnt_sysos' if logical(path).endswith('/OS') else 'mnt_appos'))
        no_link_parents(path)
        target=logical(path) or staged_targets.get(path)
        declaration=owner(plan,target)
        if command == 'ln' and path.is_dir() and (
                not path.is_symlink() or '-sfn' not in args or operands[-1].endswith('/')):
            raise ValueError('guest link command follows target directory')
        if path.is_symlink() and command not in {'rm','mv','ln'}:
            raise ValueError('guest operation follows target symlink')
        if path.exists() and path.is_file() and path.stat().st_nlink != 1:
            raise ValueError('hard-linked guest target')
        recursive = target in {'system:/System/Cryptexes/OS','system:/System/Cryptexes/App'}
        observations.append((path,target,declaration,state(path),component_effects.capture_input(path,effect_store,recursive),recursive))
    gate.recheck(plan)
    binaries={'cp':'/bin/cp','mv':'/bin/mv','rm':'/bin/rm','mkdir':'/bin/mkdir','chmod':'/bin/chmod','chown':'/usr/sbin/chown','ln':'/bin/ln','find':'/usr/bin/find','tar':'/usr/bin/tar','gtar':'/opt/homebrew/bin/gtar'}
    operation_id=uuid.uuid4().hex
    move_targets={source:logical(target) for target,source in copy_sources.items()} if command=='mv' else {}
    result=subprocess.run([binaries[command]]+args,check=False)
    for destination,expected in cryptex_copies:
        from .cryptex_source import tree
        if tree(destination)!=expected: raise ValueError('Cryptex copied member readback differs')
    for path,target,declaration,before,effect_input,recursive in observations:
        if path in source_states:
            effect=component_effects.capture_copy(source_states[path],path,effect_store,before=effect_input,recursive=recursive)
            if path in copy_sources:
                effect['sourcePath']=str(copy_sources[path])
                effect['sourceTarget']=logical(copy_sources[path])
            if path in archive_associations: effect['sourceArchive']=archive_associations[path]
        else:
            effect=component_effects.capture_change(effect_input,path,effect_store,recursive)
        effect['command']=command
        effect['operationID']=operation_id
        if path in move_targets: effect['transportTarget']=move_targets[path]
        gate.append_evidence(plan,declaration,target,path,before,state(path),source_image=source_images.get(path),effect=effect,source_binding=source_bindings.get(path))
    if result.returncode: raise SystemExit(result.returncode)


def sign(plan, argv, *, execute=None):
    """Observe an explicit signer, after exact source/target authorization."""
    from . import component_effects as effects
    from . import component_signatures as signatures
    gate.require_write_context(plan)
    if len(argv)<3 or Path(argv[0]).name!='ldid': raise ValueError('unsupported signing command')
    source=Path(os.path.abspath(argv[-1]));vm=Path(plan.context['vmDirectory'])
    args=argv[1:-1]
    if not any(a.startswith('-S') for a in args) or any(not (a=='-M' or a.startswith(('-S','-K','-I'))) for a in args):
        raise ValueError('unsupported signing options')
    if plan.context['variant']=='less':
        target=less_target(plan,source)
        rule={'target':target,'declaration':'filesystem-less-cryptex_merge'}
    else:
        rule=target_table()[0]['signing'].get(str(source.relative_to(vm))) if vm in source.parents else None
        if rule is None: rule=v2_signing_rule(plan,source)
        if rule is None: raise ValueError('unknown exact signing source')
        gate.private_path(plan,source)
    is_v2=source.parent in _signing_directories
    target=rule['target']
    if '<boot-hash>' in target:
        boot=os.environ.get('VPHONE_SIGN_BOOT_HASH','')
        if re.fullmatch('[0-9A-Fa-f]{96}',boot) is None: raise ValueError('missing exact signing boot target')
        target=target.replace('<boot-hash>',boot)
    declaration=rule['declaration'];gate.authorize(plan,declaration,target)
    store=Path(os.environ['VPHONE_GUEST_EVIDENCE']).parent/'effect-blobs'
    before=effects.capture_input(source,store);snapshot=gate.snapshot(source)
    ent_paths=[Path(arg[2:]) for arg in args if arg.startswith('-S') and len(arg)>2]
    if len(ent_paths)>1: raise ValueError('ambiguous signing entitlements')
    ent_state=effects.capture_input(ent_paths[0],store) if ent_paths else None
    if ent_paths and effects.plist(ent_paths[0]) is None: raise ValueError('invalid signing entitlements')
    from . import signature_reuse
    signing_inputs=None;reused=None
    if plan.context['variant']!='less':
        try:signing_inputs=signature_reuse.inputs(plan,argv,before)
        except FileNotFoundError:
            if execute is None:raise
        if signing_inputs is not None:
            reused=signature_reuse.candidate(plan,store.parent,declaration,target,signing_inputs)
    gate.recheck(plan)
    if reused is not None:signature_reuse.restore(source,reused[0],before)
    elif execute is None: subprocess.run(argv,check=True)
    else: execute(argv)
    gate.private_path(plan,source) if plan.context['variant']!='less' else less_target(plan,source)
    if is_v2 and v2_signing_rule(plan,source) is None:
        raise ValueError('signing source lost registered work root')
    after=effects.capture_input(source,store)
    signatures.verify_signing(effects.blob(store,before['sha256']),source)
    if ent_paths:
        if effects.state(ent_paths[0])!=ent_state: raise ValueError('signing entitlements changed')
        expected=effects.encode_value(effects.plist(ent_paths[0]))
        if any(effects.encode_value(value)!=expected for value in signatures.entitlements(source)):
            raise ValueError('signer embedded entitlements differ from source')
    proof={'schemaVersion':1,'operation':'sign','before':before,'after':after,
           'projection':{'kind':'signature'},'signerArguments':argv[1:]}
    if signing_inputs is not None:
        if signature_reuse.inputs(plan,argv,before)!=signing_inputs:raise ValueError('Signing configuration changed during production')
        proof['signingInputs']=signing_inputs
    if reused is not None:
        if after['sha256']!=reused[1]['outputSHA256']:raise ValueError('Reused signing output differs')
        proof['signatureReuse']=reused[1]
    if ent_paths: proof['entitlementsSource']={'path':str(ent_paths[0]),'state':ent_state}
    gate.append_evidence(plan,declaration,target,source,snapshot,gate.snapshot(source),effect=proof)


def less_target(plan,path):
    work=Path(plan.context['filesystemTransaction'])/'work'
    path=Path(os.path.abspath(path))
    if work not in path.parents: raise ValueError('less signing source outside transaction work')
    current=path
    while current!=work:
        if current.is_symlink(): raise ValueError('linked less signing source')
        current=current.parent
    targets=[target for target in target_table()[0]['lessCommands'].values()
             if str(path).endswith(target.removeprefix('system:'))]
    if len(targets)!=1: raise ValueError('unknown less signing source')
    gate.authorize(plan,'filesystem-less-cryptex_merge',targets[0])
    return targets[0]


def less_metadata(plan,argv):
    from . import component_effects as effects
    if len(argv)!=3 or Path(argv[0]).name!='chmod' or argv[1]!='0755':
        raise ValueError('unsupported less metadata operation')
    path=Path(argv[-1]);target=less_target(plan,path)
    store=Path(os.environ['VPHONE_GUEST_EVIDENCE']).parent/'effect-blobs'
    before=effects.capture_input(path,store);observed=gate.snapshot(path)
    gate.recheck(plan);subprocess.run(['/bin/chmod',*argv[1:]],check=True)
    proof=effects.capture_change(before,path,store);proof['command']='chmod'
    gate.append_evidence(plan,'filesystem-less-cryptex_merge',target,path,observed,gate.snapshot(path),effect=proof)


_signing_directories={}


def signing_transaction(plan, transaction_id):
    """Recheck this invocation's existing staged disk transaction."""
    import cfw_disk_txn as transaction
    gate.require_write_context(plan)
    work=gate.private_path(plan,Path(os.environ['VPHONE_GUEST_EVIDENCE']).parent)
    raw=gate.strict_bytes(work/'transaction.json');record=json.loads(raw)
    if (not isinstance(transaction_id,str) or not transaction_id or record.get('id')!=transaction_id
            or record.get('version') not in (2,3,4,5) or record.get('provenanceMode')!='required' or record.get('status')!='staged'
            or record.get('vm')!=plan.context['vmDirectory']):
        raise ValueError('signing requires the current staged transaction')
    fd=os.open(Path(plan.context['vmDirectory'])/'Disk.img',os.O_RDONLY|os.O_NOFOLLOW)
    try: transaction.require_original(fd,Path(plan.context['vmDirectory']),record['original'])
    finally: os.close(fd)
    transaction.require_staged(work,record['staged'])
    return work,raw


def private_directory(path,fd,original):
    for info in (os.fstat(fd),path.lstat()):
        if (not stat.S_ISDIR(info.st_mode) or (info.st_dev,info.st_ino)!=(original.st_dev,original.st_ino)
                or info.st_uid!=os.geteuid() or stat.S_IMODE(info.st_mode)!=0o700):
            raise ValueError('signing private directory identity/owner/mode changed')


@contextlib.contextmanager
def signing_directory(plan, *, transaction_id=None):
    """Register a live producer directory below this qualified transaction."""
    if plan.context['variant']!='regular' or plan.context['guestEnvironment']!='v2':
        raise ValueError('private signing directory requires regular/v2')
    parent,record=signing_transaction(plan,transaction_id)
    parent_fd=os.open(parent,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
    try:
        parent_info=os.fstat(parent_fd);private_directory(parent,parent_fd,parent_info)
        with tempfile.TemporaryDirectory(prefix='.vphone-launchd-',dir=parent) as temporary:
            path=Path(temporary);fd=os.open(path,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
            _signing_directories[path]={'fd':fd,'original':os.fstat(fd),'desired':plan.raw_sha256,
                'context':plan.context_json,'parent':parent,'parentFD':parent_fd,'parentInfo':parent_info,
                'transactionID':transaction_id,'transaction':record}
            try:
                if v2_signing_rule(plan,path/'launchd') is None:
                    raise ValueError('producer directory differs from generated signing slot')
                yield path
            finally:
                _signing_directories.pop(path,None);os.close(fd)
    finally: os.close(parent_fd)


def v2_signing_rule(plan,source):
    rule=target_table()[0]['v2Signing']
    if rule.get('root')!='hostTransactionWork': raise ValueError('unknown v2 signing root policy')
    work=Path(os.environ['VPHONE_GUEST_EVIDENCE']).parent
    if work not in source.parents: return None
    relative=str(source.relative_to(work))
    if re.fullmatch(rule['relativePattern'],relative) is None: return None
    if plan.context['variant']!='regular' or plan.context['guestEnvironment']!='v2':
        raise ValueError('signing source differs from v2 context')
    registered=_signing_directories.get(source.parent)
    if registered is None: raise ValueError('signing source has no live producer directory')
    if registered['desired']!=plan.raw_sha256 or registered['context']!=plan.context_json or registered['parent']!=work:
        raise ValueError('signing source differs from registered context/work root')
    gate.private_path(plan,source)
    private_directory(work,registered['parentFD'],registered['parentInfo'])
    private_directory(source.parent,registered['fd'],registered['original'])
    actual,record=signing_transaction(plan,registered['transactionID'])
    if actual!=work or record!=registered['transaction']:
        raise ValueError('signing staged transaction changed')
    return rule


def inject_v2(plan, source, *, execute=None):
    """Observe the exact /vh injection in this registered launchd producer."""
    from . import component_effects as effects
    from .cfw import dylib_command
    source=Path(source)
    rule=v2_signing_rule(plan,source)
    if rule is None: raise ValueError('v2 injection has no registered source')
    gate.authorize(plan,rule['declaration'],rule['target'])
    store=Path(os.environ['VPHONE_GUEST_EVIDENCE']).parent/'effect-blobs'
    before=effects.capture_input(source,store);snapshot=gate.snapshot(source)
    try:
        argv=dylib_command(source,'/vh')
        if execute is None: subprocess.run(argv,check=True)
        else: execute(argv)
        from .component_signatures import reserve_signature_command
        reserve_signature_command(source)
    finally:
        if v2_signing_rule(plan,source) is None:
            raise ValueError('v2 injection source lost registered work root')
        proof=effects.capture_change(before,source,store)
        gate.append_evidence(plan,rule['declaration'],rule['target'],source,snapshot,gate.snapshot(source),effect=proof)
