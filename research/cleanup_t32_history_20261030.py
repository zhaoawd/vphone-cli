"""Retire only the T32 regular CFW history authorized in this chat."""

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

import storage_cleanup_20261030 as safety

ROOT = Path(__file__).resolve().parents[1]
VM = ROOT / '.build/t32q-20261024'
TARGET = VM / '.cfw-history'
OUT = ROOT / 'research/evidence/t32-history-cleanup-20261030'
PLAN = safety.PLAN
IDS = ('20261024T004144Z-SaOxXsod', '20261024T044848Z-v8ovSVP3',
       '20261024T064924Z-hG5gtVTI', '20261024T081630Z-kbuBz8Io')
safety.OUT = OUT


def save(name, value):
    (OUT / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def metadata(path):
    s = path.lstat()
    d = {k: getattr(s, 'st_' + k) for k in
         ('dev', 'ino', 'mode', 'uid', 'gid', 'size', 'mtime_ns', 'ctime_ns', 'nlink', 'blocks')}
    d['flags'] = getattr(s, 'st_flags', 0)
    if stat.S_ISLNK(s.st_mode):
        d['link'] = os.readlink(path)
    return d


def sha(path, progress=False):
    digest = hashlib.sha256()
    total = 0
    with path.open('rb') as stream:
        while block := stream.read(8 << 20):
            digest.update(block)
            total += len(block)
            if progress and total % (8 << 30) == 0:
                print(f'Current regular disk read: {total >> 30} GiB', flush=True)
    return digest.hexdigest()


def inventory():
    if TARGET.resolve(strict=True) != TARGET or TARGET.is_symlink():
        raise ValueError('Unexpected history path')
    if sorted(p.name for p in TARGET.iterdir()) != sorted(IDS):
        raise ValueError('History transaction set differs')
    result = {str(TARGET.relative_to(ROOT)): metadata(TARGET)}
    def fail(error):
        raise error
    for parent, dirs, files in os.walk(TARGET, followlinks=False, onerror=fail):
        if os.path.ismount(parent) or not os.access(parent, os.W_OK | os.X_OK):
            raise ValueError('Mounted or unwritable history directory: ' + parent)
        for name in dirs + files:
            p = Path(parent) / name
            s = metadata(p)
            if not (stat.S_ISREG(s['mode']) or stat.S_ISDIR(s['mode'])):
                raise ValueError('Linked or special history entry: ' + str(p))
            forbidden = sum(getattr(stat, k, 0) for k in
                            ('UF_IMMUTABLE', 'UF_APPEND', 'SF_IMMUTABLE', 'SF_APPEND', 'SF_NOUNLINK'))
            if s['flags'] & forbidden or (stat.S_ISREG(s['mode']) and s['nlink'] != 1):
                raise ValueError('Protected flags or shared hard link: ' + str(p))
            result[str(p.relative_to(ROOT))] = s
    for name in IDS:
        d = json.loads((TARGET / name / 'transaction.json').read_text())
        if d['status'] != 'published' or d['exit_code'] != 0 or d['id'] != name or d['vm'] != str(VM):
            raise ValueError('History transaction changed')
    return result


def references():
    d = json.loads(PLAN.read_text())
    hits = []
    needle = str(TARGET.relative_to(ROOT))
    def walk(v, loc='$'):
        if isinstance(v, dict):
            for k, value in v.items():
                if needle in k:
                    hits.append(dict(field=loc + '.' + k, reference=k))
                walk(value, loc + '.' + k)
        elif isinstance(v, list):
            for i, value in enumerate(v):
                walk(value, loc + f'[{i}]')
        elif isinstance(v, str) and needle in v:
            hits.append(dict(field=loc, reference=v))
    walk(d)
    expected = needle + '/' + IDS[0] + '/Disk.img'
    if hits != [dict(field='$.unrelatedDiskIdentities.' + expected, reference=expected)]:
        raise ValueError('Current plan references differ from reviewed retirement scope')
    return dict(plan=str(PLAN.relative_to(ROOT)), sha256=sha(PLAN), retiredReferences=hits,
                originalPlanPreserved=True, oldPathPreservationCheckWillFail=True)


def protected():
    result = {}
    roots = [VM, ROOT / '.build/t33t-20261025', ROOT / '.build/t32q-20261024-binding-backup',
             ROOT / '.build/t32-t33-completion-20261023/pre-acceptance-backup',
             ROOT / '.build/t32-t33-completion-20261023/t33t-first-binding-20261025',
             ROOT / 'vm-new', ROOT / 'vm-2607', ROOT / 'vm-roothide-b33-20261010']
    for root in roots:
        info = metadata(root)
        result[str(root.relative_to(ROOT))] = {k: info[k] for k in ('dev', 'ino', 'mode', 'uid', 'gid')}
        for p in sorted(root.iterdir()):
            if p == TARGET:
                continue
            info = metadata(p)
            if stat.S_ISREG(info['mode']) and info['size'] <= 8 << 20:
                try:
                    info['sha256'] = sha(p)
                except PermissionError:
                    info['contentRead'] = 'permission denied'
            result[str(p.relative_to(ROOT))] = info
    result['.venv'] = metadata(ROOT / '.venv')
    result[str(PLAN.relative_to(ROOT))] = dict(sha256=sha(PLAN))
    return result


def archive_records(items):
    records = {}
    for name, info in items.items():
        p = ROOT / name
        if not stat.S_ISREG(info['mode']) or 'effect-blobs' in p.parts or p.name in ('Disk.img', 'guest-postimage.img'):
            continue
        if info['size'] > 8 << 20 or p.suffix not in ('.json', '.jsonl'):
            raise ValueError('Unreviewed record type or size: ' + name)
        records[name] = dict(metadata=info, sha256=sha(p))
    if len(records) != 47:
        raise ValueError('Record set differs from reviewed 47 records')
    archive = OUT / 'retired-records.tar.gz'
    with tarfile.open(archive, 'x:gz', dereference=False) as tar:
        for name in records:
            tar.add(ROOT / name, arcname=name, recursive=False)
    manifest = dict(files=records, archiveSHA256=sha(archive), fullHistoryBackup=False)
    save('records-manifest.json', manifest)
    verify_archive(manifest)
    return manifest


def verify_archive(manifest):
    archive = OUT / 'retired-records.tar.gz'
    if sha(archive) != manifest['archiveSHA256']:
        raise ValueError('Record archive changed')
    with tarfile.open(archive) as tar:
        names = tar.getnames()
        if len(names) != len(set(names)) or set(names) != set(manifest['files']):
            raise ValueError('Archive record set differs')
        for name, info in manifest['files'].items():
            with tar.extractfile(name) as stream:
                if hashlib.file_digest(stream, 'sha256').hexdigest() != info['sha256']:
                    raise ValueError('Archived record content differs')


def unused():
    images = subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist'])
    (OUT / 'attachments.plist').write_bytes(images)
    for entry in plistlib.loads(images).get('images', []):
        paths = [entry.get('image-path', '')] + [x.get('mount-point', '') for x in entry.get('system-entities', [])]
        if any(value and (Path(value) == VM or VM in Path(value).parents) for value in paths):
            raise ValueError('Regular VM has an image attachment')
    observations = []
    for option, path in [('+d', VM), ('+D', TARGET)]:
        r = subprocess.run(['/usr/sbin/lsof', '-nP', '-F', 'pn', option, str(path)],
                           capture_output=True, text=True, timeout=60)
        observations.append(dict(option=option, path=str(path), code=r.returncode,
                                 stdout=r.stdout, stderr=r.stderr))
        save('open-handles.json', observations)
        if r.returncode not in (0, 1) or r.stderr:
            raise ValueError('Open-handle inspection failed')
        owner = None
        for line in r.stdout.splitlines():
            if line.startswith('p'):
                owner = int(line[1:])
            elif line.startswith('n') and owner != os.getpid():
                raise ValueError('Regular VM is in use: ' + line[1:])


def main():
    if sys.argv[1:] not in ([], ['--apply'], ['--verify']):
        raise ValueError('Use no argument, --apply, or --verify')
    OUT.mkdir(exist_ok=True)
    mode = sys.argv[1:] and sys.argv[1]
    if mode == '--verify':
        plan = json.loads((OUT / 'plan.json').read_text())
        result = json.loads((OUT / 'result.json').read_text())
        if result['state'] != 'completed' or os.path.lexists(TARGET):
            raise ValueError('Retirement not complete')
        if protected() != plan['protected'] or references() != plan['references']:
            raise ValueError('Protected state differs')
        verify_archive(json.loads((OUT / 'records-manifest.json').read_text()))
        record = dict(time=datetime.datetime.now(datetime.timezone.utc).isoformat(), historyAbsent=True,
                      protectedRecordsCompared=len(plan['protected']), archivedRecordsVerified=47,
                      currentDiskFullHashBeforeEqualsAfter=result['currentDiskSHA256'] == plan['currentDiskSHA256'],
                      freeBytesNow=shutil.disk_usage(ROOT).free)
        save('independent-verification.json', record)
        print(json.dumps(record))
        return
    if (OUT / 'result.json').exists():
        raise ValueError('Execution recorded; do not repeat')
    handles = []
    try:
        for p in (VM, VM / 'Disk.img', TARGET):
            fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW)
            handles.append(fd)
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        safety.processes('before')
        unused()
        if subprocess.check_output(['git', 'ls-files', '-z', '--', str(TARGET.relative_to(ROOT))], cwd=ROOT):
            raise ValueError('Git-tracked history')
        items = inventory()
        current = protected()
        refs = references()
        if not mode:
            if (OUT / 'plan.json').exists():
                raise ValueError('Preparation already recorded')
            print('Archiving 47 records', flush=True)
            manifest = archive_records(items)
            print('Reading complete current regular disk', flush=True)
            disk_hash = sha(VM / 'Disk.img', progress=True)
            if protected() != current or inventory() != items:
                raise ValueError('Inputs changed during preparation')
            plan = dict(time=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                        authorization='Current chat: 清理T32的历史内容', target=str(TARGET.relative_to(ROOT)),
                        transactions=list(IDS), allocatedBytes=sum(x['blocks'] * 512 for x in items.values()),
                        protected=current, references=refs, currentDiskSHA256=disk_hash,
                        archivedRecords=len(manifest['files']), scriptSHA256=sha(Path(__file__)),
                        effect='Full regular CFW Receipt/Undo/identity-history capability retired; current disk retained')
            (OUT / 'inventory.json.gz').write_bytes(gzip.compress(json.dumps(items).encode(), mtime=0))
            save('plan.json', plan)
            print(json.dumps(dict(state='prepared', allocatedGiB=plan['allocatedBytes'] / 1024**3,
                                  archivedRecords=plan['archivedRecords'], currentDiskSHA256=disk_hash)))
            return
        plan = json.loads((OUT / 'plan.json').read_text())
        old_items = json.loads(gzip.decompress((OUT / 'inventory.json.gz').read_bytes()))
        if (plan['target'] != str(TARGET.relative_to(ROOT)) or plan['transactions'] != list(IDS)
                or plan['scriptSHA256'] != sha(Path(__file__)) or items != old_items
                or current != plan['protected'] or refs != plan['references']):
            raise ValueError('Prepared scope or inputs changed')
        verify_archive(json.loads((OUT / 'records-manifest.json').read_text()))
        safety.processes('immediately-before')
        unused()
        if inventory() != items or protected() != current:
            raise ValueError('Inputs changed before removal')
        if not shutil.rmtree.avoids_symlink_attacks:
            raise ValueError('Descriptor-based removal required')
        free_before = shutil.disk_usage(ROOT).free
        result = dict(state='in_progress', target=plan['target'], allocatedBytes=plan['allocatedBytes'],
                      freeBytesBefore=free_before)
        save('result.json', result)
        print('Removing only approved regular CFW history', flush=True)
        shutil.rmtree(TARGET)
        if os.path.lexists(TARGET):
            raise ValueError('History remains')
        after = protected()
        save('protected-after.json', after)
        if after != current or references() != refs:
            raise ValueError('Protected state differs after retirement')
        print('Verifying complete current regular disk after removal', flush=True)
        disk_hash = sha(VM / 'Disk.img', progress=True)
        if disk_hash != plan['currentDiskSHA256'] or protected() != current:
            raise ValueError('Current regular disk changed')
        verify_archive(json.loads((OUT / 'records-manifest.json').read_text()))
        save('retirement.json', dict(time=datetime.datetime.now(datetime.timezone.utc).isoformat(),
             target=plan['target'], transactions=list(IDS), retiredCapabilities=plan['effect'],
             originalPlanAndHistoricalEvidenceUnchanged=True, references=refs,
             archive='retired-records.tar.gz', fullDiskOrBlobBackup=False))
        result.update(state='completed', historyAbsent=True, protectedUnchanged=True,
                      currentDiskSHA256=disk_hash, freeBytesAfter=shutil.disk_usage(ROOT).free)
        result['freeBytesIncrease'] = result['freeBytesAfter'] - free_before
        save('result.json', result)
        print(json.dumps(result))
    finally:
        for fd in handles:
            os.close(fd)


if __name__ == '__main__':
    main()
