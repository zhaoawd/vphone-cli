"""Opt-in native mount cleanup check; creates only disposable APFS images."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs)


def main():
    driver = (ROOT / 'scripts/cfw_install_host.sh').read_text()
    # Exercise the exact production cleanup and traps, without installing CFW.
    cleanup = driver[driver.index('cleanup() {'):driver.index('echo "[*] host-mode')]
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
            print('PASS: native APFS cleanup; other task remains mounted; failure status 37 preserved')
        finally:
            for mount in mounts:
                if f' on {mount} (' in run('/sbin/mount').stdout:
                    run('hdiutil', 'detach', str(mount))


if __name__ == '__main__':
    main()
