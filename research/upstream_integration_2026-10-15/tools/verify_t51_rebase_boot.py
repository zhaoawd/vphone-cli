#!/usr/bin/env python3
"""Boot the selected T51 rebase target twice without daemon updates.

Uses the signed VM executable and production vm-stop path. Guest requests read
capabilities, SystemVersion.plist and kern.boottime only. This establishes a boot
baseline, not successful guest Undo or firmware migration.
"""
import argparse
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'scripts'))
from host_control_client import endpoint, request


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


class Recorder:
    def __init__(self, path):
        self.path = path

    def record(self, target, payload, response):
        with self.path.open('a') as stream:
            stream.write(json.dumps(dict(time=time.time(), request=payload, response=response), sort_keys=True) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vm', type=Path, required=True)
    parser.add_argument('--vm-executable', type=Path, required=True)
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--api', action='store_true', help='enable the current classic guest API for snapshot and shutdown')
    parser.add_argument('--ready-hold-seconds', type=int, default=35)
    args = parser.parse_args()
    if not 0 <= args.ready_hold_seconds <= 60: parser.error('ready hold must be 0...60 seconds')
    vm, binary, cli, out = args.vm.resolve(strict=True), args.vm_executable.resolve(strict=True), args.cli.resolve(strict=True), args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, VPHONE_ROOT=str(out / 'user-root'), VPHONE_PYTHON=str(REPO / '.venv/bin/python3'))
    if args.api: env['VPHONE_API_TOKEN'] = secrets.token_urlsafe(32)
    preserved = {name: hashlib.sha256((vm / name).read_bytes()).hexdigest()
                 for name in ('config.plist', '.vphoned.signed')}
    result = dict(schemaVersion=1, scope='api-two-boot-baseline' if args.api else 'legacy-two-boot-baseline', vm=str(vm),
                  positiveUndoValidated=False, daemonUpdateRequested=False, cycles=[], state='running')
    write(out / 'runtime-result.json', result)
    try:
        for cycle in (1, 2):
            run = out / f'boot-{cycle}'
            run.mkdir()
            recorder = Recorder(run / 'requests.jsonl')
            command = [str(binary), '--config', str(vm / 'config.plist'), '--headless', '--no-vphoned-update']
            if args.api: command += ['--api-listen', '127.0.0.1:0']
            info = dict(cycle=cycle, argv=command, connected=False)
            result['cycles'].append(info)
            with (run / 'serial.log').open('wb') as log:
                child = subprocess.Popen(command, cwd=vm, env=env, stdout=log, stderr=subprocess.STDOUT)
                info['pid'] = child.pid
                try:
                    deadline, last = time.monotonic() + 180, None
                    while time.monotonic() < deadline:
                        if child.poll() is not None:
                            raise RuntimeError(f'VM exited before guest connection: {child.returncode}')
                        try:
                            target = endpoint(vm.name, vm / 'vphone.sock')
                            caps = request(target, dict(t='capabilities'), recorder, 5)
                            last = caps
                            if (caps.get('ok') is True and caps.get('guest_connected') is True
                                    and (not args.api or {'device.snapshot', 'system.shutdown'}.issubset(caps.get('rpc_methods', [])))):
                                break
                        except (OSError, RuntimeError) as error:
                            last = str(error)
                        time.sleep(1)
                    else:
                        raise RuntimeError(f'Guest connection deadline: {last}')
                    runtime = json.loads((vm / '.vphone-runtime.json').read_text())
                    write(run / 'runtime.json', runtime)
                    assert runtime['pid'] == child.pid and runtime['operation'] == 'boot'
                    assert Path(runtime['bundlePath']) == vm
                    assert caps['boot_mode'] == 'normal'
                    info['connected'] = True
                    write(run / 'capabilities.json', caps)
                    if args.api:
                        boot = request(target, dict(t='rpc', method='device.snapshot', params={}), recorder, 15)
                        write(run / 'boottime.json', boot)
                        assert boot.get('ok') is True, boot
                        snapshot = boot['result']
                        assert isinstance(snapshot['boot_time'], (int, float)) and snapshot['boot_time'] > 0, boot
                        assert isinstance(snapshot['boot_session_uuid'], str) and snapshot['boot_session_uuid'], boot
                        info['bootSeconds'] = snapshot['boot_time']
                        info['bootSessionUUID'] = snapshot['boot_session_uuid']
                    else:
                        boot = request(target, dict(t='shell', cmd='if [ -x /usr/sbin/sysctl ]; then /usr/sbin/sysctl -n kern.boottime; else /var/jb/usr/sbin/sysctl -n kern.boottime; fi',
                                                   screen=False, timeout_ms=10000), recorder, 15)
                        write(run / 'boottime.json', boot)
                        assert boot.get('ok') is True and boot.get('code') == 0 and not boot.get('timed_out'), boot
                        match = re.search(r'sec\s*=\s*(\d+)', boot['stdout'])
                        assert match, boot
                        info['bootSeconds'] = int(match.group(1))
                    version = request(target, dict(t='file_get', path='/System/Library/CoreServices/SystemVersion.plist'), recorder, 15)
                    assert version.get('ok') is True, version
                    raw = base64.b64decode(version['data'], validate=True)
                    assert len(raw) == version['size']
                    (run / 'SystemVersion.plist').write_bytes(raw)
                    info['systemVersion'] = plistlib.loads(raw)
                    info['instanceID'] = runtime['instanceID']
                    write(out / 'runtime-result.json', result)
                    print(f'guest ready: cycle={cycle} pid={child.pid}; holding {args.ready_hold_seconds}s for GUI acceptance', flush=True)
                    time.sleep(args.ready_hold_seconds)
                finally:
                    if child.poll() is None:
                        stop = subprocess.run([str(cli), 'vm', 'stop', vm.name, '--library-root', str(vm.parent)],
                                              capture_output=True, text=True, env=env, timeout=50)
                        write(run / 'stop.json', dict(exitCode=stop.returncode, stdout=stop.stdout, stderr=stop.stderr))
                        info['stopExitCode'] = stop.returncode
                    info['vmExitCode'] = child.wait(timeout=10)
            serial = (run / 'serial.log').read_text(errors='replace')
            info['guestStopped'] = 'Guest stopped' in serial
            info['forcedFrameworkStop'] = any(line in serial for line in ('graceful shutdown timed out', 'no graceful shutdown path available', '[vphone] VM stopped'))
            assert info.get('stopExitCode') == 0 and info['vmExitCode'] == 0, info
            assert info['guestStopped'] and not info['forcedFrameworkStop'], info
            disk = subprocess.run(['/usr/sbin/lsof', '-nP', '-t', '--', str(vm / 'Disk.img')], capture_output=True, text=True, timeout=10)
            write(run / 'disk-holders.json', dict(exitCode=disk.returncode, stdout=disk.stdout, stderr=disk.stderr))
            assert disk.returncode == 1 and not disk.stdout and not disk.stderr, 'VM disk not released'
            directory = os.open(vm, os.O_RDONLY | os.O_DIRECTORY)
            try:
                fcntl.flock(directory, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                os.close(directory)
            info['diskReleased'] = True
            write(out / 'runtime-result.json', result)
        assert result['cycles'][0]['instanceID'] != result['cycles'][1]['instanceID']
        assert result['cycles'][0]['bootSeconds'] != result['cycles'][1]['bootSeconds']
        if args.api: assert result['cycles'][0]['bootSessionUUID'] != result['cycles'][1]['bootSessionUUID']
        assert all(hashlib.sha256((vm / name).read_bytes()).hexdigest() == digest for name, digest in preserved.items())
        result.update(state='passed', configAndStagedDaemonUnchanged=True, distinctBootTimes=True)
    except Exception as error:
        result.update(state='failed', error=f'{type(error).__name__}: {error}')
        raise
    finally:
        write(out / 'runtime-result.json', result)
    print(json.dumps(result, sort_keys=True))


if __name__ == '__main__':
    main()
