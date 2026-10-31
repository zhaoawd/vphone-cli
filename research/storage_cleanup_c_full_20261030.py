"""Retire the entire remaining old DSC VM directory approved in this chat."""

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

import storage_cleanup_c_20261030 as previous

ROOT = previous.ROOT
VM = previous.VM
ROM = previous.ROM
OUT = ROOT / 'research/evidence/storage-cleanup-c-full-20261030'
COPIED_ROM = OUT / 'retained-inputs/AVPBooter.vresearch1.bin'
safety = previous.safety
safety.OUT = OUT
safety.DIRECTORIES = [str(VM.relative_to(ROOT))]
safety.FILES = []
safety.TARGETS = [VM]


def inventory():
    if VM.resolve(strict=True) != VM or not VM.is_dir() or not os.access(ROOT, os.W_OK | os.X_OK):
        raise ValueError('Unexpected or unwritable VM directory')
    result = {str(VM.relative_to(ROOT)): safety.metadata(VM)}
    def fail(error):
        raise error
    for parent, dirs, files in os.walk(VM, followlinks=False, onerror=fail):
        if os.path.ismount(parent) or not os.access(parent, os.W_OK | os.X_OK):
            raise ValueError('Mounted or unwritable directory: ' + parent)
        for name in dirs + files:
            path = Path(parent) / name
            if path.is_symlink():
                raise ValueError('Linked object requires review: ' + str(path))
            result[str(path.relative_to(ROOT))] = safety.metadata(path)
    return result


def retained():
    prior = json.loads((previous.OUT / 'protected-after.json').read_text())
    result = {}
    prefix = str(VM.relative_to(ROOT))
    for name, template in prior.items():
        if name == prefix or name.startswith(prefix + '/'):
            continue
        path = ROOT / name
        info = safety.metadata(path)
        row = {key: info[key] for key in template if key not in ['sha256', 'hashRead']}
        if 'sha256' in template:
            row['sha256'] = previous.previous.sha(path)
        if 'hashRead' in template:
            try:
                row['sha256'] = previous.previous.sha(path)
            except PermissionError:
                row['hashRead'] = 'permission denied'
        result[name] = row
    result[str(COPIED_ROM.relative_to(ROOT))] = dict(safety.metadata(COPIED_ROM), sha256=previous.previous.sha(COPIED_ROM))
    return result


def references():
    plan = json.loads(safety.PLAN.read_text())
    rows = []
    prefix = str(VM.relative_to(ROOT))
    def walk(value, location=''):
        if isinstance(value, str) and prefix in value:
            rows.append(dict(location=location, value=value))
        elif isinstance(value, list):
            for index, child in enumerate(value):
                walk(child, location + '/' + str(index))
        elif isinstance(value, dict):
            for key, child in value.items():
                if prefix in key:
                    rows.append(dict(location=location + '/KEY', value=key))
                walk(child, location + '/' + key)
    walk(plan)
    expected = [dict(location='/unrelatedDiskIdentities/KEY', value=prefix + '/Disk.img'),
                dict(location='/frozenInputs/KEY', value=str(ROM))]
    if rows != expected:
        raise ValueError('VM has different direct references; inspect before deleting')
    return dict(originalPlanSHA256=previous.previous.sha(safety.PLAN), directReferences=rows,
                originalROM=str(ROM.relative_to(ROOT)), originalROMSHA256=plan['frozenInputs'][str(ROM)],
                futureInput=str(COPIED_ROM.relative_to(ROOT)))


def preserve_rom(reference):
    if previous.previous.sha(ROM) != reference['originalROMSHA256']:
        raise ValueError('Referenced original ROM changed')
    COPIED_ROM.parent.mkdir(exist_ok=True)
    if not COPIED_ROM.exists():
        with ROM.open('rb') as source, COPIED_ROM.open('xb') as destination:
            shutil.copyfileobj(source, destination)
            destination.flush()
            os.fsync(destination.fileno())
    if previous.previous.sha(COPIED_ROM) != reference['originalROMSHA256']:
        raise ValueError('Archived ROM differs')
    safety.save('retained-input.json', dict(originalPath=str(ROM.relative_to(ROOT)),
                originalMetadata=safety.metadata(ROM), archivePath=str(COPIED_ROM.relative_to(ROOT)),
                archiveMetadata=safety.metadata(COPIED_ROM), sha256=reference['originalROMSHA256'],
                policy='Byte-identical future input archive; original inode/path identity is retired. Original frozen plan is not modified.'))


def archive_small_records(state):
    records = {name: dict(info, sha256=previous.previous.sha(ROOT / name)) for name, info in state.items()
               if stat.S_ISREG(info['mode']) and info['size'] <= 8 * 1024**2
               and Path(name).suffix.lower() in ['.json', '.plist', '.txt', '.shsh', '.xml', '.log']}
    path = OUT / 'retired-small-records.tar.gz'
    if not path.exists():
        with tarfile.open(path, 'x:gz', dereference=False) as tar:
            for name in records:
                tar.add(ROOT / name, arcname=name, recursive=False)
    with tarfile.open(path) as tar:
        if set(tar.getnames()) != set(records):
            raise ValueError('Small-record archive members differ')
        for name, info in records.items():
            with tar.extractfile(name) as stream:
                if hashlib.file_digest(stream, 'sha256').hexdigest() != info['sha256']:
                    raise ValueError('Small-record archive digest differs')
    safety.save('small-records-manifest.json', dict(files=records, archiveSHA256=previous.previous.sha(path)))
    return len(records)


def main():
    if sys.argv[1:] not in [[], ['--apply']]:
        raise ValueError('Use no argument or --apply')
    OUT.mkdir(exist_ok=True)
    if (OUT / 'result.json').exists():
        raise ValueError('Execution recorded; do not repeat')
    handles = []
    try:
        safety.processes('before')
        reference = references()
        fd = os.open(VM, os.O_RDONLY | os.O_NOFOLLOW)
        handles.append(fd)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        state = inventory()
        run = subprocess.run(['/usr/sbin/lsof', '-nP', '-F', 'pn', '+D', str(VM)],
                             capture_output=True, text=True, timeout=45)
        safety.save('open-handles.json', dict(code=run.returncode, stdout=run.stdout, stderr=run.stderr))
        if run.returncode not in [0, 1] or run.stderr:
            raise ValueError('lsof failed')
        owner = None
        for line in run.stdout.splitlines():
            if line.startswith('p'):
                owner = int(line[1:])
            elif line.startswith('n') and owner != os.getpid():
                raise ValueError('Old VM in use: ' + line[1:])
        images = subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist'])
        (OUT / 'attachments.plist').write_bytes(images)
        for row in plistlib.loads(images).get('images', []):
            image = Path(row.get('image-path', '/nonexistent')).resolve()
            if image == VM or VM in image.parents:
                raise ValueError('Old VM image attached')
        tracked = subprocess.check_output(['git', 'ls-files', '-z', '--', str(VM.relative_to(ROOT))], cwd=ROOT)
        if tracked:
            raise ValueError('Tracked data inside old VM directory')
        preserve_rom(reference)
        archived = archive_small_records(state)
        protected = retained()
        allocated = sum(info['blocks'] * 512 for info in state.values())
        safety.save('plan.json', dict(time=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    authorization='Current chat: 完全清理c', target=str(VM.relative_to(ROOT)),
                    references=reference, protected=protected, allocatedBytes=allocated, archivedSmallRecords=archived))
        (OUT / 'inventory.json.gz').write_bytes(gzip.compress(json.dumps(state).encode(), mtime=0))
        if not sys.argv[1:]:
            print(json.dumps(dict(state='prepared', allocatedBytes=allocated,
                                  inventoryEntries=len(state), archivedSmallRecords=archived, retainedROMBytes=COPIED_ROM.stat().st_size)))
            return
        safety.processes('immediately-before')
        if inventory() != state or references() != reference or retained() != protected:
            raise ValueError('Deletion or protected state changed')
        before = shutil.disk_usage(ROOT).free
        result = dict(state='in_progress', target=str(VM.relative_to(ROOT)), freeBytesBefore=before, allocatedBytes=allocated)
        safety.save('result.json', result)
        shutil.rmtree(VM)
        if os.path.lexists(VM):
            raise ValueError('Old VM directory remains')
        for handle in handles:
            os.close(handle)
        handles.clear()
        after = retained()
        safety.save('protected-after.json', after)
        if after != protected or references() != reference:
            raise ValueError('Protected state changed; inspect evidence')
        safety.processes('after')
        result.update(state='completed', entireVMDirectoryAbsent=True, protectedUnchanged=True,
                      archivedROMVerified=True, originalPlanUnchanged=True,
                      originalROMPathRetired=True, freeBytesAfter=shutil.disk_usage(ROOT).free)
        result['freeBytesIncrease'] = result['freeBytesAfter'] - before
        safety.save('result.json', result)
        safety.save('retirement.json', dict(retiredDirectory=str(VM.relative_to(ROOT)), **reference,
                    originalPlanModified=False, originalFrozenPathsUnavailable=True, VMStarts=0))
        print(json.dumps(result, ensure_ascii=False))
    finally:
        for handle in handles:
            os.close(handle)


if __name__ == '__main__':
    main()
