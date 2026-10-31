"""Clean only the eleven build/cache directories approved in this chat."""
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

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'research/evidence/build-cache-cleanup-2026-10-23'
TARGETS = [ROOT / name for name in [
    '.build/out',
    '.build/t51-commit-scope/swift-build',
    '.build/test-daemon-pipe',
    '.build/daemon-api-icli086-20261021/Xcode/Build',
    '.build/t52-consumer-fix-20261022/daemon-api/Xcode/Build',
    '.build/pip-cache',
    '.build/build-module-cache',
    '.build/test-module-cache',
    '.build/release-module-cache',
    '.build/t52-consumer-fix-20261022/daemon-api/Xcode/ModuleCache.noindex',
    '.build/t52-consumer-fix-20261022/daemon-api/Xcode/SDKExplicitPrecompiledModules',
]]


def metadata(p):
    s = p.lstat()
    result = dict(dev=s.st_dev, ino=s.st_ino, mode=s.st_mode,
                  size=s.st_size, mtime_ns=s.st_mtime_ns, blocks=s.st_blocks)
    if p.is_symlink():
        result['link'] = os.readlink(p)
    return result


def save(name, value):
    (OUT / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def protected():
    result = {}
    for parent, dirs, files in os.walk(ROOT / '.build', followlinks=False):
        base = Path(parent)
        # Only inspect root-level retained objects and the running VM library.
        if base == ROOT / '.build':
            dirs[:] = [n for n in dirs if n.endswith('.app') or n == 't51rt']
        elif base == ROOT / '.build/t51rt':
            dirs[:] = ['lib']
        elif base == ROOT / '.build/t51rt/lib':
            dirs[:] = ['t52-v2']
        elif base == ROOT / '.build/t51rt/lib/t52-v2':
            dirs[:] = []
        elif '.app' in str(base):
            dirs[:] = [n for n in dirs if n in ['Contents', 'MacOS']]
        for name in files:
            p = base / name
            if name in ['.vphone-runtime.json', 'config.plist'] or base.name == 'MacOS':
                record = metadata(p)
                record['sha256'] = hashlib.sha256(p.read_bytes()).hexdigest()
                result[str(p.relative_to(ROOT))] = record
    for name in ['vm-2607', 'vm-new', 'vm-roothide-b33-20261010',
                 'vm-t32-t33-dsc-20261018', 'vm-t32-t33-20261018-r2',
                 '.build/t51rt/lib/t52-v2']:
        p = ROOT / name / 'Disk.img'
        if p.exists():
            s = p.stat()
            result[str(p.relative_to(ROOT))] = dict(dev=s.st_dev, ino=s.st_ino, size=s.st_size)
    for name in ['.venv', '.build/daemon-api-icli086-20261021/Xcode/SourcePackages',
                 '.build/daemon-api-icli086-20261021/candidate',
                 '.build/t52-consumer-fix-20261022/package',
                 '.build/t51-commit-scope/tree/sources/vphone-cli/VPhoneBuildInfo.swift']:
        p = ROOT / name
        if p.exists() or p.is_symlink():
            result[name] = metadata(p)
    return result


def process_check(label):
    r = subprocess.run(['/bin/ps', '-axo', 'pid,ppid,etime,command'],
                       capture_output=True, text=True, check=True)
    rows = []
    for line in r.stdout.splitlines()[1:]:
        fields = line.split(None, 3)
        if len(fields) < 4 or int(fields[0]) == os.getpid():
            continue
        cmd = fields[3]
        if any(x in cmd for x in ['swift-build', 'swift-test', '/swiftc ',
                                  '/xcodebuild ', 'scripts/run_tests.py', 'unittest']):
            raise RuntimeError('Build/test process requires review: ' + line)
        if 'vphone' in cmd or 'cfw_install' in cmd:
            rows.append(line)
    (OUT / (label + '-processes.txt')).write_text('\n'.join(rows) + '\n')


def main():
    if sys.argv[1:] not in [[], ['--apply']]:
        raise RuntimeError('Use no argument or --apply')
    apply = sys.argv[1:] == ['--apply']
    OUT.mkdir(exist_ok=True)
    if (OUT / 'result.json').exists():
        raise RuntimeError('Existing result; do not repeat deletion')
    process_check('before')
    handles = []
    try:
        inventory = {}
        initial = {}
        for p in TARGETS:
            if p.resolve(strict=True) != p or not p.is_dir():
                raise RuntimeError('Unexpected target or symlink: ' + str(p))
            fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW)
            handles.append(fd)
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            initial[str(p.relative_to(ROOT))] = metadata(p)
            for parent, dirs, files in os.walk(p, followlinks=False):
                if os.path.ismount(parent):
                    raise RuntimeError('Mounted target: ' + parent)
                for name in dirs + files:
                    child = Path(parent) / name
                    if name in ['Disk.img', 'guest-postimage.img', '.vphone-runtime.json',
                                '.cfw-history', '.firmware-generations', '.environment-history']:
                        raise RuntimeError('VM state inside cleanup target: ' + str(child))
                    inventory[str(child.relative_to(ROOT))] = metadata(child)
            check = subprocess.run(['/usr/sbin/lsof', '-nP', '-F', 'pn', '+D', str(p)],
                                   capture_output=True, text=True)
            if check.returncode not in (0, 1) or check.stderr.strip():
                raise RuntimeError('lsof failed: ' + check.stderr)
            owner = None
            for line in check.stdout.splitlines():
                if line.startswith('p'):
                    owner = int(line[1:])
                elif line.startswith('n') and owner != os.getpid():
                    raise RuntimeError('Open target: ' + str(owner) + ' ' + line[1:])
        images = plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist']))
        for entry in images.get('images', []):
            image = Path(entry.get('image-path', '/nonexistent')).resolve()
            if any(image == p or image.is_relative_to(p) for p in TARGETS):
                raise RuntimeError('Attached disk: ' + str(image))
        tracked = subprocess.check_output(['git', 'ls-files', '-z', '--',
                                           *[str(p.relative_to(ROOT)) for p in TARGETS]], cwd=ROOT)
        if tracked:
            raise RuntimeError('Tracked files inside targets')
        retained = protected()
        before = shutil.disk_usage(ROOT).free
        plan = dict(time=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    authorization='Current chat: 按建议清理 (build outputs and caches only)',
                    targets=list(initial), initial=initial, protected=retained,
                    freeBytesBefore=before, inventoryEntries=len(inventory),
                    allocatedBytes=sum(x['blocks'] * 512 for x in inventory.values())
                                   + sum(x['blocks'] * 512 for x in initial.values()))
        save('plan.json', plan)
        (OUT / 'inventory.json.gz').write_bytes(gzip.compress(json.dumps(inventory).encode(), mtime=0))
        if not apply:
            print(json.dumps(dict(state='prepared', targets=len(TARGETS),
                                  inventoryEntries=len(inventory), allocatedBytes=plan['allocatedBytes'])))
            return
        result = dict(state='in_progress', removed=[], freeBytesBefore=before)
        save('result.json', result)
        for p in TARGETS:
            relative = str(p.relative_to(ROOT))
            if metadata(p) != initial[relative]:
                raise RuntimeError('Target changed: ' + relative)
            shutil.rmtree(p)
            if os.path.lexists(p):
                raise RuntimeError('Target remains: ' + relative)
            result['removed'].append(relative)
            save('result.json', result)
            print('Removed ' + relative, flush=True)
        process_check('after')
        after = protected()
        save('protected-after.json', after)
        if after != retained:
            raise RuntimeError('Protected object changed; review saved evidence')
        result.update(state='completed', protectedUnchanged=True,
                      freeBytesAfter=shutil.disk_usage(ROOT).free)
        result['freeBytesIncrease'] = result['freeBytesAfter'] - before
        save('result.json', result)
        print(json.dumps(result, ensure_ascii=False))
    finally:
        for fd in handles:
            os.close(fd)


if __name__ == '__main__':
    main()
