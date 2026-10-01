"""Test-only entry for scripts/cfw_env_update.py on a tar-backed disk image.

The test disk image is an uncompressed tar of a guest system volume. "Mounting"
extracts it into the mountpoint and adds a line to the mount table the driver
tests read ($TEST_MOUNTS); "unmounting" writes a read-write mount back into the
attached image in place (same inode) and empties the mountpoint. The production
script carries no test hooks; this wrapper replaces its functions.

Usage:
  cfw_env_update_harness.py SCRIPT ARGS...   run SCRIPT's main with doubles
  cfw_env_update_harness.py umount MOUNTPOINT

CFW_ENV_FAULTS (comma list): replace-second (the second library replacement
fails with EIO, after the first one was written).
"""
import errno
import importlib.util
import io
import os
from pathlib import Path
import shutil
import sys
import tarfile


def log(line):
    path = os.environ.get('TEST_LOG')
    if path:
        with open(path, 'a') as stream:
            stream.write(line + '\n')


def mount_table():
    return Path(os.environ['TEST_MOUNTS'])


def attached_image():
    return Path((str(mount_table()) + '.attached')).read_text().strip()


def extract(image, mountpoint):
    with tarfile.open(image) as archive:
        archive.extractall(mountpoint, filter='tar')


def pack(mountpoint, image):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w', format=tarfile.PAX_FORMAT) as archive:
        for entry in sorted(Path(mountpoint).iterdir()):
            archive.add(entry, arcname=entry.name)
    with open(image, 'r+b') as stream:  # in place: the staged image keeps its inode
        stream.truncate(0)
        stream.write(buffer.getvalue())


def umount(mountpoint):
    table = mount_table()
    lines = table.read_text().splitlines(True) if table.exists() else []
    match = [line for line in lines if f' on {mountpoint} (' in line]
    if match and 'read-only' not in match[0]:
        pack(mountpoint, attached_image())
        log(f'harness packed {mountpoint}')
    table.write_text(''.join(line for line in lines if line not in match))
    for entry in Path(mountpoint).iterdir():
        if entry.is_dir() and not entry.is_symlink():
            shutil.rmtree(entry)
        else:
            entry.unlink()
    return 0


def load(script):
    spec = importlib.util.spec_from_file_location('cfw_env_update', script)
    module = importlib.util.module_from_spec(spec)
    sys.modules['cfw_env_update'] = module
    spec.loader.exec_module(module)
    return module


def install_doubles(env):
    faults = set(filter(None, os.environ.get('CFW_ENV_FAULTS', '').split(',')))

    def mount_volume(device, mountpoint, readonly=False):
        log(f'harness mount {"ro" if readonly else "rw"} {device} {mountpoint}')
        Path(mountpoint).mkdir(parents=True, exist_ok=True)
        extract(attached_image(), mountpoint)
        flags = 'apfs, local, read-only' if readonly else 'apfs, local'
        with open(mount_table(), 'a') as stream:
            stream.write(f'{device} on {mountpoint} ({flags})\n')

    env.mount_volume = mount_volume
    if 'replace-second' in faults:
        real = env.replace_file
        calls = []

        def replace(source, target):
            calls.append(target)
            if len(calls) == 2:
                raise OSError(errno.EIO, os.strerror(errno.EIO))
            return real(source, target)
        env.replace_file = replace


if __name__ == '__main__':
    if sys.argv[1] == 'umount':
        sys.exit(umount(sys.argv[2]))
    module = load(sys.argv[1])
    install_doubles(module)
    sys.exit(module.main(sys.argv[2:]))
