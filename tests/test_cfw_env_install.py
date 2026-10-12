"""Offline v2 install on disposable synthetic System directory trees."""
import errno
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from tests.test_cfw_env_update import LOCAL, make_bundle, make_stage, make_system, macho, sha, tree, LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, EnvironmentDriverFixture, tar_of, tree_of_tar

ROOT = Path(__file__).resolve().parents[1]


def load_installer():
    sys.path.insert(0, str(ROOT / 'scripts'))
    try:
        spec = importlib.util.spec_from_file_location('cfw_env_install_test', ROOT / 'scripts/cfw_env_install.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        sys.path.pop(0)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='v2 install ')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.vm = make_bundle(self.base / 'vm', variant='regular', checkpoint_variant='regular')
        checkpoint = self.vm / '.create-checkpoint/checkpoint.json'
        checkpoint.write_text(json.dumps({'effective_options': {'variant': 'regular', 'guest_environment': 'v2'}}))
        self.system = make_system(self.vm / 'mount', omit=LOCAL, alias=None, launchd_loads=())
        self.stage = make_stage(self.base / 'components')
        self.daemon = self.base / 'daemon'
        self.daemon.mkdir()
        overlays = json.loads((ROOT / 'dependencies/daemon-api-overlays/manifest.json').read_text())['overlays']
        marker = 'VPHONE_DAEMON_OVERLAYS:' + sha(json.dumps(overlays, sort_keys=True, separators=(',', ':')).encode())
        (self.daemon / 'vphoned').write_bytes(macho(filetype=2, tag=b'api') + marker.encode())
        (self.daemon / 'vphoned').chmod(0o755)
        config = ROOT / 'sources/VPhoneDaemon/Configuration'
        shutil.copyfile(config / 'vphoned-api.plist', self.daemon / 'vphoned-api.plist')
        shutil.copyfile(config / 'VPhoneDaemon.entitlements', self.daemon / 'vphoned.entitlements.plist')
        (self.daemon / 'manifest.json').write_text(json.dumps({'schema_version': 1,
            'pins': json.loads((ROOT / 'dependencies/daemon-api-pins.json').read_text())['pins'],
            'source_overlays': overlays,
            'files_sha256': {p.name: sha(p.read_bytes()) for p in self.daemon.iterdir()}}))
        (self.vm / 'cfw_input').mkdir()
        (self.vm / 'cfw_input/signcert.p12').write_bytes(b'test certificate')
        self.report = self.vm / 'report.json'
        self.calls = []
        self.installer = load_installer()

    def runner(self, args):
        self.calls.append(args)
        stdout = b''
        if '-e' in args:
            stdout = plistlib.dumps({'original-entitlement': True})
        elif 'inject-dylib' in args:
            path = Path(args[-2])
            path.write_bytes(macho([(LC_LOAD_DYLIB, '/usr/lib/libSystem.B.dylib'),
                                   (LC_LOAD_WEAK_DYLIB, '/vh')], filetype=2, tag=b'injected'))
        return subprocess.CompletedProcess(args, 0, stdout, b'')

    def install(self):
        return self.installer.install_mounted(self.system, self.vm, self.stage, self.daemon, self.report,
            variant='regular', owner=(os.getuid(), os.getgid()), runner=self.runner)

    def test_install_writes_only_profile_files_and_assesses_already_current(self):
        before = tree(self.system)
        launchd_backup = (self.system / 'sbin/launchd').read_bytes()
        plist_backup = (self.system / 'System/Library/xpc/launchd.plist.bak').read_bytes()
        self.assertEqual(self.install(), 0)
        report = json.loads(self.report.read_text())
        self.assertEqual(report['result'], 'installed')
        self.assertEqual(report['assessment_after']['classification'], 'already_current')
        for entry in json.loads((ROOT / 'scripts/guest_environment.json').read_text())['libraries']:
            path = self.system / entry['guest']
            self.assertEqual(path.read_bytes(), (self.stage / entry['stage']).read_bytes())
            self.assertEqual(path.stat().st_mode & 0o7777, 0o755)
            self.assertEqual((path.stat().st_uid, path.stat().st_gid), (os.getuid(), os.getgid()))
        self.assertEqual(os.readlink(self.system / 'vh'), '/usr/lib/launchdhook-vphone.dylib')
        self.assertEqual((self.system / 'sbin/launchd.bak').read_bytes(), launchd_backup)
        self.assertEqual((self.system / 'System/Library/xpc/launchd.plist.bak').read_bytes(), plist_backup)
        self.assertEqual((self.system / 'usr/bin/vphoned').read_bytes(), b'vphoned')
        self.assertEqual((self.system / 'usr/bin/vphoned-api').read_bytes(), (self.daemon / 'vphoned').read_bytes())
        key = '/System/Library/LaunchDaemons/vphoned-api.plist'
        plist = plistlib.loads((self.system / 'System/Library/xpc/launchd.plist').read_bytes())
        self.assertIn(key, plist['LaunchDaemons'])
        self.assertEqual(plist['LaunchDaemons'][key]['Label'], 'com.vphone.vphoned.api')
        self.assertFalse((self.system / 'usr/lib/libmisfix.dylib').exists())
        after = tree(self.system)
        changed = {name for name in before.keys() | after.keys() if before.get(name) != after.get(name)}
        allowed = {'vh', 'sbin/launchd', 'sbin/launchd.bak', 'usr/bin/vphoned-api',
                   'System/Library/LaunchDaemons', 'System/Library/LaunchDaemons/vphoned-api.plist',
                   'System/Library/xpc/launchd.plist'} | {'usr/lib/' + name for name in LOCAL}
        self.assertEqual(changed, allowed)
        self.assertEqual(report['launchd']['entitlements_sha256_before'], report['launchd']['entitlements_sha256_after'])

    def test_existing_different_library_refuses_without_writing_any_system_file(self):
        (self.system / 'usr/lib/libcamfix.dylib').write_bytes(macho(tag=b'existing different library'))
        before = tree(self.system)
        self.assertEqual(self.install(), 3)
        self.assertEqual(tree(self.system), before)
        self.assertEqual(self.calls, [])
        self.assertEqual(json.loads(self.report.read_text())['result'], 'refused')

    def test_missing_completed_cfw_marker_refuses_without_writes(self):
        (self.system / 'System/Library/xpc/launchd.plist.bak').unlink()
        before = tree(self.system)
        self.assertEqual(self.install(), 3)
        self.assertEqual(tree(self.system), before)
        self.assertEqual(self.calls, [])

    def test_outdated_api_pins_overlays_and_binary_marker_refuse_before_writes(self):
        record = self.daemon / 'manifest.json'
        original = json.loads(record.read_text())
        binary = self.daemon / 'vphoned'
        contents = binary.read_bytes()
        for invalid in ('pins', 'source_overlays', 'binary_marker'):
            with self.subTest(invalid=invalid):
                manifest = json.loads(json.dumps(original))
                if invalid == 'binary_marker':
                    binary.write_bytes(macho(filetype=2, tag=b'old-api'))
                    manifest['files_sha256']['vphoned'] = sha(binary.read_bytes())
                else:
                    manifest[invalid] = []
                record.write_text(json.dumps(manifest))
                before = tree(self.system)
                self.assertEqual(self.install(), 3)
                self.assertEqual(tree(self.system), before)
                self.assertEqual(self.calls, [])
                binary.write_bytes(contents)
                record.write_text(json.dumps(original))

    def test_reinstall_restores_daemon_entry_without_reinjecting_launchd_or_changing_backups(self):
        self.assertEqual(self.install(), 0)
        launchd = (self.system / 'sbin/launchd').read_bytes()
        backup = (self.system / 'sbin/launchd.bak').read_bytes()
        plist_backup = (self.system / 'System/Library/xpc/launchd.plist.bak').read_bytes()
        (self.system / 'System/Library/xpc/launchd.plist').write_bytes(plist_backup)
        self.calls.clear()
        self.assertEqual(self.install(), 0)
        self.assertFalse(any('inject-dylib' in args or any(arg.startswith('-S') for arg in args) for args in self.calls))
        self.assertEqual((self.system / 'sbin/launchd').read_bytes(), launchd)
        self.assertEqual((self.system / 'sbin/launchd.bak').read_bytes(), backup)
        self.assertEqual((self.system / 'System/Library/xpc/launchd.plist.bak').read_bytes(), plist_backup)
        self.assertEqual(json.loads(self.report.read_text())['launchd']['result'], 'unchanged')

    def test_second_library_write_failure_records_failed(self):
        write = self.installer.atomic_write
        def failing_write(target, data, mode, owner):
            if target.name == 'SystemHook-vphone.dylib':
                raise OSError(errno.EIO, 'injected second library failure')
            return write(target, data, mode, owner)
        with patch.object(self.installer, 'atomic_write', side_effect=failing_write):
            self.assertEqual(self.install(), 1)
        report = json.loads(self.report.read_text())
        self.assertEqual(report['result'], 'failed')
        self.assertIn('second library failure', report['error'])
        self.assertEqual([row['path'] for row in report['files']], ['/usr/lib/launchdhook-vphone.dylib'])

    def test_classic_unknown_and_conflicting_aliases_refuse_without_writes(self):
        for index, options in enumerate(({'classic': True, 'launchd_loads': ('/b',)},
                                         {'launchd_loads': ('/unknown',)},
                                         {'alias': '/usr/lib/other.dylib'},
                                         {'classic': True, 'alias': '/usr/lib/launchdhook-vphone.dylib', 'launchd_loads': ('/b', '/vh')})):
            with self.subTest(options=options):
                self.system = make_system(self.vm / f'system-{index}', omit=LOCAL, alias=None, launchd_loads=())
                # Replace the bootstrap fixtures, keeping all other input files unchanged.
                if options.get('classic'):
                    (self.system / 'b').write_bytes(macho(tag=b'basebin'))
                if options.get('alias'):
                    os.symlink(options['alias'], self.system / 'vh')
                loads = options.get('launchd_loads', ())
                (self.system / 'sbin/launchd').write_bytes(macho([(LC_LOAD_DYLIB, '/usr/lib/libSystem.B.dylib')] +
                    [(LC_LOAD_WEAK_DYLIB, name) for name in loads], filetype=2))
                before = tree(self.system)
                self.calls.clear()
                self.assertEqual(self.install(), 3)
                self.assertEqual(tree(self.system), before)
                self.assertEqual(self.calls, [])

    def test_invalid_candidate_hash_signature_and_daemon_refuse_without_writes(self):
        inputs = ((self.stage / 'camfix/libcamfix.dylib', b'wrong hash'),
                  (self.daemon / 'vphoned', b'wrong daemon'))
        for path, data in inputs:
            with self.subTest(path=path):
                original = path.read_bytes()
                path.write_bytes(data)
                before = tree(self.system)
                self.assertEqual(self.install(), 3)
                self.assertEqual(tree(self.system), before)
                self.assertEqual(self.calls, [])
                path.write_bytes(original)
        path = self.stage / 'camfix/libcamfix.dylib'
        path.write_bytes(macho(signed=False))
        record = self.stage / 'manifest.json'
        obj = json.loads(record.read_text())
        obj['files_sha256']['camfix/libcamfix.dylib'] = sha(path.read_bytes())
        record.write_text(json.dumps(obj))
        before = tree(self.system)
        self.assertEqual(self.install(), 3)
        self.assertEqual(tree(self.system), before)
        self.assertIn('no code signature', json.loads(self.report.read_text())['error'])

    def test_single_daemon_command_preserves_unrelated_entries(self):
        target = self.system / 'System/Library/xpc/launchd.plist'
        before = plistlib.loads(target.read_bytes())
        proc = subprocess.run([sys.executable, str(ROOT / 'scripts/patchers/cfw.py'), 'inject-daemon',
                               str(target), str(self.daemon / 'vphoned-api.plist'),
                               '/System/Library/LaunchDaemons/vphoned-api.plist'],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        after = plistlib.loads(target.read_bytes())
        self.assertEqual(after['LaunchDaemons']['vphoned'], before['LaunchDaemons']['vphoned'])
        self.assertEqual(len(after['LaunchDaemons']), len(before['LaunchDaemons']) + 1)
        self.assertEqual(after['LaunchDaemons']['/System/Library/LaunchDaemons/vphoned-api.plist']['Label'],
                         'com.vphone.vphoned.api')

    @unittest.skipUnless((ROOT / '.tools/bin/insert_dylib').is_file() and sys.platform == 'darwin',
                         'macOS and insert_dylib required')
    def test_real_insert_dylib_adds_weak_alias_to_compiled_host_binary(self):
        source = self.base / 'main.c'
        source.write_text('int main(void) { return 0; }\n')
        binary = self.base / 'test-launchd'
        subprocess.run(['/usr/bin/clang', str(source), '-o', str(binary)], check=True, capture_output=True)
        proc = subprocess.run([sys.executable, str(ROOT / 'scripts/patchers/cfw.py'), 'inject-dylib', str(binary), '/vh'],
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        loads = self.installer.environment.dylib_loads(binary)
        self.assertEqual(loads.count('/vh'), 1)
        commands = list(self.installer.environment.macho_commands(binary.read_bytes()))
        self.assertTrue(any(cmd == LC_LOAD_WEAK_DYLIB and b'/vh\0' in payload for cmd, payload in commands))

    def test_signing_entitlement_change_fails_before_launchd_publication(self):
        original = (self.system / 'sbin/launchd').read_bytes()
        runner = self.runner
        def changed_entitlements(args):
            result = runner(args)
            if '-e' in args and Path(args[-1]).parent.name.startswith('.vphone-launchd-'):
                result.stdout = plistlib.dumps({'changed-entitlement': True})
            return result
        with patch.object(self, 'runner', side_effect=changed_entitlements):
            self.assertEqual(self.install(), 1)
        self.assertEqual((self.system / 'sbin/launchd').read_bytes(), original)
        self.assertIn('entitlements changed', json.loads(self.report.read_text())['error'])

    def test_unmount_failure_marks_report_failed(self):
        install = self.installer.install_mounted
        def local_install(*args, **kwargs):
            return install(*args, **kwargs, owner=(os.getuid(), os.getgid()), runner=self.runner)
        args = ['install', str(self.vm), '--device', '/dev/test', '--mount', str(self.system),
                '--components', str(self.stage), '--daemon', str(self.daemon), '--report', str(self.report)]
        error = self.installer.environment.DiskAccess('unmount', 'test unmount failed')
        with patch.object(self.installer.environment, 'mount_volume'), \
                patch.object(self.installer.environment, 'unmount', side_effect=error), \
                patch.object(self.installer, 'install_mounted', side_effect=local_install):
            with self.assertRaises(self.installer.environment.DiskAccess):
                self.installer.main(args)
        record = json.loads(self.report.read_text())
        self.assertEqual(record['result'], 'failed')
        self.assertIn('unmount', record['error'])


class V2DriverTests(EnvironmentDriverFixture):
    def setUp(self):
        super().setUp()
        shutil.copyfile(ROOT / 'scripts/cfw_env_install.py', self.root / 'scripts/cfw_env_install.py')
        (self.root / 'dependencies').mkdir()
        shutil.copyfile(ROOT / 'dependencies/daemon-api-pins.json', self.root / 'dependencies/daemon-api-pins.json')
        stub = self.root / '.tools/bin/stub'
        text = stub.read_text().replace('[[ "$1" == */cfw_env_update.py ]]',
                                       '[[ "$1" == */cfw_env_update.py || "$1" == */cfw_env_install.py ]]')
        text = '\n'.join('   if [[ "$1" == */apfs_snap_rename.py ]]; then [[ ${FAIL_SNAP:-0} == 1 ]] && exit 5; exit 0; fi'
                         if 'if [[ "$1" == */apfs_snap_rename.py ]]' in line else line for line in text.splitlines()) + '\n'
        stub.write_text(text)
        (self.root / 'scripts/cfw_install.sh').write_text('#!/bin/zsh\nprint classic-installer >> "$TEST_LOG"\n')
        self.daemon = self.root / 'daemon'
        self.daemon.mkdir()
        overlays = json.loads((ROOT / 'dependencies/daemon-api-overlays/manifest.json').read_text())['overlays']
        marker = 'VPHONE_DAEMON_OVERLAYS:' + sha(json.dumps(overlays, sort_keys=True, separators=(',', ':')).encode())
        (self.daemon / 'vphoned').write_bytes(macho(filetype=2, tag=b'api') + marker.encode())
        (self.daemon / 'vphoned').chmod(0o755)
        config = ROOT / 'sources/VPhoneDaemon/Configuration'
        shutil.copyfile(config / 'vphoned-api.plist', self.daemon / 'vphoned-api.plist')
        shutil.copyfile(config / 'VPhoneDaemon.entitlements', self.daemon / 'vphoned.entitlements.plist')
        (self.daemon / 'manifest.json').write_text(json.dumps({'schema_version': 1,
            'pins': json.loads((ROOT / 'dependencies/daemon-api-pins.json').read_text())['pins'],
            'source_overlays': overlays,
            'files_sha256': {p.name: sha(p.read_bytes()) for p in self.daemon.iterdir()}}))
        self.env['VPHONE_API_DAEMON'] = str(self.daemon)

    def new_vm(self):
        vm = make_bundle(self.root / 'vm', variant='regular', checkpoint_variant='regular')
        (vm / '.create-checkpoint/checkpoint.json').write_text(json.dumps({'effective_options':
            {'variant': 'regular', 'guest_environment': 'v2'}}))
        system = make_system(self.root / 'system', omit=LOCAL, alias=None, launchd_loads=())
        (vm / 'Disk.img').write_bytes(tar_of(system))
        (vm / 'cfw_input').mkdir()
        (vm / 'cfw_input/signcert.p12').write_bytes(b'test certificate')
        return vm, tree(system)

    def run_install(self, vm, args=None, **env):
        return subprocess.run(['/bin/zsh', str(self.driver), *(args or ['--variant', 'regular', '--guest-environment', 'v2']),
                               str(vm)], env=dict(self.env, TEST_MOUNTS=str(vm / 'mount-table'), **env),
                              capture_output=True, text=True, timeout=60)

    def test_v2_install_publishes_one_transaction_and_preserves_previous_disk(self):
        vm, previous = self.new_vm()
        original = (vm / 'Disk.img').read_bytes()
        result = self.run_install(vm)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        history = list(vm.glob('.cfw-history/*'))
        self.assertEqual(len(history), 1)
        self.assertEqual((history[0] / 'Disk.img').read_bytes(), original)
        report = json.loads((history[0] / 'guest-environment-install.json').read_text())
        transaction = json.loads((history[0] / 'transaction.json').read_text())
        self.assertEqual(report['result'], 'installed')
        self.assertEqual(report['transaction_id'], transaction['id'])
        self.assertEqual(report['assessment_after']['classification'], 'already_current')
        after = tree_of_tar((vm / 'Disk.img').read_bytes(), self.scratch)
        self.assertEqual(after['usr/lib/libcamfix.dylib'][1], sha((self.stage / 'camfix/libcamfix.dylib').read_bytes()))
        self.assertEqual(after['usr/bin/vphoned'], previous['usr/bin/vphoned'])
        calls = (self.root / 'calls').read_text().splitlines()
        self.assertEqual(sum('apfs_snap_rename.py' in line for line in calls), 1)
        self.assertEqual(sum(line == 'classic-installer' for line in calls), 1)

    def test_recorded_v2_install_without_opt_in_refuses_before_tools(self):
        vm, _ = self.new_vm()
        info = vm / 'restore-info.json'
        document = json.loads(info.read_text())
        document['guest_environment'] = 'v2'
        info.write_text(json.dumps(document))
        original = (vm / 'Disk.img').read_bytes()
        result = self.run_install(vm, args=['--variant', 'regular'])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('--guest-environment v2', result.stderr)
        self.assertFalse((self.root / 'calls').exists())
        self.assertEqual((vm / 'Disk.img').read_bytes(), original)

    def test_failed_v2_install_keeps_original_inode_bytes_and_mtime(self):
        vm, _ = self.new_vm()
        disk = vm / 'Disk.img'
        original = (disk.stat().st_ino, disk.stat().st_mtime_ns, sha(disk.read_bytes()))
        result = self.run_install(vm, CFW_ENV_FAULTS='install-second')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual((disk.stat().st_ino, disk.stat().st_mtime_ns, sha(disk.read_bytes())), original)
        self.assertFalse(list(vm.glob('.cfw-history/*/Disk.img')))
        report = json.loads(next(vm.glob('.cfw-history/*/guest-environment-install.json')).read_text())
        self.assertEqual(report['result'], 'failed')
        self.assertNotIn('apfs_snap_rename.py', (self.root / 'calls').read_text())

    def test_unsupported_v2_variants_and_modes_refuse_without_tools(self):
        vm, _ = self.new_vm()
        cases = [['--variant', variant, '--guest-environment', 'v2'] for variant in ('dev', 'jb', 'exp', 'less')]
        cases += [['--update-environment', '--guest-environment', 'v2'], ['--variant', 'regular', '--guest-environment', 'other']]
        for args in cases:
            with self.subTest(args=args):
                result = self.run_install(vm, args=args)
                self.assertEqual(result.returncode, 1)
                self.assertFalse((self.root / 'calls').exists())
                self.assertFalse((vm / '.cfw-history').exists())

    def test_classic_install_does_not_call_environment_installer(self):
        vm, _ = self.new_vm()
        result = self.run_install(vm, args=['--variant', 'regular'])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = (self.root / 'calls').read_text()
        self.assertNotIn('cfw_env_install.py', calls)
        self.assertNotIn('guest-environment-install.json', calls)
        self.assertEqual(sum('apfs_snap_rename.py' in line for line in calls.splitlines()), 1)
