"""Frozen desired-plan gate for real CFW entrypoints (helpers remain importable).

The Swift verifier reopens the current desired record, generation and catalog.
A JSON document alone is never an execution capability. Target rules are exact
catalog-frozen literals; no declaration-ID prefix grants ownership.
"""
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

TARGET = '8a75092013eda87a4e30ed029b72028cb9279ac4'
DIGEST = re.compile(r'[0-9a-f]{64}\Z')
GROUPS = ('selected', 'excludedByVersion', 'excludedByOptIn', 'excludedByVariant', 'guestUncovered', 'notImplemented')


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()


def sha(data):
    return data.sha256 if isinstance(data, FileSnapshot) else hashlib.sha256(data).hexdigest()


def strict_bytes(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise ValueError('plan input is not a regular file')
        with os.fdopen(os.dup(fd), 'rb') as stream:
            data = stream.read()
        after, named = os.fstat(fd), os.lstat(path)
        keys = ('st_dev', 'st_ino', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
        if any(getattr(before, key) != getattr(after, key) or getattr(before, key) != getattr(named, key) for key in keys):
            raise ValueError('plan input changed during read')
        return data
    finally:
        os.close(fd)


@dataclass(frozen=True)
class FrozenPlan:
    path: Path
    raw_sha256: str
    context_json: bytes
    record_json: bytes

    @property
    def context(self):
        return json.loads(self.context_json)

    @property
    def record(self):
        return json.loads(self.record_json)


def load_plan(path, expected_sha256, context) -> FrozenPlan:
    if not isinstance(expected_sha256, str) or not DIGEST.fullmatch(expected_sha256):
        raise ValueError('missing or invalid expected raw plan SHA-256')
    if not isinstance(context, dict) or context.get('schemaVersion') != 1:
        raise ValueError('missing or unknown frozen context schema')
    required = {'schemaVersion', 'vmDirectory', 'identity', 'generationID', 'catalogSHA256',
                'planSHA256', 'upstreamTarget', 'variant', 'verifierPath', 'verifierSHA256',
                'guestEnvironment', 'spoofBuild', 'disableLaunchdHook'}
    if context.get('variant') == 'less': required.add('filesystemTransaction')
    if set(context) != required:
        raise ValueError('missing or unknown frozen context fields')
    if context['variant'] not in ('regular', 'dev', 'jb', 'exp', 'less') or context['guestEnvironment'] not in ('classic', 'v2'):
        raise ValueError('unknown frozen mode or guest profile')
    if context['guestEnvironment'] == 'v2' and context['variant'] != 'regular':
        raise ValueError('v2 requires the regular variant')
    if context['disableLaunchdHook'] not in ('0', '1') or not isinstance(context['spoofBuild'], str):
        raise ValueError('invalid frozen guest options')
    for key in ('generationID', 'catalogSHA256', 'planSHA256', 'verifierSHA256'):
        if not isinstance(context[key], str) or not DIGEST.fullmatch(context[key]):
            raise ValueError('invalid frozen context digest: ' + key)
    path = Path(path)
    vm = Path(context['vmDirectory'])
    if not vm.is_absolute() or vm.is_symlink() or path != vm / '.firmware-desired-plan.json':
        raise ValueError('plan path differs from bound VM')
    if (vm / '.firmware-desired-pending.json').exists():
        raise ValueError('desired plan publication uncertain')
    raw = strict_bytes(path)
    if sha(raw) != expected_sha256:
        raise ValueError('frozen plan raw digest changed')
    record = json.loads(raw)
    if set(record) != {'schemaVersion', 'upstreamTarget', 'catalogSHA256', 'planSHA256', 'generationID', 'identity', 'plan'} or record['schemaVersion'] != 1:
        raise ValueError('missing or unknown desired plan schema/fields')
    if canonical(record) != raw or record['upstreamTarget'] != TARGET:
        raise ValueError('desired plan encoding/target mismatch')
    for key in ('upstreamTarget', 'generationID', 'catalogSHA256', 'planSHA256', 'identity'):
        if record[key] != context[key]:
            raise ValueError('frozen context mismatch: ' + key)
    plan = record['plan']
    if plan.get('variant') != context['variant'] or plan.get('gates', {}).get('variant') != context['variant']:
        raise ValueError('guest mode differs from frozen plan')
    profile = plan.get('gates', {}).get('guestEnvironmentV2')
    if type(profile) is not bool or profile != (context['guestEnvironment'] == 'v2'):
        raise ValueError('guest profile differs from frozen gate (legacy nil cannot authorize writes)')
    if sha(canonical(plan)) != record['planSHA256']:
        raise ValueError('semantic plan digest mismatch')
    ids = []
    for group in GROUPS:
        if not isinstance(plan.get(group), list):
            raise ValueError('missing frozen classification: ' + group)
        for entry in plan[group]:
            if entry.get('disposition') != group or not isinstance(entry.get('id'), str):
                raise ValueError('invalid frozen declaration')
            ids.append(entry['id'])
    if len(ids) != len(set(ids)):
        raise ValueError('repeated frozen declaration')
    verifier = Path(context['verifierPath'])
    if not verifier.is_absolute() or sha(strict_bytes(verifier)) != context['verifierSHA256']:
        raise ValueError('Swift plan verifier changed or missing')
    result = subprocess.run([str(verifier), 'cfw', 'verify-plan', str(vm), '--expected-sha256', expected_sha256],
                            capture_output=True, check=False)
    if result.returncode:
        raise ValueError('current Swift plan validation refused: ' + result.stderr.decode(errors='replace').strip())
    verified = json.loads(result.stdout)
    if verified != {'schemaVersion': 1, 'state': 'ready', 'rawSHA256': expected_sha256, 'record': record}:
        raise ValueError('Swift verified export differs from frozen input')
    if strict_bytes(path) != raw:
        raise ValueError('frozen plan changed during current validation')
    return FrozenPlan(path, expected_sha256, canonical(context), raw)


def from_environment():
    try:
        plan = load_plan(os.environ['VPHONE_FROZEN_PLAN'], os.environ['VPHONE_FROZEN_PLAN_SHA256'],
                         json.loads(os.environ['VPHONE_FROZEN_CONTEXT']))
        verify_expected_binding(plan.path.parent)
        require_supported_implementations(plan)
        return plan
    except (KeyError, OSError, json.JSONDecodeError) as error:
        raise ValueError('missing or invalid frozen plan/context: ' + str(error)) from error


def require_supported_implementations(plan, *, command=None):
    """A declaration ID alone does not prove the target's implementation.

    The isolated IOMFB algorithm implements the conditional dispatcher, but
    existing effect blobs are not authenticated first originals or a committed
    Undo log. Algorithm availability cannot authorize production migration.
    Refuse the complete execution before any staging/evidence side effects.
    guestUncovered includes this ID even on older OS versions; the verified
    iosBaseIs27 gate determines whether installation will execute it. An
    explicit command cannot bypass missing migration/publication qualification.
    """
    enabled = {entry['id'] for group in ('selected', 'guestUncovered')
               for entry in plan.record['plan'][group]}
    ios27 = plan.record['plan']['gates'].get('iosBaseIs27')
    if (command == 'patch-iomfb-force-kern'
            or ('dyld-boot-iomfb_force_kern' in enabled and ios27 is not False)):
        raise ValueError(
            'dyld-boot-iomfb_force_kern: target implementation unavailable for production; '
            'the conditional algorithm for ' + TARGET + ' has no qualified migration/publication chain. Trusted original/Undo '
            'provenance and transactional migration are not implemented; '
            'existing patch IDs, current bytes, or effect blobs cannot authorize migration')


def recheck(plan):
    verify_expected_binding(plan.path.parent)
    if sha(strict_bytes(plan.path)) != plan.raw_sha256:
        raise ValueError('frozen plan changed before write')
    if (plan.path.parent / '.firmware-desired-pending.json').exists():
        raise ValueError('desired plan publication uncertain')


def verify_expected_binding(vm):
    digest = os.environ.get('VPHONE_EXPECTED_BINDING_SHA256')
    version = os.environ.get('VPHONE_EXPECTED_CORE_BUNDLE')
    if digest is None and version is None:
        return
    if not isinstance(digest, str) or not DIGEST.fullmatch(digest) or not version:
        raise ValueError('incomplete expected Core Bundle binding')
    raw = strict_bytes(Path(vm) / 'launchpad.json')
    record = json.loads(raw)
    if sha(raw) != digest or not isinstance(record, dict) or record.get('bundle') != version:
        raise ValueError('Core Bundle binding changed before environment write')


def private_path(plan, path):
    """Validate invocation-local staging without granting guest ownership."""
    vm = Path(plan.context['vmDirectory'])
    path = Path(os.path.abspath(path))
    if path == vm:
        raise ValueError('private staging outside bound VM')
    if vm not in path.parents:
        # External mount roots are explicit journal members. Disk staging,
        # evidence and publication remain inside the VM on its own volume.
        from cfw_disk_txn import require_mount_root, Refused
        root = Path(os.environ.get('CFW_HOST_MNT', ''))
        sink = Path(os.environ.get('VPHONE_GUEST_EVIDENCE', ''))
        try:
            require_mount_root(vm, sink.parent, root)
            if path != root and root not in path.parents:
                raise ValueError('private staging outside bound mount root')
            current = path
            while current != root:
                if current.is_symlink(): raise ValueError('linked private staging path')
                current = current.parent
            return path
        except (Refused, OSError) as error:
            raise ValueError(str(error)) from error
    relative = path.relative_to(vm)
    first = relative.parts[0]
    if first not in {'.cfw_temp', '.iosbinpack_tmp', '.vphoned.signed', 'cfw_input', 'cfw_jb_input'} and not first.startswith(('.cfw_mount.', '.cfw_disk.')):
        raise ValueError('unknown private staging target: ' + str(path))
    current = path
    while current != vm:
        if current.is_symlink(): raise ValueError('linked private staging path')
        current = current.parent
    return path


def require_write_context(plan):
    """Real writers must inherit the VM lock and a private evidence sink."""
    require_supported_implementations(plan)
    from vm_lock import check_inherited
    vm = Path(plan.context['vmDirectory'])
    verify_expected_binding(vm)
    if plan.context['variant'] == 'less':
        import fcntl
        transaction = Path(plan.context['filesystemTransaction'])
        if transaction != vm / '.firmware-transaction' or transaction.is_symlink():
            raise ValueError('less filesystem transaction differs from bound VM')
        fd = int(os.environ['VPHONE_FIRMWARE_WORKER_FD'])
        actual, expected = os.fstat(fd), transaction.stat()
        if (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino):
            raise ValueError('less filesystem worker belongs to another transaction')
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        journal = json.loads(strict_bytes(transaction / 'journal.json'))
        if journal.get('plan') != plan.record['plan'] or journal.get('phase') != 'building' or journal.get('options', {}).get('desiredSHA256') != plan.raw_sha256 or journal['options'].get('generationID') != plan.context['generationID']:
            raise ValueError('less filesystem worker is not bound to current plan')
        if Path(os.environ['VPHONE_GUEST_EVIDENCE']) != transaction / 'guest-changes.jsonl':
            raise ValueError('less filesystem evidence outside transaction')
        destination = transaction / 'guest-changes.jsonl'
        fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
        os.close(fd)
        recheck(plan)
        return
    check_inherited(vm)
    root = private_path(plan, os.environ['CFW_HOST_MNT'])
    if not root.name.startswith('.cfw_mount.') or not root.is_dir():
        raise ValueError('guest mount root differs from bound invocation')
    destination = private_path(plan, os.environ['VPHONE_GUEST_EVIDENCE'])
    if destination.parent.parent != vm or not destination.parent.name.startswith('.cfw_disk.') or destination.name != 'guest-changes.jsonl':
        raise ValueError('evidence path differs from bound transaction')
    if destination.exists() and (not destination.is_file() or destination.stat().st_nlink != 1):
        raise ValueError('evidence sink is not a private regular file')
    # Open before the first target mutation; failure must not leave an unrecorded write.
    destination.parent.mkdir(mode=0o700, exist_ok=True)
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
    os.close(fd)
    recheck(plan)


def authorize(plan, declaration_id, target) -> None:
    recheck(plan)
    group = 'selected' if plan.context['variant'] == 'less' else 'guestUncovered'
    entries = [entry for entry in plan.record['plan'][group] if entry['id'] == declaration_id]
    if len(entries) != 1:
        raise ValueError('unknown or disabled guest declaration: ' + declaration_id)
    rules = entries[0].get('recordRules')
    from .guest_write import target_table, normalized
    table, digest = target_table()
    if group == 'selected':
        rule = {'literal':'filesystem.cryptex.merge','hexadecimalOffsetSuffix':False,'guestTargetRulesSHA256':digest}
        if declaration_id != 'filesystem-less-cryptex_merge' or rule not in (rules or []) or target not in table['lessCommands'].values():
            raise ValueError('unknown less filesystem suboperation target')
        return
    rule = {'literal': 'guest-target-map-v1:' + digest + ':' + declaration_id, 'hexadecimalOffsetSuffix': False}
    if not isinstance(rules, list) or rule not in rules or declaration_id not in table['owners'].get(normalized(target), []):
        raise ValueError('undeclared guest target: ' + str(target))


def record_change(plan, declaration_id, target, before, after) -> dict:
    authorize(plan, declaration_id, target)
    if not isinstance(before, (bytes, FileSnapshot)) or not isinstance(after, (bytes, FileSnapshot)):
        raise ValueError('change evidence requires actual snapshot bytes')
    return {'schemaVersion': 1, 'planDigest': plan.record['planSHA256'],
            'desiredSHA256': plan.raw_sha256, 'generationID': plan.record['generationID'],
            'declarationID': declaration_id, 'target': target,
            'beforeSHA256': sha(before), 'afterSHA256': sha(after)}


@dataclass(frozen=True)
class FileSnapshot:
    sha256: str
    metadata: dict


def snapshot(path, *, readonly_source=False):
    """Hash actual file/link metadata and bytes; directories enumerate exact children."""
    path = Path(path)
    try:
        info = path.lstat()
    except FileNotFoundError:
        return canonical({'state': 'missing'})
    metadata = {'mode': stat.S_IMODE(info.st_mode), 'uid': info.st_uid, 'gid': info.st_gid}
    if stat.S_ISLNK(info.st_mode):
        return canonical(dict(metadata, kind='symlink', link=os.readlink(path)))
    if stat.S_ISREG(info.st_mode):
        from .component_effects import regular
        with regular(path,readonly_source=readonly_source) as stream:
            before=os.fstat(stream.fileno());digest=hashlib.sha256()
            metadata={'mode':stat.S_IMODE(before.st_mode),'uid':before.st_uid,'gid':before.st_gid}
            while data := stream.read(1 << 20): digest.update(data)
            return FileSnapshot(digest.hexdigest(), metadata)
    if stat.S_ISDIR(info.st_mode):
        children = {}
        for item in sorted(path.iterdir()):
            child = snapshot(item,readonly_source=readonly_source)
            children[item.name] = dict(child.metadata, kind='file', sha256=child.sha256) if isinstance(child, FileSnapshot) else json.loads(child)
        return canonical(dict(metadata, kind='directory', children=children))
    raise ValueError('unsupported guest target file type: ' + str(path))


def append_evidence(plan, declaration, target, path, before, after, source_image=None, effect=None, source_binding=None):
    record = record_change(plan, declaration, target, before, after)
    record['path'] = str(Path(path).absolute())
    if effect is not None: record['effect'] = effect
    if isinstance(before, FileSnapshot): record['beforeMetadata'] = before.metadata
    if isinstance(after, FileSnapshot): record['afterMetadata'] = after.metadata
    from .guest_write import logical
    record['phase'] = 'filesystem-staging' if plan.context['variant'] == 'less' else 'guest' if logical(path) is not None or target.startswith('dsc:') else 'staging'
    if source_image is not None:
        record['sourceImage'] = str(source_image)
        record['sourceImageProof'] = source_binding
    destination = Path(os.environ['VPHONE_GUEST_EVIDENCE'])
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
    try:
        data = memoryview(canonical(record) + b'\n')
        while data:
            count = os.write(fd, data)
            if count <= 0: raise OSError('short evidence write')
            data = data[count:]
        os.fsync(fd)
    finally:
        os.close(fd)


def validate_entry(plan, entry):
    variant = plan.context['variant']
    paths = {'cfw_install.sh': {'regular', 'jb', 'exp'}, 'cfw_install_dev.sh': {'dev'},
             'cfw_install_jb.sh': {'jb'}, 'cfw_install_exp.sh': {'exp'}, 'cfw_install_host.sh': {'regular', 'dev', 'jb', 'exp'}}
    if entry not in paths or variant not in paths[entry]:
        raise ValueError('script path differs from frozen guest mode')
    if os.environ.get('VPHONE_CFW_VARIANT') != variant:
        raise ValueError('guest mode cannot be overridden')
    if os.environ.get('VPHONE_GUEST_ENVIRONMENT', 'classic') != plan.context['guestEnvironment']:
        raise ValueError('guest environment cannot be overridden')
    if os.environ.get('SPOOF_BUILD', '') != plan.context['spoofBuild'] or os.environ.get('DISABLE_LAUNCHD_HOOK', '0') != plan.context['disableLaunchdHook']:
        raise ValueError('guest options differ from bound execution context')
    for name in ('VPHONE_PATCHSET', 'VPHONE_PATCHSETS', 'PATCHSET', 'PATCHSETS'):
        if os.environ.get(name):
            raise ValueError('external executable patchsets disabled')
    frida = os.environ.get('VPHONE_FRIDA', '0')
    if frida not in ('0', '1') or (frida == '1') != plan.record['plan']['gates']['enableFrida']:
        raise ValueError('guest Frida option differs from frozen plan')


def main():
    plan = from_environment()
    if len(sys.argv) == 2 and sys.argv[1] == 'verify-final':
        from .final_guest import run
        result=run(plan)
        destination=Path(os.environ['VPHONE_GUEST_EVIDENCE']).parent/'guest-effects-final.json'
        from cfw_guest_evidence import write_final
        write_final(destination, canonical(result))
        from .undo_provenance import seal
        seal(destination.parent,result)
        return
    if len(sys.argv) == 3 and sys.argv[1] == 'entry':
        validate_entry(plan, Path(sys.argv[2]).name)
        return
    if len(sys.argv) == 5 and sys.argv[1] == 'cache':
        from .cryptex_source import prepare
        prepare(plan, *sys.argv[2:])
        return
    if len(sys.argv) == 4 and sys.argv[1] == 'mount-cryptex':
        from .cryptex_source import attach
        attach(plan, *sys.argv[2:])
        return
    if len(sys.argv) == 3 and sys.argv[1] == 'cache-detached':
        from .cryptex_source import refresh
        refresh(plan, sys.argv[2])
        return
    if len(sys.argv) >= 4 and sys.argv[1] == 'sign':
        from .guest_write import sign
        sign(plan, sys.argv[2:])
        return
    if len(sys.argv) >= 3 and sys.argv[1] == 'write':
        from .guest_write import run
        run(plan, sys.argv[2:])
        return
    raise ValueError('unknown plan gate operation')


if __name__ == '__main__':
    if not __package__:
        sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
        __package__ = 'patchers'
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        print('[-] frozen plan: ' + str(error), file=sys.stderr)
        sys.exit(1)
