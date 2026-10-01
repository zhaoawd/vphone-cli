"""Opt-in native check of the T16 environment update on a disposable APFS image.

Builds a 64 MiB raw disk image (GPT + case-sensitive APFS volume "System") with
hdiutil, fills the volume with the synthetic guest layout of
tests/test_cfw_env_update.py (two libraries older than the candidates), then
runs, without root and with the real hdiutil/diskutil/mount_apfs:

  1. cfw_env_update.py check-vm: offline_update, Disk.img unchanged;
  2. a copy of cfw_install_host.sh --update-environment with only its sudo
     re-exec disabled (as the driver tests do): publishes the staged copy;
  3. check-vm again: already_current; the previous disk in .cfw-history keeps
     the original SHA-256 and inode;
  4. check-vm --report (the form cfw_install_host.sh --check-environment uses
     as root): the result file says already_current, mode 0600, this user.

Never touches a VM directory; everything lives in one temporary directory.
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_cfw_env_update as fixtures  # noqa: E402


def run(*args, check=True, **kwargs):
    result = subprocess.run(args, capture_output=True, text=True, **kwargs)
    if check and result.returncode != 0:
        raise RuntimeError(f'{" ".join(map(str, args))} -> {result.returncode}\n{result.stdout}\n{result.stderr}')
    return result


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def attach(image, readonly=False):
    args = ['hdiutil', 'attach', '-nomount', '-plist', '-imagekey', 'diskimage-class=CRawDiskImage', str(image)]
    if readonly:
        args.insert(2, '-readonly')
    entities = plistlib.loads(run(*args).stdout.encode())['system-entities']
    base = next(e['dev-entry'] for e in entities if e.get('content-hint') == 'GUID_partition_scheme')
    volume = next(e['dev-entry'] for e in entities if e.get('content-hint') == '41504653-0000-11AA-AA11-00306543ECAC')
    return base, volume


def build_image(temp):
    run('hdiutil', 'create', '-size', '64m', '-layout', 'GPTSPUD', '-fs', 'Case-sensitive APFS',
        '-volname', 'System', '-type', 'UDIF', str(temp / 'seed.dmg'))
    run('hdiutil', 'convert', str(temp / 'seed.dmg'), '-format', 'UDTO', '-o', str(temp / 'seed'))
    vm = fixtures.make_bundle(temp / 'vm')
    shutil.move(temp / 'seed.cdr', vm / 'Disk.img')
    versions = {name: 'v2' for name in fixtures.LOCAL}
    versions['libcamfix.dylib'] = 'v1'
    versions['launchdhook-vphone.dylib'] = 'v1'
    source = fixtures.make_system(temp / 'source', versions)
    base, volume = attach(vm / 'Disk.img')
    mount = temp / 'fill'
    mount.mkdir()
    try:
        run('/sbin/mount_apfs', '-o', 'rw,nobrowse', volume, str(mount))
        try:
            run('/bin/cp', '-Rp', f'{source}/.', str(mount))
        finally:
            run('/sbin/umount', str(mount))
    finally:
        run('hdiutil', 'detach', base)
    return vm


def check(vm, stage):
    result = run(sys.executable, str(ROOT / 'scripts/cfw_env_update.py'), 'check-vm', str(vm),
                 '--components', str(stage))
    return json.loads(result.stdout)


def driver_copy(temp):
    scripts = temp / 'scripts'
    scripts.mkdir()
    for name in ('vm_lock.py', 'cfw_disk_txn.py', 'sparse_file.py', 'cfw_env_update.py',
                 'guest_environment.json'):
        shutil.copyfile(ROOT / 'scripts' / name, scripts / name)
    driver = (ROOT / 'scripts/cfw_install_host.sh').read_text()
    guard = 'if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then'
    assert guard in driver
    (scripts / 'cfw_install_host.sh').write_text(driver.replace(guard, 'if false; then'))
    return scripts / 'cfw_install_host.sh'


def main():
    temp = Path(tempfile.mkdtemp(prefix='cfw-env-native-')).resolve()
    try:
        vm = build_image(temp)
        stage = fixtures.make_stage(temp / 'stage')
        disk = vm / 'Disk.img'
        original = (disk.stat().st_ino, sha256(disk), disk.stat().st_mtime_ns)

        first = check(vm, stage)
        assert first['classification'] == 'offline_update', first
        assert sorted(first['replace']) == ['launchdhook-vphone.dylib', 'libcamfix.dylib'], first['replace']
        assert first['disk']['unchanged'] and first['disk_read'], first['disk']
        assert (disk.stat().st_ino, sha256(disk), disk.stat().st_mtime_ns) == original
        print(f'PASS check-vm (unprivileged, read-only): {first["classification"]} {first["replace"]} '
              f'system={first["system_volume"]}; Disk.img SHA-256, inode and mtime unchanged')

        env = {key: value for key, value in os.environ.items()
               if key not in ('SUDO_UID', 'SUDO_GID', 'SUDO_USER', 'VPHONE_VM_LOCK_FD', 'VPHONE_CFW_LOCK_REEXEC')}
        env.update(VPHONE_PYTHON=sys.executable, VPHONE_GUEST_COMPONENTS=str(stage))
        result = run('/bin/zsh', str(driver_copy(temp)), '--update-environment', str(vm), env=env, check=False)
        print(result.stdout)
        assert result.returncode == 0, result.stderr
        history = list((vm / '.cfw-history').iterdir())
        assert len(history) == 1, history
        retained = history[0] / 'Disk.img'
        assert (retained.stat().st_ino, sha256(retained)) == original[:2]
        report = json.loads((history[0] / 'environment-update.json').read_text())
        assert report['result'] == 'replaced' and report['identity_unchanged'], report
        transaction = json.loads((history[0] / 'transaction.json').read_text())
        print(f'PASS driver: method={transaction["method"]} publish={transaction["publish_method"]} '
              f'replaced={report["replaced"]}; previous disk retained with original SHA-256 and inode')

        second = check(vm, stage)
        assert second['classification'] == 'already_current', second
        print('PASS check-vm after publication: already_current')

        # 4. The result-file form used by the elevated check (here unprivileged).
        caller = temp / 'caller'
        caller.mkdir(mode=0o700)
        report_path = caller / 'report.json'
        run(sys.executable, str(ROOT / 'scripts/cfw_env_update.py'), 'check-vm', str(vm), '--components', str(stage),
            '--report', str(report_path), '--owner', f'{os.getuid()}:{os.getgid()}')
        result = json.loads(report_path.read_text())
        info = report_path.stat()
        assert result['exit_code'] == 0 and result['report']['classification'] == 'already_current', result
        assert (info.st_mode & 0o777, info.st_uid) == (0o600, os.getuid()), info
        print(f'PASS check-vm --report: exit_code 0, already_current, mode 0600, owner uid {info.st_uid}')
        assert f' on {temp}' not in run('/sbin/mount').stdout
    finally:
        info = plistlib.loads(run('hdiutil', 'info', '-plist').stdout.encode())
        for image in info.get('images', []):
            if str(image.get('image-path', '')).startswith(str(temp)):
                for entry in image.get('system-entities', []):
                    if entry.get('content-hint') == 'GUID_partition_scheme':
                        run('hdiutil', 'detach', '-force', entry['dev-entry'], check=False)
        shutil.rmtree(temp, ignore_errors=True)


if __name__ == '__main__':
    main()
