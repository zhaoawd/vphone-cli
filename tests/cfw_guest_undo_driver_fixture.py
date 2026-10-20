"""APFS command replacement for the actual host Undo driver regression.

The filesystem is a disposable directory. Only APFS attachment/mount syscalls
are replaced; Python plan, Undo, journal, receipt and origin code run normally.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'scripts'))
from patchers import final_guest, plan_gate
import cfw_disk_txn

STATE = Path(os.environ['TEST_UNDO_STATE'])
FILESYSTEM = Path(os.environ['TEST_UNDO_FILESYSTEM'])
MOUNTS = Path(os.environ['TEST_MOUNTS'])


def state():
    return json.loads(STATE.read_bytes())


def save(value):
    STATE.write_text(json.dumps(value))
    MOUNTS.write_text('/dev/disk42s1 on '+value['root']+' (apfs, local)\n' if value.get('mounted') else '')


def mount(readonly):
    value = state(); root = Path(value['root'])
    root.mkdir(parents=True, exist_ok=True)
    shutil.copytree(FILESYSTEM, root, dirs_exist_ok=True, copy_function=shutil.copy2)
    value.update(mounted=True, readonly=readonly); save(value)


def unmount():
    value = state(); root = Path(value['root'])
    if value['mounted'] and not value['readonly']:
        shutil.rmtree(FILESYSTEM)
        shutil.copytree(root, FILESYSTEM, copy_function=shutil.copy2)
        target = root/'System/Cryptexes/OS/System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64e'
        Path(value['image']).write_bytes(target.read_bytes())
    if root.exists(): shutil.rmtree(root)
    root.mkdir(parents=True)
    value['mounted'] = False; save(value)


def query(args, **kwargs):
    value = state()
    if args[0] == '/usr/bin/hdiutil':
        return plistlib.dumps({'images':[{'image-path':value['image'], 'system-entities':[
            {'dev-entry':'/dev/disk41','content-hint':'GUID_partition_scheme'}]}]})
    if args[0] == '/usr/sbin/diskutil':
        if args[1:3] == ['apfs','list']:
            return plistlib.dumps({'Containers':[{'ContainerReference':'disk42',
                'PhysicalStores':[{'DeviceIdentifier':'disk41s1'}],
                'Volumes':[{'DeviceIdentifier':'disk42s1','MountPoint':value['root'] if value['mounted'] else 'Not Mounted'}]}]})
        return plistlib.dumps({'ReadOnlyVolume':value['readonly'],'DeviceIdentifier':'disk42s1',
                              'MountPoint':value['root']})
    return REAL_OUTPUT(args, **kwargs)


def run(args, **kwargs):
    if args[0] == '/sbin/umount':
        unmount(); return SimpleNamespace(returncode=0)
    if args[0] == '/sbin/mount_apfs':
        mount('rdonly' in args); return SimpleNamespace(returncode=0)
    return REAL_RUN(args, **kwargs)


REAL_RUN, REAL_OUTPUT = subprocess.run, subprocess.check_output


def tool(name, args):
    if name == 'hdiutil' and args[0] == 'attach':
        value = dict(image=args[-1], root=str(Path(os.environ['CFW_HOST_MNT'])/'mnt1'), mounted=False, readonly=False)
        save(value); mount('-readonly' in args)
        sys.stdout.buffer.write(plistlib.dumps({'system-entities':[
            {'dev-entry':'/dev/disk41','content-hint':'GUID_partition_scheme'}, {'dev-entry':'/dev/disk41s1'}]}))
    elif name == 'diskutil' and args[0] == 'info':
        sys.stdout.buffer.write(plistlib.dumps({'APFSContainerReference':'disk42'}))
    elif name == 'diskutil' and args[0] == 'apfs':
        print('APFS Volume Disk (Role): disk42s1 (System)\nName: System (Case-sensitive)')
    elif name == 'umount': unmount()
    elif name == 'hdiutil' and args[0] == 'detach':
        value = state(); value['mounted'] = False; save(value)
    else: raise ValueError('unexpected fixture tool: '+name+' '+str(args))


def main():
    if sys.argv[1] == 'tool': tool(sys.argv[2],sys.argv[3:]); return 0
    args = sys.argv[2:]
    if args[0] == '-c' or args[0].endswith('vm_lock.py'):
        os.execv(sys.executable,[sys.executable]+args)
    subprocess.run, subprocess.check_output = run, query
    if args[0].endswith('cfw_disk_txn.py'): return cfw_disk_txn.main(args[1:])
    if args[0].endswith('plan_gate.py'):
        sys.argv = args; plan_gate.main(); return 0
    raise ValueError('unexpected fixture Python invocation: '+str(args))


if __name__ == '__main__': sys.exit(main())
