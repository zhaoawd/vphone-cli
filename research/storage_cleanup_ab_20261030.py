"""Clean only the twelve A+B objects approved in the current chat."""

import datetime
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

import project_storage_review_20261024 as packages
import storage_cleanup_20261030 as safety

ROOT = safety.ROOT
REVIEW = ROOT / 'research/evidence/storage-review-additional-20261030'
OUT = ROOT / 'research/evidence/storage-cleanup-ab-20261030'
BASE = '.build/t32-t33-completion-20261023'
NAMES = [f'{BASE}/{name}' for name in [
    'exp-bootstrap-pristine-9770-20261025',
    'exp-plist-lifetime-pristine-3ffd-20261025',
    'exp-reboot-recovery-pristine-f430-20261026',
    'exp-reboot-recovery-pristine-f430-20261026-r2',
    'exp-staged-dsc-pristine-e127-20261025',
    'source-identity-pristine-73b-20261026',
]] + ['.build/artifacts', '.build/daemon-api-icli086-20261021/PackageCache',
      '.build/daemon-api-icli086-20261021/Xcode/SourcePackages',
      '.build/t52-consumer-fix-20261022/daemon-api/Xcode/SourcePackages']
FAILURES = ['20261025T100633Z-Bvlz2q7C', '20261025T114952Z-zhZ5OOCf']
NAMES += [f'.build/t33t-20261025/.cfw-history/{name}/effect-blobs' for name in FAILURES]
TARGETS = [ROOT / name for name in NAMES]
safety.OUT = OUT
safety.DIRECTORIES = NAMES
safety.FILES = []
safety.TARGETS = TARGETS


def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def inventory(path):
    if path.resolve(strict=True) != path or not path.is_dir():
        raise ValueError('Unexpected cleanup directory: ' + str(path))
    result = {str(path.relative_to(ROOT)): safety.metadata(path)}
    def fail(error):
        raise error
    for parent, dirs, files in os.walk(path, followlinks=False, onerror=fail):
        if os.path.ismount(parent) or not os.access(parent, os.W_OK | os.X_OK):
            raise ValueError('Mounted or unwritable directory: ' + parent)
        for name in dirs + files:
            child = Path(parent) / name
            if name in ['Disk.img', 'guest-postimage.img', '.cfw-history', '.firmware-generations']:
                raise ValueError('Unexpected VM state inside target: ' + str(child))
            result[str(child.relative_to(ROOT))] = safety.metadata(child)
    return result


def retained():
    result = safety.protected()
    # Preserve C entirely; only metadata is read for its large images.
    old = ROOT / 'vm-t32-t33-dsc-20261018'
    for path in [old, *old.rglob('*')]:
        result[str(path.relative_to(ROOT))] = safety.metadata(path)
    for name in FAILURES:
        directory = ROOT / '.build/t33t-20261025/.cfw-history' / name
        record = json.loads((directory / 'transaction.json').read_text())
        if record['status'] != 'failed' or record['exit_code'] != 1 or record['staged_removed'] is not True:
            raise ValueError('Failure transaction state changed')
        for parent, dirs, files in os.walk(directory):
            dirs[:] = [d for d in dirs if d != 'effect-blobs']
            for filename in files:
                path = Path(parent) / filename
                info = safety.metadata(path)
                info['sha256'] = sha(path)
                result[str(path.relative_to(ROOT))] = info
    comparisons = json.loads((REVIEW / 'package-comparisons.json').read_text())
    for row in comparisons:
        if row['matched']:
            archive = ROOT / row['archive']
            if sha(archive) != row['archiveSHA256']:
                raise ValueError('Retained archive changed')
            result[row['archive']] = dict(safety.metadata(archive), sha256=row['archiveSHA256'])
    return result


def archive_small_records(protected):
    records = {name: info for name, info in protected.items()
               if any(f'/.cfw-history/{failure}/' in '/' + name for failure in FAILURES)
               and info.get('sha256') and info['size'] <= 8 * 1024**2
               and Path(name).suffix in ['.json', '.jsonl', '.plist', '.log', '.txt', '.shsh']}
    archive = OUT / 'failed-small-records.tar.gz'
    if not archive.exists():
        with tarfile.open(archive, 'x:gz', dereference=False) as tar:
            for name in records:
                tar.add(ROOT / name, arcname=name, recursive=False)
    with tarfile.open(archive) as tar:
        if set(tar.getnames()) != set(records):
            raise ValueError('Small-record archive membership changed')
        for name, info in records.items():
            with tar.extractfile(name) as stream:
                if hashlib.file_digest(stream, 'sha256').hexdigest() != info['sha256']:
                    raise ValueError('Small-record archive digest differs')
    safety.save('small-records-manifest.json', dict(files=records, archiveSHA256=sha(archive)))
    return len(records)


def main():
    if sys.argv[1:] not in [[], ['--apply']]:
        raise ValueError('Use no argument or --apply')
    OUT.mkdir(exist_ok=True)
    if (OUT / 'result.json').exists():
        raise ValueError('Execution already recorded; do not repeat')
    assessment = json.loads((REVIEW / 'assessment.json').read_text())
    if NAMES != [row['path'] for row in assessment['targets'] if row['group'] in ['A', 'B']]:
        raise ValueError('Approved A+B scope differs')
    handles = []
    try:
        safety.processes('before')
        safety.references()
        before_inventory = {}
        opened = []
        for path in TARGETS:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            handles.append(fd)
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            before_inventory.update(inventory(path))
            command = ['/usr/sbin/lsof', '-nP', '-F', 'pn', '+D', str(path)]
            run = subprocess.run(command, capture_output=True, text=True, timeout=45)
            opened.append(dict(path=str(path.relative_to(ROOT)), code=run.returncode,
                               stdout=run.stdout, stderr=run.stderr))
            if run.returncode not in [0, 1] or run.stderr:
                raise ValueError('lsof failed')
            owner = None
            for line in run.stdout.splitlines():
                if line.startswith('p'):
                    owner = int(line[1:])
                elif line.startswith('n') and owner != os.getpid():
                    raise ValueError('Cleanup target in use: ' + line[1:])
        safety.save('open-handles.json', opened)
        import plistlib
        images = subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist'])
        (OUT / 'attachments.plist').write_bytes(images)
        for row in plistlib.loads(images).get('images', []):
            image = Path(row.get('image-path', '/nonexistent')).resolve()
            if any(image == p or p in image.parents for p in TARGETS):
                raise ValueError('Cleanup target attached')
        if subprocess.check_output(['git', 'ls-files', '-z', '--', *NAMES], cwd=ROOT):
            raise ValueError('Tracked cleanup target')
        frozen = json.loads(safety.PLAN.read_text())['frozenInputs']
        compared = [packages.compare(ROOT / r['directory'], ROOT / r['archive'], r['archiveSHA256'], frozen)
                    for r in json.loads((REVIEW / 'package-comparisons.json').read_text()) if r['matched']]
        safety.save('package-comparisons.json', compared)
        protected = retained()
        small_count = archive_small_records(protected)
        allocated = sum(info['blocks'] * 512 for info in before_inventory.values())
        safety.save('plan.json', dict(time=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    authorization='Current chat: 先清理a+b，另外旧dsc vm是什么', targets=NAMES,
                    protected=protected, allocatedBytes=allocated, archivedSmallRecords=small_count,
                    reviewSHA256=sha(REVIEW / 'assessment.json')))
        (OUT / 'inventory.json.gz').write_bytes(gzip.compress(json.dumps(before_inventory).encode(), mtime=0))
        if not sys.argv[1:]:
            print(json.dumps(dict(state='prepared', targets=12, allocatedBytes=allocated,
                                  archivedSmallRecords=small_count)))
            return
        safety.processes('immediately-before')
        # Recheck every target before deleting the first one.
        for path in TARGETS:
            expected = {k: v for k, v in before_inventory.items()
                        if k == str(path.relative_to(ROOT)) or str(path.relative_to(ROOT)) + '/' in k}
            if inventory(path) != expected:
                raise ValueError('Cleanup target changed before deletion')
        free_before = shutil.disk_usage(ROOT).free
        result = dict(state='in_progress', removed=[], freeBytesBefore=free_before, allocatedBytes=allocated)
        safety.save('result.json', result)
        for path in TARGETS:
            if safety.metadata(path) != before_inventory[str(path.relative_to(ROOT))]:
                raise ValueError('Cleanup directory changed')
            shutil.rmtree(path)
            if os.path.lexists(path):
                raise ValueError('Cleanup target remains')
            result['removed'].append(str(path.relative_to(ROOT)))
            safety.save('result.json', result)
            print('Removed ' + str(path.relative_to(ROOT)), flush=True)
        for fd in handles:
            os.close(fd)
        handles.clear()
        after = retained()
        safety.save('protected-after.json', after)
        if after != protected:
            raise ValueError('Protected state changed; inspect evidence')
        safety.processes('after')
        result.update(state='completed', allTargetsAbsent=all(not os.path.lexists(p) for p in TARGETS),
                      protectedUnchanged=True, groupCUnchanged=True, freeBytesAfter=shutil.disk_usage(ROOT).free)
        result['freeBytesIncrease'] = result['freeBytesAfter'] - free_before
        safety.save('result.json', result)
        print(json.dumps(result, ensure_ascii=False))
    finally:
        for fd in handles:
            os.close(fd)


if __name__ == '__main__':
    main()
