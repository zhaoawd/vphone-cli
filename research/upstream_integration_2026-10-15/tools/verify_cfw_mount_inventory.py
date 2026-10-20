#!/usr/bin/env python3
"""Native APFS mount regression on an exclusive clone; never writes the source."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'scripts'))
from cfw_disk_txn import clone_file
from patchers import final_guest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True)
    parser.add_argument('--writable-remount', action='store_true')
    parser.add_argument('--snapshot-flip', action='store_true',
                        help='Run the production offline snapshot rename before readonly attachment')
    args = parser.parse_args()
    if args.snapshot_flip and args.writable_remount:
        parser.error('--snapshot-flip requires the readonly attachment scenario')
    source, work = args.source.resolve(strict=True), args.work.resolve()
    if ROOT / '.build' not in work.parents:
        raise ValueError('diagnostic work must be inside repository .build')
    work.mkdir(parents=True, exist_ok=False)
    image = work / 'Disk.img'
    before = source.stat()
    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        clone_file(fd, image)
    finally:
        os.close(fd)
    if (image.stat().st_dev,image.stat().st_ino) == (before.st_dev,before.st_ino):
        raise ValueError('diagnostic image must be an independent inode')
    result = dict(schemaVersion=1, source=str(source), clone=str(image),
        scope='native isolated clone; plan private-path boundary replaced, all mount queries real',
        phases=[], state='running')
    def save():
        (work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    save()
    device = None
    try:
        if args.snapshot_flip:
            flipped = subprocess.run([sys.executable, str(ROOT/'tools/apfs_snap_rename.py'), str(image)],
                                     capture_output=True, text=True)
            result['snapshotFlip'] = dict(exitCode=flipped.returncode,
                                         stdout=flipped.stdout, stderr=flipped.stderr)
            save()
            if flipped.returncode or 'done: root snapshot renamed' not in flipped.stdout:
                raise ValueError('diagnostic clone has no completed root snapshot rename')
        argv = ['/usr/bin/hdiutil','attach','-nomount','-plist']
        if not args.writable_remount: argv.append('-readonly')
        raw = subprocess.check_output(argv + [str(image)])
        (work / 'attachment.plist').write_bytes(raw)
        bases = [e['dev-entry'] for e in plistlib.loads(raw)['system-entities']
                 if e.get('content-hint') == 'GUID_partition_scheme']
        if len(bases) != 1: raise ValueError('diagnostic has no unique physical disk')
        device = bases[0]
        with patch.dict(os.environ, CFW_HOST_MNT=str(work)), \
             patch.object(final_guest.gate,'private_path',side_effect=lambda plan,p:Path(p).resolve()):
            for readonly in ([False, True] if args.writable_remount else [True]):
                roots, container, _ = final_guest.mount_roots(SimpleNamespace(),image,
                    {'system','hardware'},read_only=readonly)
                observations = {}
                for name in ['system','hardware']:
                    expected = container['ContainerReference'] + final_guest.VOLUMES[name][1]
                    info = final_guest.require_mount(roots[name],expected,readonly)
                    observations[name] = {k:info.get(k) for k in
                        ['DeviceIdentifier','MountPoint','Mounted','WritableVolume','ReadOnlyVolume']}
                    try: final_guest.require_mount(roots[name],expected,not readonly)
                    except ValueError: pass
                    else: raise AssertionError('opposite mount state was accepted')
                result['phases'].append(dict(readOnly=readonly,volumes=observations,
                    inventoryMountpoints={v['DeviceIdentifier']:v.get('MountPoint') for v in container['Volumes']}))
                save()
        after = source.stat()
        if any(getattr(before,k) != getattr(after,k) for k in ['st_dev','st_ino','st_size','st_mtime_ns']):
            raise ValueError('source identity changed during isolated regression')
        result.update(state='passed',sourceIdentityUnchanged=True)
    except BaseException as error:
        result.update(state='failed',error=f'{type(error).__name__}: {error}')
        raise
    finally:
        if device:
            detached = subprocess.run(['/usr/bin/hdiutil','detach',device],capture_output=True,text=True)
            result['cleanup'] = dict(exitCode=detached.returncode,stdout=detached.stdout,stderr=detached.stderr)
            if detached.returncode:
                result['state'] = 'failed'
        save()
    if result['state'] != 'passed': raise RuntimeError('native regression or cleanup failed')
    print(json.dumps(result),flush=True)


if __name__ == '__main__':
    main()
