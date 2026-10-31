"""Execute only the ten cleanup objects approved in the current chat."""

import datetime
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'research/evidence/storage-cleanup-20261030'
BASE = '.build/t32-t33-completion-20261023'
DIRECTORIES = ['.build/out', '.build/test-module-cache',
               '.build/release-module-cache', '.build/test-cache']
DIAGNOSTICS = ['cryptex-tree-stability-20261025-root',
               'cryptex-private-attach-20261025',
               'cryptex-mounted-image-sequence-20261025']
FILES = [f'{BASE}/{name}/{mode}/cache.dmg'
         for name in DIAGNOSTICS for mode in ['readonly', 'writable']]
TARGETS = [ROOT / name for name in DIRECTORIES + FILES]
PLAN = ROOT / BASE / 'exp-source-identity-acceptance-20261026/offline-plan.json'


def save(name, value):
    (OUT / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def metadata(path):
    s = path.lstat()
    result = dict(dev=s.st_dev, ino=s.st_ino, mode=s.st_mode, size=s.st_size,
                  mtime_ns=s.st_mtime_ns, blocks=s.st_blocks, nlink=s.st_nlink)
    if stat.S_ISLNK(s.st_mode):
        result['link'] = os.readlink(path)
    return result


def protected():
    result = {}
    for name in DIAGNOSTICS:
        for parent, dirs, files in os.walk(ROOT / BASE / name):
            for filename in files:
                p = Path(parent) / filename
                if p in TARGETS:
                    continue
                result[str(p.relative_to(ROOT))] = metadata(p)
                result[str(p.relative_to(ROOT))]['sha256'] = hashlib.sha256(p.read_bytes()).hexdigest()
    for name in ['vm-new', 'vm-2607', 'vm-roothide-b33-20261010',
                 'vm-t32-t33-dsc-20261018', '.build/t32q-20261024',
                 '.build/t33t-20261025', '.build/t32q-20261024-binding-backup',
                 f'{BASE}/pre-acceptance-backup', f'{BASE}/t33t-first-binding-20261025']:
        root = ROOT / name
        result[name] = {key: value for key, value in metadata(root).items()
                        if key in ['dev', 'ino', 'mode']}
        for filename in ['Disk.img', 'config.plist', 'nvram.bin', 'SEPStorage',
                         'AVPBooter.vresearch1.bin', 'AVPSEPBooter.vresearch1.bin',
                         'launchpad.json', '.vphone-runtime.json',
                         '.cfw-reboot-identity.json', '.cfw-reboot-source-identity.json']:
            p = root / filename
            try:
                info = metadata(p)
            except FileNotFoundError:
                continue
            if filename != 'Disk.img':
                try:
                    info['sha256'] = hashlib.sha256(p.read_bytes()).hexdigest()
                except PermissionError:
                    info['hashRead'] = 'permission denied'
            result[str(p.relative_to(ROOT))] = info
    result[str(PLAN.relative_to(ROOT))] = {'sha256': hashlib.sha256(PLAN.read_bytes()).hexdigest()}
    result['.venv'] = metadata(ROOT / '.venv')
    return result


def processes(label):
    rows = subprocess.check_output(['/bin/ps', '-axo', 'pid,ppid,etime,command'], text=True)
    active = []
    other = []
    pattern = re.compile(r'(?:^|[/\s])(?:vphone-vm|vphone-cli|swift-frontend|swiftc|swift-build|swift-test|xcodebuild)(?:\s|$)|cfw_install|scripts/run_tests\.py|probe_t33_|tools/(?:execute|run)_t3[23]_')
    for row in rows.splitlines()[1:]:
        fields = row.split(None, 3)
        if len(fields) != 4 or int(fields[0]) == os.getpid() or not pattern.search(fields[3]):
            continue
        cwd = subprocess.run(['/usr/sbin/lsof', '-a', '-p', fields[0], '-d', 'cwd', '-Fn'],
                             capture_output=True, text=True, timeout=15)
        directories = [line[1:] for line in cwd.stdout.splitlines() if line.startswith('n')]
        if str(ROOT) + '/' in fields[3] or any(
                Path(name) == ROOT or Path(name).is_relative_to(ROOT) for name in directories):
            active.append(row)
        elif not directories:
            active.append(row + ' (working directory unavailable)')
        else:
            other.append(dict(process=row, cwd=directories))
    save(f'{label}-processes.json', active)
    save(f'{label}-other-project-processes.json', other)
    if active:
        raise RuntimeError('Active VM/build/acceptance process; see process evidence')


def references():
    data = json.loads(PLAN.read_text())
    strings = []

    def walk(value):
        if isinstance(value, str):
            strings.append(value)
        elif isinstance(value, list):
            for child in value:
                walk(child)
        elif isinstance(value, dict):
            for key, child in value.items():
                strings.append(key)
                walk(child)

    walk(data)
    hits = []
    for name in DIRECTORIES + FILES:
        for value in strings:
            if value in [name, str(ROOT / name)] or name + '/' in value or name in value and name in FILES:
                hits.append({'target': name, 'reference': value})
    save('plan-reference-check.json', hits)
    if hits:
        raise RuntimeError('Cleanup target referenced by current acceptance plan')


def main():
    if sys.argv[1:] not in [[], ['--apply']]:
        raise RuntimeError('Use no argument or --apply')
    apply = sys.argv[1:] == ['--apply']
    OUT.mkdir(exist_ok=True)
    if (OUT / 'result.json').exists():
        raise RuntimeError('Execution already recorded; do not repeat')
    handles = []
    try:
        processes('before')
        references()
        inventory = {}
        initial = {}
        open_files = []
        for p in TARGETS:
            if p.resolve(strict=True) != p:
                raise RuntimeError('Unexpected real path: ' + str(p))
            info = metadata(p)
            is_directory = str(p.relative_to(ROOT)) in DIRECTORIES
            if not (stat.S_ISDIR(info['mode']) if is_directory else stat.S_ISREG(info['mode'])):
                raise RuntimeError('Unexpected target type: ' + str(p))
            if not is_directory and info['nlink'] != 1:
                raise RuntimeError('Unexpected hard links: ' + str(p))
            fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW)
            handles.append(fd)
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            initial[str(p.relative_to(ROOT))] = info
            if is_directory:
                def walk_error(error):
                    raise error
                for parent, dirs, files in os.walk(p, followlinks=False, onerror=walk_error):
                    if os.path.ismount(parent):
                        raise RuntimeError('Mounted cleanup directory: ' + parent)
                    for name in dirs + files:
                        if name in ['Disk.img', 'guest-postimage.img', '.cfw-history',
                                    '.firmware-generations', '.vphone-runtime.json']:
                            raise RuntimeError('VM data in cleanup directory: ' + str(Path(parent) / name))
                        child = Path(parent) / name
                        inventory[str(child.relative_to(ROOT))] = metadata(child)
            cmd = ['/usr/sbin/lsof', '-nP', '-F', 'pn'] + (['+D'] if is_directory else ['--']) + [str(p)]
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=45)
            open_files.append(dict(path=str(p.relative_to(ROOT)), code=r.returncode,
                                   stdout=r.stdout, stderr=r.stderr))
            if r.returncode not in [0, 1] or r.stderr:
                raise RuntimeError('lsof failed: ' + str(p))
            owner = None
            for line in r.stdout.splitlines():
                if line.startswith('p'):
                    owner = int(line[1:])
                elif line.startswith('n') and owner != os.getpid():
                    raise RuntimeError('Open target: ' + line[1:])
        save('open-handles.json', open_files)
        images = plistlib.loads(subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist']))
        (OUT / 'attachments.plist').write_bytes(plistlib.dumps(images))
        for entry in images.get('images', []):
            image = Path(entry.get('image-path', '/nonexistent')).resolve()
            if any(image == p or image.is_relative_to(p) for p in TARGETS):
                raise RuntimeError('Attached cleanup target: ' + str(image))
        tracked = subprocess.check_output(['git', '-c', 'safe.directory=' + str(ROOT),
                                           'ls-files', '-z', '--', *DIRECTORIES, *FILES], cwd=ROOT)
        if tracked:
            raise RuntimeError('Tracked cleanup target')
        retained = protected()
        allocated = sum(i['blocks'] * 512 for i in [*initial.values(), *inventory.values()])
        plan = dict(time=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    authorization='Current chat: 确认这些清理内容; ten objects in storage_cleanup_review_20261030.md',
                    targets=list(initial), initial=initial, protected=retained,
                    allocatedBytes=allocated, inventoryEntries=len(inventory))
        save('plan.json', plan)
        (OUT / 'inventory.json.gz').write_bytes(gzip.compress(json.dumps(inventory).encode(), mtime=0))
        if not apply:
            print(json.dumps(dict(state='prepared', targets=len(TARGETS), allocatedBytes=allocated,
                                  inventoryEntries=len(inventory))))
            return
        processes('immediately-before')
        before = shutil.disk_usage(ROOT).free
        result = dict(state='in_progress', removed=[], freeBytesBefore=before, allocatedBytes=allocated)
        save('result.json', result)
        for p in TARGETS:
            name = str(p.relative_to(ROOT))
            if metadata(p) != initial[name]:
                raise RuntimeError('Target changed before removal: ' + name)
            if name in DIRECTORIES:
                shutil.rmtree(p)
            else:
                p.unlink()
            if os.path.lexists(p):
                raise RuntimeError('Target still exists: ' + name)
            result['removed'].append(name)
            save('result.json', result)
            print('Removed ' + name, flush=True)
        for fd in handles:
            os.close(fd)
        handles.clear()
        after = protected()
        save('protected-after.json', after)
        if after != retained:
            raise RuntimeError('Protected objects changed; review saved evidence')
        processes('after')
        result.update(state='completed', protectedUnchanged=True,
                      allTargetsAbsent=all(not os.path.lexists(p) for p in TARGETS),
                      freeBytesAfter=shutil.disk_usage(ROOT).free)
        result['freeBytesIncrease'] = result['freeBytesAfter'] - before
        save('result.json', result)
        print(json.dumps(result, ensure_ascii=False))
    finally:
        for fd in handles:
            os.close(fd)


if __name__ == '__main__':
    main()
