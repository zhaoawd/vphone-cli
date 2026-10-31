"""Retire only the two approved C objects; preserve generation and ROM inputs."""

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

import storage_cleanup_ab_20261030 as previous

safety = previous.safety
ROOT = safety.ROOT
OUT = ROOT / 'research/evidence/storage-cleanup-c-20261030'
VM = ROOT / 'vm-t32-t33-dsc-20261018'
NAMES = ['vm-t32-t33-dsc-20261018/Disk.img',
         'vm-t32-t33-dsc-20261018/iPhone17,3_26.0_23A341_Restore']
TARGETS = [ROOT / name for name in NAMES]
ROM = VM / '.firmware-generations/6ebc5f6705cf0bffb32da62bf3006cc7ece5027edee4306abc8031aee9f4bb42/originals/AVPBooter.vresearch1.bin'
safety.OUT = OUT
safety.DIRECTORIES = [NAMES[1]]
safety.FILES = [NAMES[0]]
safety.TARGETS = TARGETS


def retained():
    result = previous.retained()
    for name in list(result):
        if any(name == target or name.startswith(target + '/') for target in NAMES):
            del result[name]
    # Removing two children necessarily changes the parent directory metadata.
    result[str(VM.relative_to(ROOT))] = {
        key: value for key, value in safety.metadata(VM).items() if key in ['dev', 'ino', 'mode']}
    result[str(ROM.relative_to(ROOT))]['sha256'] = previous.sha(ROM)
    return result


def inventory():
    for path in TARGETS:
        if path.resolve(strict=True) != path:
            raise ValueError('Unexpected cleanup path')
    disk = safety.metadata(TARGETS[0])
    if not stat.S_ISREG(disk['mode']) or disk['nlink'] != 1 or not os.access(VM, os.W_OK | os.X_OK):
        raise ValueError('Unexpected or unwritable disk target')
    result = {NAMES[0]: disk}
    result.update(previous.inventory(TARGETS[1]))
    return result


def references():
    data = json.loads(safety.PLAN.read_text())
    strings = []
    def walk(value, location=''):
        if isinstance(value, str):
            strings.append((location, value))
        elif isinstance(value, list):
            for index, child in enumerate(value):
                walk(child, location + '/' + str(index))
        elif isinstance(value, dict):
            for key, child in value.items():
                strings.append((location + '/KEY', key))
                walk(child, location + '/' + key)
    walk(data)
    hits = [dict(location=location, value=value) for location, value in strings
            if any(value in [name, str(ROOT / name)] or name + '/' in value for name in NAMES)]
    if hits != [dict(location='/unrelatedDiskIdentities/KEY', value=NAMES[0])]:
        raise ValueError('Different retirement references; inspect before deleting')
    if str(ROM) not in data['frozenInputs'] or previous.sha(ROM) != data['frozenInputs'][str(ROM)]:
        raise ValueError('Referenced original ROM changed')
    return dict(originalPlanSHA256=previous.sha(safety.PLAN), directReferences=hits,
                retiredDiskIdentity=data['unrelatedDiskIdentities'][NAMES[0]],
                retainedROM=str(ROM.relative_to(ROOT)), retainedROMSHA256=previous.sha(ROM),
                policy='Retain the original plan; its retired disk check can no longer pass. Future plans need an explicit retirement exception.')


def archive_records(before_inventory):
    paths = set()
    for name, info in before_inventory.items():
        if (stat.S_ISREG(info['mode']) and info['size'] <= 8 * 1024**2
                and Path(name).suffix.lower() in ['.json', '.plist', '.txt', '.shsh', '.xml']):
            paths.add(name)
    for path in VM.iterdir():
        if path.is_file() and path.suffix.lower() in ['.json', '.plist', '.txt', '.shsh']:
            paths.add(str(path.relative_to(ROOT)))
    records = {name: dict(safety.metadata(ROOT / name), sha256=previous.sha(ROOT / name)) for name in sorted(paths)}
    archive = OUT / 'retired-small-records.tar.gz'
    if not archive.exists():
        with tarfile.open(archive, 'x:gz', dereference=False) as tar:
            for name in records:
                tar.add(ROOT / name, arcname=name, recursive=False)
    with tarfile.open(archive) as tar:
        if set(tar.getnames()) != set(records):
            raise ValueError('Different archive members')
        for name, info in records.items():
            with tar.extractfile(name) as stream:
                if hashlib.file_digest(stream, 'sha256').hexdigest() != info['sha256']:
                    raise ValueError('Archive digest differs')
    safety.save('small-records-manifest.json', dict(files=records, archiveSHA256=previous.sha(archive)))
    return len(records)


def main():
    if sys.argv[1:] not in [[], ['--apply']]:
        raise ValueError('Use no argument or --apply')
    OUT.mkdir(exist_ok=True)
    if (OUT / 'result.json').exists():
        raise ValueError('Execution recorded; do not repeat')
    review = json.loads((previous.REVIEW / 'assessment.json').read_text())
    if NAMES != [row['path'] for row in review['targets'] if row['group'] == 'C']:
        raise ValueError('Approved C scope differs')
    handles = []
    try:
        safety.processes('before')
        reference_state = references()
        for path in [VM, *TARGETS]:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
            handles.append(fd)
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        before_inventory = inventory()
        opened = []
        for path in [VM, *TARGETS]:
            command = ['/usr/sbin/lsof', '-nP', '-F', 'pn'] + (['+D'] if path.is_dir() else ['--']) + [str(path)]
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
                    raise ValueError('Old VM in use: ' + line[1:])
        safety.save('open-handles.json', opened)
        images = subprocess.check_output(['/usr/bin/hdiutil', 'info', '-plist'])
        (OUT / 'attachments.plist').write_bytes(images)
        for row in plistlib.loads(images).get('images', []):
            image = Path(row.get('image-path', '/nonexistent')).resolve()
            if image == VM or VM in image.parents:
                raise ValueError('Old VM image attached')
        if subprocess.check_output(['git', 'ls-files', '-z', '--', *NAMES], cwd=ROOT):
            raise ValueError('Tracked cleanup target')
        protected = retained()
        archive_count = archive_records(before_inventory)
        allocated = sum(info['blocks'] * 512 for info in before_inventory.values())
        plan = dict(time=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    authorization='Current chat: 清理c这块', targets=NAMES, protected=protected,
                    references=reference_state, allocatedBytes=allocated, archivedSmallRecords=archive_count)
        safety.save('plan.json', plan)
        (OUT / 'inventory.json.gz').write_bytes(gzip.compress(json.dumps(before_inventory).encode(), mtime=0))
        if not sys.argv[1:]:
            print(json.dumps(dict(state='prepared', targets=2, allocatedBytes=allocated, archivedSmallRecords=archive_count)))
            return
        safety.processes('immediately-before')
        if inventory() != before_inventory or references() != reference_state or retained() != protected:
            raise ValueError('Cleanup or retained state changed')
        free_before = shutil.disk_usage(ROOT).free
        result = dict(state='in_progress', removed=[], freeBytesBefore=free_before, allocatedBytes=allocated)
        safety.save('result.json', result)
        for path in TARGETS:
            if safety.metadata(path) != before_inventory[str(path.relative_to(ROOT))]:
                raise ValueError('Cleanup target changed')
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()
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
        if after != protected or references() != reference_state:
            raise ValueError('Retained state changed; inspect evidence')
        safety.processes('after')
        result.update(state='completed', allTargetsAbsent=all(not os.path.lexists(p) for p in TARGETS),
                      protectedUnchanged=True, originalROMUnchanged=True, originalPlanUnchanged=True,
                      oldVMCanBoot=False, retiredDiskCheckCanPass=False,
                      freeBytesAfter=shutil.disk_usage(ROOT).free)
        result['freeBytesIncrease'] = result['freeBytesAfter'] - free_before
        safety.save('result.json', result)
        safety.save('retirement.json', dict(time=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    retired=NAMES, **reference_state, originalPlanModified=False, VMStarts=0))
        print(json.dumps(result, ensure_ascii=False))
    finally:
        for fd in handles:
            os.close(fd)


if __name__ == '__main__':
    main()
