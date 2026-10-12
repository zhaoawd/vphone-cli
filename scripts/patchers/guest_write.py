"""Exact local guest target ownership and guarded shell filesystem operations."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import tarfile
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
    for directory, volume in [('mnt1', 'system'), ('mnt3', 'hardware'), ('mnt5', 'preboot')]:
        base = root / directory
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
        preferred = {'system:/sbin/launchd':'system-launchd-boot-jetsam_panic_guard_bypass',
                     'system:/usr/libexec/vphoned-api':'system-vphoned-boot-install',
                     'system:/System/Library/LaunchDaemons/vphoned-api.plist':'system-vphoned-boot-install'}
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
    if command not in {'cp','mv','rm','mkdir','chmod','chown','ln','gtar','tar','find'}:
        raise ValueError('unsupported guarded guest command: ' + command)
    args = argv[1:]
    flags = {
        'cp': {'-R', '-r', '-p'}, 'mv': set(), 'rm': {'-rf', '-f', '-r'},
        'mkdir': {'-p'}, 'chmod': {'-R'}, 'chown': {'-R'}, 'ln': {'-sf'},
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
    copy_sources = {}
    cryptex_copies = []
    if command in {'cp','mv'} and len(operands)>=2:
        destination=operands[-1]
        for source in operands[:-1]:
            if logical(destination):
                if logical(destination) in {'system:/System/Cryptexes/OS','system:/System/Cryptexes/App'} and Path(source).is_dir():
                    expected_mount = Path(os.environ['CFW_HOST_MNT']) / target_table()[0]['treeTargets'][logical(destination)]['sourceMount']
                    if Path(source) != expected_mount: raise ValueError('Cryptex source differs from invocation-local image mount')
                    from .cryptex_source import mounted, tree
                    mounted(plan, expected_mount)
                    if any(Path(destination).iterdir()): raise ValueError('Cryptex replacement destination is not empty')
                    cryptex_copies.append((Path(destination),tree(source)))
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
        logical(target) in {'system:/System/Cryptexes/OS','system:/System/Cryptexes/App'})
        for target,source in copy_sources.items()}
    archive_associations = {}
    if command in {'tar','gtar'} and targets:
        flag=next(i for i,a in enumerate(args) if a in ('-xf','-f'))
        archive_path=Path(args[flag+1]);archive_digest=component_effects.digest(archive_path)
        destination=Path(args[args.index('-C')+1])
        with tarfile.open(archive_path) as archive:
            for member in archive:
                name=str(PurePosixPath(member.name))
                if name=='.': continue
                target=destination/name
                source_state={'mode':member.mode,'uid':member.uid,'gid':member.gid}
                if member.isfile():
                    import tempfile
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
                archive_associations[target]={'archiveSHA256':archive_digest,'member':name}
        if component_effects.digest(archive_path)!=archive_digest: raise ValueError('archive changed during source capture')
    observations=[]
    for path in targets:
        if logical(path) in {'system:/System/Cryptexes/OS','system:/System/Cryptexes/App'}:
            from .cryptex_source import mounted
            mounted(plan,Path(os.environ['CFW_HOST_MNT'])/('mnt_sysos' if logical(path).endswith('/OS') else 'mnt_appos'))
        no_link_parents(path)
        target=logical(path)
        declaration=owner(plan,target)
        if path.is_symlink() and command not in {'rm','mv','ln'}:
            raise ValueError('guest operation follows target symlink')
        if path.exists() and path.is_file() and path.stat().st_nlink != 1:
            raise ValueError('hard-linked guest target')
        recursive = target in {'system:/System/Cryptexes/OS','system:/System/Cryptexes/App'}
        observations.append((path,target,declaration,state(path),component_effects.capture_input(path,effect_store,recursive),recursive))
    gate.recheck(plan)
    binaries={'cp':'/bin/cp','mv':'/bin/mv','rm':'/bin/rm','mkdir':'/bin/mkdir','chmod':'/bin/chmod','chown':'/usr/sbin/chown','ln':'/bin/ln','find':'/usr/bin/find','tar':'/usr/bin/tar','gtar':'/opt/homebrew/bin/gtar'}
    result=subprocess.run([binaries[command]]+args,check=False)
    for destination,expected in cryptex_copies:
        from .cryptex_source import tree
        if tree(destination)!=expected: raise ValueError('Cryptex copied member readback differs')
    for path,target,declaration,before,effect_input,recursive in observations:
        if path in source_states:
            effect=component_effects.capture_copy(source_states[path],path,effect_store,before=effect_input,recursive=recursive)
            if path in copy_sources: effect['sourcePath']=str(copy_sources[path])
            if path in archive_associations: effect['sourceArchive']=archive_associations[path]
        else:
            effect=component_effects.capture_change(effect_input,path,effect_store,recursive)
        effect['command']=command
        gate.append_evidence(plan,declaration,target,path,before,state(path),effect=effect)
    if result.returncode: raise SystemExit(result.returncode)
