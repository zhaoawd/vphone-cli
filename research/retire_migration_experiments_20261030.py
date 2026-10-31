"""Retire the four T32/T33 directories authorized in the current chat.

Archive records, source snapshots, ROMs and top-level candidate packages before
deletion. This retires the old runtime/replay state; it does not accept tests.
"""
import datetime
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[1]
NAMES = ('.build/t32q-20261024', '.build/t32q-20261024-binding-backup',
         '.build/t33t-20261025', '.build/t32-t33-completion-20261023')
TARGETS = tuple(ROOT / name for name in NAMES)
OUT = ROOT / 'research/evidence/migration-experiments-retirement-20261030'
TEXT = {'.json', '.jsonl', '.plist', '.log', '.txt', '.shsh', '.xml', '.md',
        '.py', '.swift', '.sh', '.zsh', '.c', '.h', '.m', '.mm', '.inc',
        '.yaml', '.yml', '.toml', '.csv', '.tsv', '.lock', '.entitlements',
        '.xcconfig', '.pbxproj', '.resolved', '.p12', '.pem', '.cer'}


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def save(name, value):
    path = OUT / name
    with path.open('w') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    path.chmod(0o600)


def meta(path):
    s = path.lstat()
    result = {k: getattr(s, 'st_' + k) for k in
              ('dev', 'ino', 'mode', 'uid', 'gid', 'size', 'mtime_ns', 'blocks', 'nlink')}
    result['flags'] = s.st_flags
    if stat.S_ISLNK(s.st_mode):
        result['link'] = os.readlink(path)
    return result


def inventory():
    rows = {}
    for target in TARGETS:
        if target.resolve(strict=True) != target or not target.is_dir():
            raise ValueError('Unexpected root: ' + str(target))
        rows[str(target.relative_to(ROOT))] = meta(target)
        for parent, dirs, files in os.walk(target, followlinks=False,
                                         onerror=lambda error: (_ for _ in ()).throw(error)):
            if os.path.ismount(parent):
                raise ValueError('Mounted directory: ' + parent)
            for name in dirs + files:
                p = Path(parent) / name
                info = meta(p)
                if not any(test(info['mode']) for test in (stat.S_ISREG, stat.S_ISDIR, stat.S_ISLNK)):
                    raise ValueError('Special file: ' + str(p))
                if info['dev'] != target.stat().st_dev:
                    raise ValueError('Different filesystem: ' + str(p))
                if info['flags'] & sum(getattr(stat, key, 0) for key in
                                      ('UF_IMMUTABLE', 'UF_APPEND', 'SF_IMMUTABLE', 'SF_APPEND', 'SF_NOUNLINK')):
                    raise ValueError('Protected flags: ' + str(p))
                rows[str(p.relative_to(ROOT))] = info
    return rows


def preserve(name, info):
    if not stat.S_ISREG(info['mode']):
        return False
    p = Path(name)
    if p.name.startswith('AVP') and p.suffix == '.bin':
        return True
    if p.parent == Path(NAMES[3]) and p.suffix == '.tar':
        return True
    if any(part in {'effect-blobs', 'blobs'}
           or part.endswith('_Restore') for part in p.parts):
        return False
    return p.suffix.lower() in TEXT or p.name in {'Makefile', 'Package.swift', '.vphoned.signed'}


def command(args):
    return subprocess.check_output(args, cwd=ROOT, timeout=60)


def git(*args):
    return command(['git', '-c', 'safe.directory=' + str(ROOT), *args])


def protected():
    names = set(os.fsdecode(p) for p in git('diff', '--name-only', '-z', 'HEAD').split(b'\0') if p)
    names.update(os.fsdecode(p) for p in git('ls-files', '--others', '--exclude-standard', '-z',
                                           '--', 'sources', 'scripts', 'tests').split(b'\0') if p)
    names.discard('TODO.md')
    names.discard('TASKS.md')
    result = {}
    for name in sorted(names):
        p = ROOT / name
        if p.is_file() and not p.is_symlink():
            result[name] = dict(meta(p), sha256=sha(p))
    for dirname in ('vm-new', 'vm-2607', 'vm-roothide-b33-20261010', 'ipsws'):
        root = ROOT / dirname
        for p in [root, *root.iterdir()]:
            info = meta(p)
            if stat.S_ISREG(info['mode']) and info['size'] < 8 << 20:
                info['sha256'] = sha(p)
            result[str(p.relative_to(ROOT))] = info
    result['.venv'] = meta(ROOT / '.venv')
    result['gitHEAD'] = git('rev-parse', 'HEAD').decode().strip()
    return result


def unused():
    ps = command(['/bin/ps', '-axo', 'pid,uid,comm']).decode()
    (OUT / 'processes.txt').write_text(ps)
    images = command(['/usr/bin/hdiutil', 'info', '-plist'])
    (OUT / 'attachments.plist').write_bytes(images)
    for row in plistlib.loads(images).get('images', []):
        values = [row.get('image-path', '')] + [e.get('mount-point', '') for e in row.get('system-entities', [])]
        for value in filter(None, values):
            p = Path(value).resolve()
            if any(p == root or root in p.parents for root in TARGETS):
                raise ValueError('Attached experiment image: ' + value)
    observations = []
    for target in TARGETS:
        r = subprocess.run(['/usr/sbin/lsof', '-nP', '-F', 'pn', '+D', str(target)],
                           capture_output=True, text=True, timeout=60)
        observations.append(dict(path=str(target), code=r.returncode, stdout=r.stdout, stderr=r.stderr))
        save('open-handles.json', observations)
        if r.returncode not in (0, 1) or r.stderr:
            raise ValueError('Open handle inspection failed')
        owner = None
        for line in r.stdout.splitlines():
            if line.startswith('p'):
                owner = int(line[1:])
            elif line.startswith('n') and owner != os.getpid():
                raise ValueError('Open handle: ' + line[1:])


def verify_archive(manifest):
    path = OUT / 'retained-records-and-inputs.tar.gz'
    if sha(path) != manifest['archiveSHA256']:
        raise ValueError('Archive digest differs')
    with tarfile.open(path) as archive:
        if archive.getnames() != list(manifest['files']):
            raise ValueError('Archive members differ')
        for name, row in manifest['files'].items():
            with archive.extractfile(name) as stream:
                if hashlib.file_digest(stream, 'sha256').hexdigest() != row['sha256']:
                    raise ValueError('Archived member differs: ' + name)


def main():
    if sys.argv[1:] not in [[], ['--apply'], ['--verify']]:
        raise ValueError('Use no argument, --apply or --verify')
    OUT.mkdir(exist_ok=True, mode=0o700)
    if sys.argv[1:] == ['--verify']:
        plan = json.loads((OUT / 'plan.json').read_text())
        result = json.loads((OUT / 'result.json').read_text())
        if result['state'] != 'completed' or any(os.path.lexists(p) for p in TARGETS):
            raise ValueError('Retirement incomplete')
        if protected() != plan['protected']:
            raise ValueError('Protected data differs')
        verify_archive(json.loads((OUT / 'archive-manifest.json').read_text()))
        save('independent-verification.json', dict(result='pass', rootsAbsent=4,
             archiveVerified=True, protectedVerified=True, freeBytes=shutil.disk_usage(ROOT).free))
        print('Independent verification passed', flush=True)
        return
    if (OUT / 'result.json').exists():
        raise ValueError('Execution already recorded')
    handles = []
    try:
        for root in TARGETS:
            fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            handles.append(fd)
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        unused()
        if git('ls-files', '-z', '--', *NAMES):
            raise ValueError('Tracked file in deletion scope')
        refs = subprocess.run(['rg', '-l', '-F', '--hidden',
                               *[arg for name in NAMES for arg in ('-e', name)],
                               '--', 'research', 'sources', 'scripts'], cwd=ROOT,
                              capture_output=True, text=True, timeout=60)
        if refs.returncode not in (0, 1):
            raise ValueError('Reference scan failed: ' + refs.stderr)
        save('reference-files.json', dict(files=refs.stdout.splitlines(),
             policy='Historical references retained; old frozen plans and runtime identities retired.'))
        rows = inventory()
        protected_before = protected()
        if not (OUT / 'plan.json').exists():
            print('Archiving records, source snapshots and candidate packages', flush=True)
            records = {}
            archive_path = OUT / 'retained-records-and-inputs.tar.gz'
            with tarfile.open(archive_path, 'x:gz', compresslevel=1, dereference=False) as archive:
                for name, info in sorted(rows.items()):
                    if not preserve(name, info):
                        continue
                    p = ROOT / name
                    records[name] = dict(metadata=info, sha256=sha(p))
                    archive.add(p, arcname=name, recursive=False)
                    if meta(p) != info:
                        raise ValueError('Archive input changed: ' + name)
                    if len(records) % 1000 == 0:
                        print('Archived files: ' + str(len(records)), flush=True)
            archive_path.chmod(0o600)
            manifest = dict(files=records, archiveSHA256=sha(archive_path), fullVMBackup=False)
            save('archive-manifest.json', manifest)
            verify_archive(manifest)
            with gzip.open(OUT / 'inventory.json.gz', 'wt') as stream:
                json.dump(rows, stream)
            save('plan.json', dict(targets=NAMES, protected=protected_before,
                 authorization='Current chat: 进行一波清理吧; preceding four T32/T33 groups',
                 inventoryEntries=len(rows), allocatedBytes=sum(r['blocks'] * 512 for r in rows.values()),
                 archivedFiles=len(records), scriptSHA256=sha(Path(__file__)),
                 retiredCapabilities=['old VM boot', 'old receipt/undo replay', 'old frozen plan reuse']))
        plan = json.loads((OUT / 'plan.json').read_text())
        if tuple(plan['targets']) != NAMES or plan['scriptSHA256'] != sha(Path(__file__)):
            raise ValueError('Scope or script changed')
        with gzip.open(OUT / 'inventory.json.gz', 'rt') as stream:
            if rows != json.load(stream):
                raise ValueError('Inventory changed')
        if protected_before != plan['protected']:
            raise ValueError('Protected inputs changed')
        print(json.dumps({k:plan[k] for k in ('inventoryEntries', 'allocatedBytes', 'archivedFiles')}), flush=True)
        if not sys.argv[1:]:
            return
        verify_archive(json.loads((OUT / 'archive-manifest.json').read_text()))
        unused()
        if inventory() != rows or protected() != protected_before:
            raise ValueError('Pre-delete state changed')
        before = shutil.disk_usage(ROOT).free
        result = dict(state='deleting', startedAt=datetime.datetime.now().astimezone().isoformat(),
                      freeBytesBefore=before, deleted=[])
        save('result.json', result)
        for root in TARGETS:
            print('Removing ' + str(root.relative_to(ROOT)), flush=True)
            shutil.rmtree(root)
            if os.path.lexists(root):
                raise ValueError('Root still exists')
            result['deleted'].append(str(root.relative_to(ROOT)))
            save('result.json', result)
        after = protected()
        save('protected-after.json', after)
        if after != protected_before:
            raise ValueError('Protected inputs differ after deletion')
        result.update(state='completed', freeBytesAfter=shutil.disk_usage(ROOT).free,
                      completedAt=datetime.datetime.now().astimezone().isoformat())
        result['freeBytesDelta'] = result['freeBytesAfter'] - before
        save('result.json', result)
        print(json.dumps(result), flush=True)
    finally:
        for fd in handles:
            os.close(fd)


if __name__ == '__main__':
    main()
