"""Opt-in native mount cleanup check; creates only disposable APFS images."""
import os
import plistlib
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs)


def main():
    driver = (ROOT / 'scripts/cfw_install_host.sh').read_text()
    # Exercise the exact production cleanup and traps, without installing CFW.
    cleanup = driver[driver.index('attached_disk() {'):driver.index('echo "[*] host-mode')]
    with tempfile.TemporaryDirectory(prefix='cfw-native-') as temp:
        root = Path(temp).resolve()
        mounts = []
        try:
            for index in range(2):
                image = root / f'image{index}.dmg'
                run('hdiutil', 'create', '-size', '32m', '-fs', 'APFS', '-volname', f'CFWNative{index}', str(image))
                task = root / f'task{index}'
                mount = task / 'mnt_sysos_hv_vmm'
                mount.mkdir(parents=True)
                run('hdiutil', 'attach', '-nobrowse', '-mountpoint', str(mount), str(image))
                mounts.append(mount)
                (mount / 'sentinel').write_text(str(index))
            for index, code in enumerate((0, 37)):
                result = subprocess.run(['/bin/zsh', '-c', 'set -euo pipefail\nBASEDISK=""\n' + cleanup + f'\nexit {code}\n'],
                                        env=dict(os.environ, CFW_HOST_MNT=str(mounts[index].parent)),
                                        capture_output=True, text=True)
                print(result.stdout, end='')
                assert result.returncode == code, result.stderr
                assert not mounts[index].parent.exists()
                if index == 0:
                    assert (mounts[1] / 'sentinel').read_text() == '1'
                    table = run('/sbin/mount').stdout
                    assert f' on {mounts[1]} (' in table
            task = root / 'nomount-task'
            task.mkdir()
            attached = run('hdiutil', 'attach', '-plist', '-nomount', str(root / 'image0.dmg'))
            (task / 'attach.log').write_text(attached.stdout)
            result = subprocess.run(['/bin/zsh', '-c', 'set -euo pipefail\nBASEDISK=""\n' + cleanup + '\nexit 0\n'],
                                    env=dict(os.environ, CFW_HOST_MNT=str(task), PY=sys.executable),
                                    capture_output=True, text=True)
            assert result.returncode == 0, result.stdout + result.stderr
            assert not task.exists()
            print('PASS: native attach plist identifies and detaches the base disk')
            print('PASS: native APFS cleanup; other task remains mounted; failure status 37 preserved')
        finally:
            for mount in mounts:
                if f' on {mount} (' in run('/sbin/mount').stdout:
                    run('hdiutil', 'detach', str(mount))
            # Also recover an attached-but-unmounted image if an assertion fails.
            info = plistlib.loads(run('hdiutil', 'info', '-plist').stdout.encode())
            for image in info.get('images', []):
                if Path(image.get('image-path', '')).parent == root:
                    for entry in image.get('system-entities', []):
                        if entry.get('content-hint') == 'GUID_partition_scheme':
                            run('hdiutil', 'detach', entry['dev-entry'])


if __name__ == '__main__':
    main()
