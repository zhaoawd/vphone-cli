#!/usr/bin/env python3
"""Restore the fresh T32/T33 DSC VM using the production DFU/restore commands."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
CDHASH = 'cad3fa35fa16672ad522b31564352ffd4276b469'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vm-executable', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    vm = ROOT / 'vm-t32-t33-dsc-20261018'
    binary, out = args.vm_executable.resolve(strict=True), args.out.resolve()
    cli = ROOT / '.build/vphone-cli.app/Contents/MacOS/vphone-cli'
    if any((vm / name).exists() for name in ('.firmware-transaction', '.cfw-history',
            'restore-info.json', 'udid-prediction.txt')):
        raise ValueError('requires the fresh patched DSC VM, without restore/runtime history')
    runtime = vm / '.vphone-runtime.json'
    if runtime.exists() and json.loads(runtime.read_bytes()).get('operation') in ('boot', 'dfu'):
        raise ValueError('fresh DSC VM must not have a prior boot/DFU record')
    histories = list((vm / '.firmware-history').iterdir())
    if len(histories) != 1:
        raise ValueError('expected exactly one committed firmware transaction')
    journal = json.loads((histories[0] / 'journal.json').read_bytes())
    if journal.get('phase') != 'committed' or journal.get('options', {}).get('variant') != 'regular':
        raise ValueError('firmware transaction is not a committed regular build')
    signature = subprocess.run(['/usr/bin/codesign', '-d', '--verbose=4', str(binary)],
                               capture_output=True, text=True, check=True)
    if not re.search(r'^CDHash=' + CDHASH + r'$', signature.stderr, re.M):
        raise ValueError('VM executable does not have the explicitly approved CDHash')
    subprocess.run([str(binary), '--help'], check=True, capture_output=True)
    out.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, VPHONE_ROOT=str(ROOT / '.build/t32-t33-runtime-20261018'),
               VPHONE_PYTHON=str(ROOT / '.venv/bin/python3'), PYTHONDONTWRITEBYTECODE='1')
    result = dict(schemaVersion=1, vm=str(vm), binary=str(binary), cdhash=CDHASH,
                  state='running', steps=[], firmwareTransaction=histories[0].name)
    def save():
        (out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    def run_step(name, command, timeout):
        with (out / (name + '.log')).open('wb') as log:
            code = subprocess.run(command, cwd=vm, env=env, stdout=log,
                                  stderr=subprocess.STDOUT, timeout=timeout).returncode
        result['steps'].append(dict(name=name, argv=command, exitCode=code)); save()
        if code:
            raise RuntimeError(f'{name} exited {code}')
    save()
    child = None
    try:
        with (out / 'dfu.log').open('wb') as log:
            child = subprocess.Popen([str(binary), '--config', str(vm / 'config.plist'),
                '--dfu', '--headless', '--no-vphoned-update'], cwd=vm, env=env,
                stdout=log, stderr=subprocess.STDOUT)
            result['dfuPID'] = child.pid; save()
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                if child.poll() is not None:
                    raise RuntimeError(f'DFU process exited {child.returncode}')
                state = json.loads(runtime.read_bytes()) if runtime.exists() else {}
                if (state.get('pid') == child.pid and state.get('operation') == 'dfu'
                        and state.get('bundlePath') == str(vm)
                        and (vm / 'udid-prediction.txt').exists()):
                    (out / 'dfu-runtime.json').write_text(json.dumps(state, indent=2) + '\n')
                    break
                time.sleep(1)
            else:
                raise RuntimeError('DFU lock/device identity deadline')
            identity = dict(line.split('=', 1) for line in (vm / 'udid-prediction.txt').read_text().splitlines() if '=' in line)
            udid = identity['UDID'].upper()
            ecid = identity['ECID'].removeprefix('0x').upper()
            if not re.fullmatch(r'[0-9A-F]{8}-[0-9A-F]{16}', udid) or udid.split('-')[1] != ecid:
                raise ValueError('UDID/ECID mismatch')
            result.update(udid=udid, ecid=ecid); save()
            bridge = ROOT / 'scripts/pymobiledevice3_bridge.py'
            for _ in range(90):
                if child.poll() is not None:
                    raise RuntimeError('DFU process exited before recovery endpoint')
                probe = subprocess.run([str(ROOT / '.venv/bin/python3'), str(bridge),
                    'recovery-probe', '--ecid', '0x' + ecid, '--timeout', '2'],
                    env=env, capture_output=True, timeout=15)
                if probe.returncode == 0:
                    break
                time.sleep(2)
            else:
                raise RuntimeError('recovery endpoint deadline')
            command = [str(cli), 'restore', vm.name, '--library-root', str(ROOT),
                       '--udid', udid, '--ecid', '0x' + ecid, '-v']
            run_step('shsh', command + ['--get-shsh'], 300)
            run_step('restore', command, 1200)
            deadline = time.monotonic() + 30
            while child.poll() is None and time.monotonic() < deadline:
                if re.search('panic', (out / 'dfu.log').read_text(errors='replace'), re.I):
                    result['postRestorePanicMarker'] = True
                    break
                time.sleep(1)
            result['state'] = 'restored'
    except BaseException as error:
        result.update(state='failed', error=f'{type(error).__name__}: {error}')
        raise
    finally:
        if child is not None:
            if child.poll() is None:
                child.send_signal(signal.SIGINT)
            try:
                result['dfuExitCode'] = child.wait(timeout=60)
            except subprocess.TimeoutExpired:
                result.update(state='failed', stopError='DFU did not exit within 60 seconds; retain process for inspection')
                save()
                raise
        save()
    holders = subprocess.run(['/usr/sbin/lsof', '-nP', '-t', '--', str(vm / 'Disk.img')],
                             capture_output=True, text=True, timeout=15)
    (out / 'disk-holders.json').write_text(json.dumps(dict(exitCode=holders.returncode,
        stdout=holders.stdout, stderr=holders.stderr), indent=2) + '\n')
    if holders.returncode != 1 or holders.stdout or holders.stderr:
        result.update(state='failed', error='restored disk still has holders or holder query failed')
        save()
        raise RuntimeError(result['error'])
    directory = os.open(vm, os.O_RDONLY | os.O_DIRECTORY)
    try:
        fcntl.flock(directory, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as error:
        result.update(state='failed', error=f'bundle lock not released: {error}')
        save()
        raise
    finally:
        os.close(directory)
    result['diskReleased'] = True
    save()
    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    main()
