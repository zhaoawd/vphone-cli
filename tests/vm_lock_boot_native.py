"""Opt-in signed CLI lock check; deliberately supplies no bootable manifest."""
import fcntl
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    binary = ROOT / '.build/release/vphone-cli'
    with tempfile.TemporaryDirectory(prefix='vphone-lock-native-') as temp:
        directory = Path(temp).resolve()
        if '--ad-hoc-copy' in sys.argv:
            copied = directory / 'vphone-cli-test'
            shutil.copyfile(binary, copied)
            copied.chmod(0o755)
            subprocess.run(['codesign', '--remove-signature', str(copied)], check=True, capture_output=True)
            subprocess.run(['codesign', '--force', '--sign', '-', str(copied)], check=True, capture_output=True)
            binary = copied
            print('Test uses a temporary ad-hoc copy without private entitlements')
        command = [str(binary), 'boot', '--headless', '--config', str(directory / 'absent-config.plist')]
        fd = os.open(directory, os.O_RDONLY)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            blocked = subprocess.run(command, capture_output=True, text=True, timeout=20)
            assert blocked.returncode != 0
            assert 'VM lock unavailable' in blocked.stdout + blocked.stderr, (blocked.returncode, blocked.stdout, blocked.stderr)
            assert not (directory / '.vphone-runtime.json').exists()
            fcntl.flock(fd, fcntl.LOCK_UN)
            failed_boot = subprocess.run(command, capture_output=True, text=True, timeout=20)
            assert failed_boot.returncode != 0  # no manifest exists; no VM can start
            record = json.loads((directory / '.vphone-runtime.json').read_text())
            assert record['operation'] == 'boot'
            assert 'VM lock acquired' in failed_boot.stdout
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            print('PASS: boot rejects occupied VM before manifest access; failed boot releases lock')
        finally:
            os.close(fd)


if __name__ == '__main__':
    main()
