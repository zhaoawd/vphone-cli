"""T16 offline environment eligibility and guarded replacement.

Synthetic system volumes are directory trees; the driver tests store one as a
tar file in Disk.img (tests/cfw_env_update_harness.py). No VM disk is used.
"""
import contextlib
import fcntl
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_cfw_host_isolation import HostDriverFixture  # noqa: E402

SCRIPT = ROOT / 'scripts/cfw_env_update.py'
MANIFEST = ROOT / 'scripts/guest_environment.json'

LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_CODE_SIGNATURE = 0x1D
LOCAL = ['launchdhook-vphone.dylib', 'SystemHook-vphone.dylib', 'libvcamcaptured.dylib',
         'libcamfix.dylib', 'libvlocation.dylib']
UPSTREAM_2_2_3 = ['launchdhook-vphone.dylib', 'SystemHook-vphone.dylib', 'libvcamcaptured.dylib',
                  'libcamfix.dylib', 'libmisfix.dylib']


def load_module():
    spec = importlib.util.spec_from_file_location('cfw_env_update_under_test', SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def macho(loads=(), signed=True, tag=b'', filetype=6):
    commands = b''
    for command, name in loads:
        raw = name.encode() + b'\0'
        size = (24 + len(raw) + 7) & ~7
        commands += struct.pack('<6I', command, size, 24, 2, 0x10000, 0x10000) + raw.ljust(size - 24, b'\0')
    count = len(loads)
    if signed:
        commands += struct.pack('<4I', LC_CODE_SIGNATURE, 16, 0, 0)
        count += 1
    header = struct.pack('<IiiIIIII', 0xfeedfacf, 0x0100000C, 2, filetype, count, len(commands), 0, 0)
    return header + commands + tag


def sha(data):
    return hashlib.sha256(data).hexdigest()


def library(name, version):
    return macho(tag=f'{name}:{version}'.encode())


def stage_paths():
    return {entry['name']: entry['stage'] for entry in json.loads(MANIFEST.read_text())['libraries']}


def make_stage(directory, version='v2', overrides=None):
    directory.mkdir(parents=True, exist_ok=True)
    hashes = {}
    for name, relative in stage_paths().items():
        data = (overrides or {}).get(name, library(name, version))
        path = directory / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        hashes[relative] = sha(data)
    (directory / 'manifest.json').write_text(json.dumps({'files_sha256': hashes}))
    return directory


def make_system(root, versions=None, omit=(), marker=True, alias='/usr/lib/launchdhook-vphone.dylib',
                launchd_loads=('/vh',), classic=False, misfix=False):
    """A guest system volume. versions: name -> version tag (default v1)."""
    (root / 'usr/lib').mkdir(parents=True, exist_ok=True)
    for name in LOCAL:
        if name in omit:
            continue
        path = root / 'usr/lib' / name
        path.write_bytes(library(name, (versions or {}).get(name, 'v1')))
        path.chmod(0o755)
    (root / 'usr/lib/libSystem.B.dylib').write_bytes(macho(tag=b'libSystem'))
    (root / 'sbin').mkdir(exist_ok=True)
    loads = [(LC_LOAD_DYLIB, '/usr/lib/libSystem.B.dylib')] + [(LC_LOAD_WEAK_DYLIB, path) for path in launchd_loads]
    (root / 'sbin/launchd').write_bytes(macho(loads, filetype=2, tag=b'launchd'))
    (root / 'sbin/launchd').chmod(0o755)
    xpc = root / 'System/Library/xpc'
    xpc.mkdir(parents=True, exist_ok=True)
    (xpc / 'launchd.plist').write_bytes(plistlib.dumps({'LaunchDaemons': {'vphoned': {}}}))
    if marker:
        (xpc / 'launchd.plist.bak').write_bytes(plistlib.dumps({'LaunchDaemons': {}}))
    if alias:
        os.symlink(alias, root / 'vh')
    if classic:
        (root / 'b').write_bytes(macho(tag=b'basebin launchdhook'))
    if misfix:
        (root / 'usr/lib/libmisfix.dylib').write_bytes(library('libmisfix.dylib', 'upstream'))
        (root / 'usr/lib/libmisfix.plist').write_bytes(plistlib.dumps({}))
    (root / 'usr/bin').mkdir(exist_ok=True)
    (root / 'usr/bin/vphoned').write_bytes(b'vphoned')
    return root


def make_bundle(vm, variant=None, checkpoint_variant=None):
    vm.mkdir(parents=True, exist_ok=True)
    (vm / 'config.plist').write_bytes(plistlib.dumps({
        'machineIdentifier': b'\x01\x02machine', 'nvramStorage': 'nvram.bin', 'sepStorage': 'SEPStorage',
        'diskImage': 'Disk.img'}))
    (vm / 'nvram.bin').write_bytes(b'nvram')
    (vm / 'SEPStorage').write_bytes(b'sep' * 10)
    (vm / '0000000000000001.shsh').write_bytes(b'shsh')
    info = {'ios': {'version': '26.1', 'build': '23B85'}, 'cloudOS': {'version': '26.1', 'build': '23B85'}}
    if variant:
        info['variant'] = variant
    (vm / 'restore-info.json').write_text(json.dumps(info))
    if checkpoint_variant:
        (vm / '.create-checkpoint').mkdir(exist_ok=True)
        (vm / '.create-checkpoint/checkpoint.json').write_text(json.dumps({'variant': checkpoint_variant}))
    return vm


def tree(root):
    """relative path -> (kind, content digest or link target, mode)."""
    result = {}
    for directory, names, files in os.walk(root):
        for name in names + files:
            path = Path(directory) / name
            info = os.lstat(path)
            relative = str(path.relative_to(root))
            if os.path.islink(path):
                result[relative] = ('link', os.readlink(path), None)
            elif path.is_dir():
                result[relative] = ('dir', None, info.st_mode & 0o7777)
            else:
                result[relative] = ('file', sha(path.read_bytes()), info.st_mode & 0o7777)
    return result


def tar_of(root):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w', format=tarfile.PAX_FORMAT) as archive:
        for entry in sorted(root.iterdir()):
            archive.add(entry, arcname=entry.name)
    return buffer.getvalue()


def tree_of_tar(data, scratch):
    target = Path(tempfile.mkdtemp(dir=scratch))
    with tarfile.open(fileobj=io.BytesIO(data)) as archive:
        archive.extractall(target, filter='tar')
    return tree(target)


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='cfw env test ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = load_module()
        self.stage = make_stage(self.root / 'stage')

    def assess(self, system, vm=None):
        vm = vm or make_bundle(self.root / 'vm')
        return self.env.assess(system, vm, self.stage)

    def by_name(self, report):
        return {entry['name']: entry for entry in report['libraries']}


# MARK: - Classification

class AssessTests(Fixture):
    def current_versions(self):
        return {name: 'v2' for name in LOCAL}

    def test_matching_libraries_and_load_paths_are_already_current(self):
        report = self.assess(make_system(self.root / 'sys', self.current_versions()))
        self.assertEqual(report['classification'], 'already_current', report['reasons'])
        self.assertEqual(report['replace'], [])
        for name in LOCAL:
            entry = self.by_name(report)[name]
            self.assertEqual(entry['state'], 'current')
            self.assertEqual(entry['expected_sha256'], entry['actual_sha256'])
            self.assertEqual(entry['guest_path'], f'/usr/lib/{name}')
        self.assertTrue(all(check['ok'] for check in report['load_paths']), report['load_paths'])
        self.assertEqual(report['bootstrap']['kind'], 'v2')

    def test_differing_libraries_are_an_offline_update_of_exactly_those(self):
        versions = self.current_versions()
        versions['libcamfix.dylib'] = 'v1'
        versions['launchdhook-vphone.dylib'] = 'v1'
        report = self.assess(make_system(self.root / 'sys', versions))
        self.assertEqual(report['classification'], 'offline_update', report['reasons'])
        self.assertEqual(sorted(report['replace']), ['launchdhook-vphone.dylib', 'libcamfix.dylib'])
        self.assertEqual(self.by_name(report)['libcamfix.dylib']['state'], 'differs')
        self.assertEqual(self.by_name(report)['libvlocation.dylib']['state'], 'current')
        self.assertFalse(report['activation']['respring_requested'])
        self.assertIn('launchdhook-vphone.dylib', ' '.join(report['activation']['reasons']))

    def test_a_missing_local_library_requires_full_migration(self):
        for name in LOCAL:
            with self.subTest(name=name):
                system = make_system(self.root / f'sys-{name}', omit=(name,))
                report = self.assess(system)
                self.assertEqual(report['classification'], 'full_migration_required')
                self.assertEqual(report['replace'], [])
                self.assertEqual(self.by_name(report)[name]['state'], 'missing')
                self.assertTrue(any(name in reason for reason in report['reasons']), report['reasons'])
                self.assertIn('migration', report)

    def test_missing_or_wrong_load_paths_require_full_migration(self):
        cases = {
            'no /vh alias': dict(alias=None),
            '/vh points elsewhere': dict(alias='/usr/lib/other.dylib'),
            'launchd lacks /vh': dict(launchd_loads=()),
        }
        for label, options in cases.items():
            with self.subTest(label):
                system = make_system(self.root / f'sys-{label}', self.current_versions(), **options)
                report = self.assess(system)
                self.assertEqual(report['classification'], 'full_migration_required', label)
                self.assertEqual(report['replace'], [])
                self.assertFalse(all(check['ok'] for check in report['load_paths']))

    def test_classic_basebin_bootstrap_requires_full_migration(self):
        system = make_system(self.root / 'sys', omit=tuple(LOCAL), alias=None, launchd_loads=('/b',), classic=True)
        report = self.assess(system, make_bundle(self.root / 'vm', variant='jb'))
        self.assertEqual(report['classification'], 'full_migration_required')
        self.assertEqual(report['bootstrap']['kind'], 'classic')
        self.assertTrue(any('/b' in reason for reason in report['reasons']), report['reasons'])

    def test_regular_classic_install_without_hooks_requires_full_migration(self):
        system = make_system(self.root / 'sys', omit=tuple(LOCAL), alias=None, launchd_loads=())
        report = self.assess(system, make_bundle(self.root / 'vm', variant='regular'))
        self.assertEqual(report['classification'], 'full_migration_required')
        self.assertEqual(report['bootstrap']['kind'], 'none')

    def test_unknown_bootstrap_requires_full_migration(self):
        system = make_system(self.root / 'sys', self.current_versions(),
                             launchd_loads=('/vh', '/var/jb/usr/lib/other.dylib'))
        report = self.assess(system)
        self.assertEqual(report['classification'], 'full_migration_required')
        self.assertEqual(report['bootstrap']['kind'], 'unknown')
        self.assertIn('/var/jb/usr/lib/other.dylib', report['bootstrap']['launchd_custom_loads'])

    def test_no_install_marker_requires_full_migration(self):
        report = self.assess(make_system(self.root / 'sys', self.current_versions(), marker=False))
        self.assertEqual(report['classification'], 'full_migration_required')
        self.assertTrue(any('launchd.plist.bak' in reason for reason in report['reasons']))

    def test_classic_variant_record_on_a_v2_disk_requires_full_migration(self):
        system = make_system(self.root / 'sys', self.current_versions())
        report = self.assess(system, make_bundle(self.root / 'vm', variant='exp'))
        self.assertEqual(report['classification'], 'full_migration_required')
        self.assertTrue(any('exp' in reason for reason in report['reasons']), report['reasons'])

    def test_a_library_that_is_a_symlink_is_not_replaceable(self):
        system = make_system(self.root / 'sys', self.current_versions(), omit=('libcamfix.dylib',))
        os.symlink('/usr/lib/libvlocation.dylib', system / 'usr/lib/libcamfix.dylib')
        report = self.assess(system)
        self.assertEqual(report['classification'], 'full_migration_required')
        self.assertEqual(self.by_name(report)['libcamfix.dylib']['state'], 'not_regular_file')

    def test_less_variant_is_not_applicable(self):
        for options in (dict(variant='less'), dict(checkpoint_variant='less')):
            with self.subTest(**options):
                vm = make_bundle(self.root / f'vm-{sorted(options.items())}', **options)
                report = self.assess(make_system(self.root / f'sys-{sorted(options.items())}'), vm)
                self.assertEqual(report['classification'], 'not_applicable')
                self.assertEqual(report['replace'], [])

    def test_missing_libmisfix_is_reported_and_neither_fails_nor_counts_as_updated(self):
        versions = self.current_versions()
        versions['libvlocation.dylib'] = 'v1'
        report = self.assess(make_system(self.root / 'sys', versions))
        self.assertEqual(report['classification'], 'offline_update', report['reasons'])
        misfix = self.by_name(report)['libmisfix.dylib']
        self.assertEqual(misfix['scope'], 'upstream_only')
        self.assertEqual(misfix['state'], 'upstream_only_absent')
        self.assertFalse(misfix['present'])
        self.assertEqual(misfix['task'], 'T18')
        self.assertNotIn('libmisfix.dylib', report['replace'])
        self.assertFalse(any('libmisfix' in reason for reason in report['reasons']))
        self.assertTrue(any('libmisfix' in note for note in report['notes']))

    def test_present_libmisfix_is_not_managed(self):
        versions = self.current_versions()
        versions['SystemHook-vphone.dylib'] = 'v1'
        report = self.assess(make_system(self.root / 'sys', versions, misfix=True))
        self.assertEqual(report['classification'], 'offline_update')
        self.assertEqual(self.by_name(report)['libmisfix.dylib']['state'], 'upstream_only_present_not_managed')
        self.assertEqual(report['replace'], ['SystemHook-vphone.dylib'])

    def test_candidate_that_differs_from_its_stage_manifest_is_refused(self):
        (self.stage / stage_paths()['libcamfix.dylib']).write_bytes(library('libcamfix.dylib', 'tampered'))
        with self.assertRaises(self.env.Refused):
            self.assess(make_system(self.root / 'sys', self.current_versions()))

    def test_unsigned_candidate_is_refused(self):
        make_stage(self.stage, overrides={'libcamfix.dylib': macho(signed=False, tag=b'unsigned')})
        with self.assertRaises(self.env.Refused):
            self.assess(make_system(self.root / 'sys', self.current_versions()))


# MARK: - Replacement on a mounted (directory) volume

class ApplyMountedTests(Fixture):
    def offline_system(self, misfix=False):
        versions = {name: 'v2' for name in LOCAL}
        versions['libcamfix.dylib'] = 'v1'
        versions['SystemHook-vphone.dylib'] = 'v1'
        return make_system(self.root / 'sys', versions, misfix=misfix)

    def test_replacement_changes_only_the_differing_libraries(self):
        system = self.offline_system(misfix=True)
        vm = make_bundle(self.root / 'vm')
        before = tree(system)
        report_path = self.root / 'report.json'
        self.assertEqual(self.env.apply_mounted(system, vm, self.stage, report_path), 0)
        after = tree(system)
        changed = {path for path in before.keys() | after.keys() if before.get(path) != after.get(path)}
        self.assertEqual(changed, {'usr/lib/libcamfix.dylib', 'usr/lib/SystemHook-vphone.dylib'})
        self.assertEqual(after['usr/lib/libcamfix.dylib'][2], 0o755)
        report = json.loads(report_path.read_text())
        self.assertEqual(report['result'], 'replaced')
        self.assertEqual(sorted(report['replaced']), ['SystemHook-vphone.dylib', 'libcamfix.dylib'])
        self.assertNotIn('libmisfix.dylib', report['replaced'])
        self.assertEqual(report['after']['classification'], 'already_current')
        self.assertIn('identity_before', report)

    def test_full_migration_is_refused_without_writing(self):
        system = make_system(self.root / 'sys', omit=('libvlocation.dylib',))
        before = tree(system)
        report_path = self.root / 'report.json'
        self.assertEqual(self.env.apply_mounted(system, make_bundle(self.root / 'vm'), self.stage, report_path), 3)
        self.assertEqual(tree(system), before)
        report = json.loads(report_path.read_text())
        self.assertEqual(report['result'], 'refused')
        self.assertEqual(report['replaced'], [])
        self.assertEqual(report['before']['classification'], 'full_migration_required')

    def test_already_current_is_refused_without_writing(self):
        system = make_system(self.root / 'sys', {name: 'v2' for name in LOCAL})
        before = tree(system)
        self.assertEqual(self.env.apply_mounted(system, make_bundle(self.root / 'vm'), self.stage,
                                                self.root / 'report.json'), 3)
        self.assertEqual(tree(system), before)


# MARK: - Shared library list

class ManifestConsistencyTests(unittest.TestCase):
    def test_daemon_list_matches_the_manifest(self):
        source = (ROOT / 'sources/VPhoneDaemon/Daemon/GuestAPI+Environment.swift').read_text()
        block = re.search(r'environmentLibraries = \[(.*?)\]', source, re.S).group(1)
        names = re.findall(r'"([^"]+)"', block)
        manifest = json.loads(MANIFEST.read_text())
        self.assertEqual(names, [entry['name'] for entry in manifest['libraries']])

    def test_stage_paths_are_built_guest_component_artifacts(self):
        spec = importlib.util.spec_from_file_location('check_guest_components', ROOT / 'scripts/check_guest_components.py')
        checker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(checker)
        for relative in stage_paths().values():
            self.assertIn(relative, checker.ARTIFACTS)

    def test_systemhook_loads_the_manifest_paths(self):
        hook = (ROOT / 'sources/VPhoneGuestComponents/SystemHook/SystemHook-vphone.c').read_text()
        shared = (ROOT / 'sources/VPhoneGuestComponents/Shared/InjectionEnvironment.h').read_text()
        defined = set(re.findall(r'#define VP_\w+ "(/usr/lib/[^"]+)"', hook + shared))
        manifest = json.loads(MANIFEST.read_text())
        for entry in manifest['libraries']:
            if entry['name'] != 'launchdhook-vphone.dylib':
                self.assertIn('/' + entry['guest'], defined)
        self.assertEqual(manifest['load_alias']['target'], '/' + manifest['libraries'][0]['guest'])

    def test_local_list_differs_from_upstream_only_by_location_and_misfix(self):
        manifest = json.loads(MANIFEST.read_text())
        local = [entry['name'] for entry in manifest['libraries']]
        self.assertEqual(local, LOCAL)
        self.assertEqual(set(local) - set(UPSTREAM_2_2_3), {'libvlocation.dylib'})
        self.assertEqual(set(UPSTREAM_2_2_3) - set(local), {entry['name'] for entry in manifest['upstream_only']})


# MARK: - Read-only check of a stopped VM

class CheckVMTests(Fixture):
    """check-vm in this process; disk attach and mount are tar-backed doubles."""

    def setUp(self):
        super().setUp()
        self.calls = []
        env = self.env
        self.production = {name: getattr(env, name) for name in
                           ('attach_readonly', 'system_volume', 'mount_volume', 'unmount', 'detach')}
        self.err = io.StringIO()

        def attach_readonly(image):
            self.calls.append(('attach', str(image), 'readonly'))
            return '/dev/disk91'

        def system_volume(base):
            self.calls.append(('locate', base))
            return '/dev/disk92s1'

        def mount_volume(device, mountpoint, readonly=False):
            self.calls.append(('mount', device, readonly))
            self.err_at_mount = self.err.getvalue()
            with tarfile.open(self.vm / 'Disk.img') as archive:
                archive.extractall(mountpoint, filter='tar')

        def unmount(mountpoint):
            self.calls.append(('unmount', str(mountpoint)))
            for entry in Path(mountpoint).iterdir():
                shutil.rmtree(entry) if entry.is_dir() and not entry.is_symlink() else entry.unlink()

        def detach(base):
            self.calls.append(('detach', base))

        env.attach_readonly, env.system_volume = attach_readonly, system_volume
        env.mount_volume, env.unmount, env.detach = mount_volume, unmount, detach

    def make_vm(self, versions=None, **bundle):
        self.vm = make_bundle(self.root / 'vm', **bundle)
        system = make_system(self.root / 'sys', versions)
        (self.vm / 'Disk.img').write_bytes(tar_of(system))
        return self.vm

    def run_check(self, *extra):
        out = io.StringIO()
        self.err = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(self.err):
            code = self.env.main(['check-vm', str(self.vm), '--components', str(self.stage), *extra])
        return code, out.getvalue(), self.err.getvalue()

    def tool(self, name, body):
        """An executable standing in for a disk tool (absolute path, as in production)."""
        path = self.root / name
        path.write_text('#!/bin/sh\n' + body + '\n')
        path.chmod(0o755)
        return str(path)

    def private_dir(self, name='caller', mode=0o700):
        path = self.root / name
        path.mkdir()
        path.chmod(mode)
        return path

    def test_check_reads_a_stopped_vm_without_writing_its_disk(self):
        versions = {name: 'v2' for name in LOCAL}
        versions['libvcamcaptured.dylib'] = 'v1'
        vm = self.make_vm(versions)
        disk = vm / 'Disk.img'
        before = (os.stat(disk).st_ino, os.stat(disk).st_mtime_ns, sha(disk.read_bytes()))
        listing = sorted(os.listdir(vm))
        code, out, err = self.run_check()
        self.assertEqual(code, 0, err)
        report = json.loads(out)
        self.assertEqual(report['classification'], 'offline_update')
        self.assertEqual(report['replace'], ['libvcamcaptured.dylib'])
        self.assertTrue(report['disk']['unchanged'])
        self.assertEqual((os.stat(disk).st_ino, os.stat(disk).st_mtime_ns, sha(disk.read_bytes())), before)
        self.assertEqual(sorted(os.listdir(vm)), listing)  # no record, lock file or mountpoint in the bundle
        self.assertIn(('mount', '/dev/disk92s1', True), self.calls)
        self.assertEqual([call[0] for call in self.calls], ['attach', 'locate', 'mount', 'unmount', 'detach'])
        self.assertEqual(set(report['identity']), {'config.plist', 'nvram.bin', 'SEPStorage',
                                                   '0000000000000001.shsh', 'restore-info.json'})

    def test_check_refuses_while_the_vm_lock_is_held(self):
        vm = self.make_vm()
        fd = os.open(vm, os.O_RDONLY)
        self.addCleanup(os.close, fd)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        code, out, err = self.run_check()
        self.assertEqual(code, 4, err)
        self.assertIn('lock', err)
        self.assertEqual(self.calls, [])

    def test_check_refuses_while_another_process_holds_the_disk(self):
        vm = self.make_vm()
        holder = subprocess.Popen([sys.executable, '-c', 'import sys,time; f=open(sys.argv[1],"rb"); print("ok",flush=True); time.sleep(30)',
                                   str(vm / 'Disk.img')], stdout=subprocess.PIPE)

        def stop():
            holder.kill()
            holder.communicate()
        self.addCleanup(stop)
        holder.stdout.readline()
        code, out, err = self.run_check()
        self.assertEqual(code, 4, err)
        self.assertIn(str(holder.pid), err)
        self.assertEqual(self.calls, [])

    def test_less_vm_is_not_applicable_without_attaching(self):
        self.make_vm(variant='less')
        code, out, err = self.run_check()
        self.assertEqual(code, 0, err)
        self.assertEqual(json.loads(out)['classification'], 'not_applicable')
        self.assertEqual(self.calls, [])

    # MARK: stages, limits and the unprivileged notice (2026-10-01 follow-up)

    def test_mount_timeout_names_the_stage_and_releases_the_image(self):
        # Real host, 2026-10-01: an unprivileged mount_apfs of the System
        # volume did not return for 180 s. The limit is now per stage and the
        # error names the stage and the next step.
        self.make_vm()
        argv = self.root / 'mount-argv'
        self.env.mount_volume = self.production['mount_volume']
        self.env.MOUNT_APFS = self.tool('slow-mount', f'echo "$@" > "{argv}"\nexec /bin/sleep 30')
        self.env.STAGE_TIMEOUTS['mount'] = 1
        started = time.monotonic()
        code, out, err = self.run_check()
        elapsed = time.monotonic() - started
        self.assertEqual(code, 5, err)
        self.assertLess(elapsed, 10)
        self.assertEqual(out, '')
        self.assertIn('stage mount', err)
        self.assertIn('timed out after 1 s', err)
        self.assertIn('--root-popup', err)
        self.assertEqual([call[0] for call in self.calls], ['attach', 'locate', 'detach'])
        mountpoint = Path(argv.read_text().split()[-1])
        self.assertTrue(argv.read_text().startswith('-o rdonly,nobrowse '))
        self.assertFalse(mountpoint.exists())
        self.assertNotIn(self.vm, mountpoint.parents)

    def test_unprivileged_check_announces_the_mount_and_its_limit_first(self):
        if os.geteuid() == 0:
            self.skipTest('the notice is for unprivileged runs')
        self.make_vm()
        code, out, err = self.run_check()
        self.assertEqual(code, 0, err)
        self.assertIn(f'as uid {os.geteuid()}', self.err_at_mount)
        self.assertIn(f'limit {self.env.STAGE_TIMEOUTS["mount"]} s', self.err_at_mount)
        self.assertIn('--root-popup', self.err_at_mount)

    def test_attach_failure_names_the_attach_stage(self):
        self.make_vm()
        self.env.attach_readonly = self.production['attach_readonly']
        self.env.HDIUTIL = self.tool('failing-hdiutil', 'echo "hdiutil: attach failed - Resource busy" >&2\nexit 1')
        code, out, err = self.run_check()
        self.assertEqual(code, 5, err)
        self.assertIn('stage attach', err)
        self.assertIn('Resource busy', err)
        self.assertEqual(self.calls, [])

    def test_read_failure_on_the_mounted_volume_names_the_read_stage(self):
        self.make_vm()

        def assess(*_args, **_kwargs):
            raise PermissionError(13, 'Permission denied', '/mnt/usr/lib/libcamfix.dylib')
        self.env.assess = assess
        code, out, err = self.run_check()
        self.assertEqual(code, 5, err)
        self.assertIn('stage read', err)
        self.assertEqual([call[0] for call in self.calls], ['attach', 'locate', 'mount', 'unmount', 'detach'])

    # MARK: report file for an elevated check

    def test_report_file_carries_the_result_to_the_caller(self):
        self.make_vm()
        caller = self.private_dir()
        report = caller / 'report.json'
        code, out, err = self.run_check('--report', str(report), '--owner', f'{os.getuid()}:{os.getgid()}')
        self.assertEqual(code, 0, err)
        self.assertNotIn('"classification"', out)   # the caller prints the report
        info = os.lstat(report)
        self.assertEqual((stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid), (0o600, os.getuid(), os.getgid()))
        result = json.loads(report.read_text())
        self.assertEqual(result['exit_code'], 0)
        self.assertIsNone(result['error'])
        self.assertEqual(result['report']['classification'], 'offline_update')   # v1 disk, v2 candidates
        self.assertEqual(os.listdir(caller), ['report.json'])

    def test_report_file_records_a_failure_with_its_exit_code(self):
        vm = self.make_vm()
        fd = os.open(vm, os.O_RDONLY)
        self.addCleanup(os.close, fd)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        report = self.private_dir() / 'report.json'
        code, out, err = self.run_check('--report', str(report))
        self.assertEqual(code, 4, err)
        result = json.loads(report.read_text())
        self.assertEqual((result['exit_code'], result['report']), (4, None))
        self.assertEqual(result['error']['kind'], 'busy')

    def test_report_destination_must_be_new_and_private(self):
        self.make_vm()
        caller = self.private_dir()
        existing = caller / 'existing.json'
        existing.write_text('keep')
        target = self.root / 'elsewhere'
        target.write_text('keep')
        (caller / 'link.json').symlink_to(target)
        shared = self.private_dir('shared', 0o777)
        cases = [(existing, ()), (caller / 'link.json', ()), (shared / 'report.json', ()),
                 (caller / 'report.json', ('--owner', str(os.getuid() + 1)))]
        for path, extra in cases:
            with self.subTest(path=path.name, extra=extra):
                code, out, err = self.run_check('--report', str(path), *extra)
                self.assertEqual(code, 2, err)
                self.assertEqual(self.calls, [])   # refused before the disk is touched
        self.assertEqual((existing.read_text(), target.read_text()), ('keep', 'keep'))
        self.assertFalse((shared / 'report.json').exists())
        self.assertFalse((caller / 'report.json').exists())


# MARK: - Root driver: replacement through the T15 transaction

class EnvironmentDriverFixture(HostDriverFixture):
    """Driver copy whose cfw_env_update.py runs under tests/cfw_env_update_harness.py."""

    def setUp(self):
        super().setUp()
        scripts = self.root / 'scripts'
        for name in ('cfw_env_update.py', 'guest_environment.json'):
            if (ROOT / 'scripts' / name).exists():
                shutil.copyfile(ROOT / 'scripts' / name, scripts / name)
        stub = self.root / '.tools/bin/stub'
        text = stub.read_text()
        text = text.replace(' umount:*) ', ' umount:*) [[ -n ${TEST_ENV_HARNESS:-} ]] && exec "$TEST_PYTHON" "$TEST_ENV_HARNESS" umount "$1"; ', 1)
        text = text.replace(' python:*) ', ' python:*) [[ "$1" == */cfw_env_update.py ]] && exec "$TEST_PYTHON" "$TEST_ENV_HARNESS" "$@"; ', 1)
        stub.write_text(text)
        self.stage = make_stage(self.root / 'stage')
        self.env.update(TEST_ENV_HARNESS=str(ROOT / 'tests/cfw_env_update_harness.py'),
                        VPHONE_GUEST_COMPONENTS=str(self.stage))
        self.scratch = self.root / 'scratch'
        self.scratch.mkdir()

    def make_vm(self, versions, **system):
        vm = make_bundle(self.root / 'vm')
        source = make_system(self.root / 'sys', versions, **system)
        (vm / 'Disk.img').write_bytes(tar_of(source))
        return vm, tree(source)

    def run_update(self, vm, **env):
        proc = subprocess.Popen(['/bin/zsh', str(self.driver), '--update-environment', str(vm)],
                                env=dict(self.env, TEST_MOUNTS=str(vm / 'mount-table'), **env),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        out, err = proc.communicate(timeout=60)
        return proc.returncode, (out + err).decode()

    def sudo_invoker(self):
        return dict(SUDO_USER='test-user', SUDO_UID=str(os.getuid()), SUDO_GID=str(os.getgid()))

    def bundle_digests(self, vm):
        return {name: sha((vm / name).read_bytes()) for name in
                ('config.plist', 'nvram.bin', 'SEPStorage', '0000000000000001.shsh', 'restore-info.json')}

    def offline_versions(self):
        versions = {name: 'v2' for name in LOCAL}
        versions['libvlocation.dylib'] = 'v1'
        versions['launchdhook-vphone.dylib'] = 'v1'
        return versions


class DriverUpdateTests(EnvironmentDriverFixture):
    def test_update_publishes_only_the_target_libraries_and_keeps_identity(self):
        vm, source = self.make_vm(self.offline_versions())
        disk = vm / 'Disk.img'
        original = (os.stat(disk).st_ino, sha(disk.read_bytes()))
        identity = self.bundle_digests(vm)
        rc, output = self.run_update(vm, **self.sudo_invoker())
        self.assertEqual(rc, 0, output)
        published = tree_of_tar(disk.read_bytes(), self.scratch)
        changed = {path for path in source.keys() | published.keys() if source.get(path) != published.get(path)}
        self.assertEqual(changed, {'usr/lib/libvlocation.dylib', 'usr/lib/launchdhook-vphone.dylib'})
        self.assertEqual(published['usr/lib/libvlocation.dylib'][1],
                         sha((self.stage / stage_paths()['libvlocation.dylib']).read_bytes()))
        self.assertNotEqual(os.stat(disk).st_ino, original[0])
        history = list((vm / '.cfw-history').iterdir())
        self.assertEqual(len(history), 1)
        retained = history[0] / 'Disk.img'
        self.assertEqual((os.stat(retained).st_ino, sha(retained.read_bytes())), original)
        report = json.loads((history[0] / 'environment-update.json').read_text())
        self.assertEqual(report['result'], 'replaced')
        self.assertTrue(report['identity_unchanged'])
        self.assertEqual(report['identity_after'], report['identity_before'])
        self.assertEqual(self.bundle_digests(vm), identity)
        self.assertNotIn('variant', json.loads((vm / 'restore-info.json').read_text()))
        calls = (self.root / 'calls').read_text()
        self.assertNotIn('apfs_snap_rename.py', calls)
        self.assertIn('respring', output)
        self.assertIn(f'chown -h {self.sudo_invoker()["SUDO_UID"]}', calls)
        self.assertFalse(list(vm.glob('.cfw_disk.*')))

    def test_full_migration_is_refused_and_the_disk_is_not_published(self):
        vm, _ = self.make_vm({name: 'v2' for name in LOCAL}, omit=('libcamfix.dylib',))
        disk = vm / 'Disk.img'
        original = (os.stat(disk).st_ino, sha(disk.read_bytes()), os.stat(disk).st_mtime_ns)
        rc, output = self.run_update(vm)
        self.assertNotEqual(rc, 0, output)
        self.assertIn('full_migration_required', output)
        self.assertEqual((os.stat(disk).st_ino, sha(disk.read_bytes()), os.stat(disk).st_mtime_ns), original)
        record = next((vm / '.cfw-history').iterdir())
        self.assertFalse((record / 'Disk.img').exists())
        self.assertEqual(json.loads((record / 'transaction.json').read_text())['status'], 'failed')
        report = json.loads((record / 'environment-update.json').read_text())
        self.assertEqual((report['result'], report['replaced']), ('refused', []))
        self.assertIn('/usr/lib/libcamfix.dylib is missing', report['reasons'])

    def test_failure_midway_leaves_the_original_disk_unchanged(self):
        vm, _ = self.make_vm(self.offline_versions())
        disk = vm / 'Disk.img'
        original = (os.stat(disk).st_ino, sha(disk.read_bytes()), os.stat(disk).st_mtime_ns)
        rc, output = self.run_update(vm, CFW_ENV_FAULTS='replace-second')
        self.assertNotEqual(rc, 0, output)
        self.assertEqual((os.stat(disk).st_ino, sha(disk.read_bytes()), os.stat(disk).st_mtime_ns), original)
        record = next((vm / '.cfw-history').iterdir())
        self.assertFalse((record / 'Disk.img').exists())  # staged copy removed, nothing published
        transaction = json.loads((record / 'transaction.json').read_text())
        self.assertEqual(transaction['status'], 'failed')
        self.assertTrue(transaction['original_check']['unchanged'])
        report = json.loads((record / 'environment-update.json').read_text())
        self.assertEqual(report['result'], 'failed')

    def test_root_popup_update_returns_the_record_to_the_invoker(self):
        vm, _ = self.make_vm(self.offline_versions())
        env = self.bare_env()
        env.update(TEST_ENV_HARNESS=self.env['TEST_ENV_HARNESS'], VPHONE_GUEST_COMPONENTS=str(self.stage),
                   TEST_MOUNTS=str(vm / 'mount-table'), SUDO_USER='test-user',
                   VPHONE_INVOKER_UID=str(os.getuid()), VPHONE_INVOKER_GID=str(os.getgid()))
        proc = subprocess.run(['/bin/zsh', str(self.driver), '--update-environment', str(vm)], env=env,
                              capture_output=True, timeout=60)
        output = (proc.stdout + proc.stderr).decode()
        self.assertEqual(proc.returncode, 0, output)
        record = next((vm / '.cfw-history').iterdir())
        calls = (self.root / 'calls').read_text()
        self.assertIn(f'chown -h {os.getuid()}:{os.getgid()}', calls)
        self.assertIn(str(record / 'environment-update.json'), calls)

    def test_unknown_option_is_rejected_before_any_change(self):
        # Before T16 an unrecognized argument was taken as the VM path and
        # then replaced by the next one, so the default exp install ran.
        vm, _ = self.make_vm(self.offline_versions())
        disk = vm / 'Disk.img'
        original = (os.stat(disk).st_ino, sha(disk.read_bytes()))
        proc = subprocess.run(['/bin/zsh', str(self.driver), '--update-enviroment', str(vm)],
                              env=dict(self.env, TEST_MOUNTS=str(vm / 'mount-table')), capture_output=True, timeout=60)
        self.assertEqual(proc.returncode, 1)
        self.assertIn(b'unknown option: --update-enviroment', proc.stderr)
        self.assertFalse((vm / '.cfw-history').exists())
        self.assertFalse(list(vm.glob('.cfw_disk.*')))
        self.assertEqual((os.stat(disk).st_ino, sha(disk.read_bytes())), original)
        self.assertFalse((self.root / 'calls').exists())


# MARK: - Elevated read-only check through the driver (sudo and root-popup)

class ElevatedCheckTests(EnvironmentDriverFixture):
    """`--check-environment` on the driver copy whose sudo re-exec is disabled.

    The sudo path is the driver's environment after `sudo -E` (SUDO_USER,
    SUDO_UID, SUDO_GID); the root-popup path is the bare environment of
    `do shell script` with the variables vphone-cli writes inline
    (VPHONE_INVOKER_UID/GID, SUDO_USER, VPHONE_PYTHON, VPHONE_GUEST_COMPONENTS).
    Nothing runs as root; attach, mount, unmount and detach are harness doubles.
    """

    def setUp(self):
        super().setUp()
        self.caller = self.root / 'caller'
        self.caller.mkdir(mode=0o700)
        self.report = self.caller / 'report.json'
        self.mounts = self.root / 'mount-table'
        self.tmpdir = self.root / 'tmp'
        self.tmpdir.mkdir()

    def run_check(self, vm, bare=False, args=None, **env):
        base = self.bare_env() if bare else dict(self.env, TMPDIR=str(self.tmpdir))
        base.pop('PYTHONDONTWRITEBYTECODE', None)   # the driver sets it for the root check
        base.update(TEST_ENV_HARNESS=self.env['TEST_ENV_HARNESS'], VPHONE_GUEST_COMPONENTS=str(self.stage),
                    TEST_MOUNTS=str(self.mounts))
        base.update(env)
        command = ['/bin/zsh', str(self.driver)] + (args if args is not None else
                                                     ['--check-environment', '--report', str(self.report)]) + [str(vm)]
        started = time.monotonic()
        proc = subprocess.run(command, env=base, capture_output=True, timeout=60)
        return proc.returncode, (proc.stdout + proc.stderr).decode(), time.monotonic() - started

    def snapshot(self, vm):
        disk = vm / 'Disk.img'
        info = os.stat(disk)
        return sorted(os.listdir(vm)), (info.st_ino, info.st_size, info.st_mtime_ns, sha(disk.read_bytes())), \
            self.bundle_digests(vm)

    def calls(self):
        path = self.root / 'calls'
        return path.read_text() if path.exists() else ''

    def assert_read_only_and_clean(self, vm, before):
        self.assertEqual(self.snapshot(vm), before)   # no record, lock file, staging or mount dir in the bundle
        for name in ('.vphone-runtime.json', '.cfw-history'):
            self.assertFalse((vm / name).exists())
        self.assertFalse(list(vm.glob('.cfw_disk.*')) + list(vm.glob('.cfw_mount.*')))
        calls = self.calls()
        self.assertNotIn('vm_lock.py', calls)
        self.assertNotIn('cfw_disk_txn.py', calls)
        self.assertFalse([line for line in calls.splitlines() if line.startswith(('chown ', 'hdiutil ', 'diskutil '))])
        self.assertIn('harness attach -readonly ', calls)
        self.assertIn('harness detach /dev/disk91', calls)
        self.assertEqual(self.mounts.read_text() if self.mounts.exists() else '', '')
        for line in calls.splitlines():
            if line.startswith('harness mount '):
                self.assertTrue(line.startswith('harness mount ro '), line)
                mountpoint = Path(line.split()[-1])
                self.assertFalse(mountpoint.exists())
                self.assertNotIn(vm.resolve(), mountpoint.resolve().parents)
        self.assertFalse(list(self.tmpdir.iterdir()))
        self.assertFalse((self.root / 'scripts/__pycache__').exists())   # nothing written beside the scripts

    def assert_report_returned(self, owner):
        info = os.lstat(self.report)
        self.assertEqual((stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid), (0o600, os.getuid(), os.getgid()))
        self.assertIn(f'--owner {owner}', self.calls())
        self.assertEqual(os.listdir(self.caller), ['report.json'])
        return json.loads(self.report.read_text())

    def test_sudo_path_check_is_read_only_and_returns_the_report(self):
        vm, _ = self.make_vm(self.offline_versions())
        before = self.snapshot(vm)
        rc, output, _ = self.run_check(vm, **self.sudo_invoker())
        self.assertEqual(rc, 0, output)
        result = self.assert_report_returned(f'{os.getuid()}:{os.getgid()}')
        self.assertEqual(result['exit_code'], 0)
        self.assertEqual(result['report']['classification'], 'offline_update')
        self.assertEqual(sorted(result['report']['replace']), ['launchdhook-vphone.dylib', 'libvlocation.dylib'])
        self.assertTrue(result['report']['disk']['unchanged'])
        self.assertIn('harness mount ro /dev/disk92s1 ', self.calls())
        self.assert_read_only_and_clean(vm, before)

    def test_root_popup_path_check_is_read_only_and_returns_the_report(self):
        vm, _ = self.make_vm({name: 'v2' for name in LOCAL}, omit=('libcamfix.dylib',))
        before = self.snapshot(vm)
        rc, output, _ = self.run_check(vm, bare=True, SUDO_USER='test-user',
                                       VPHONE_INVOKER_UID=str(os.getuid()), VPHONE_INVOKER_GID=str(os.getgid()))
        self.assertEqual(rc, 0, output)
        result = self.assert_report_returned(f'{os.getuid()}:{os.getgid()}')
        self.assertEqual(result['report']['classification'], 'full_migration_required')
        self.assertIn('/usr/lib/libcamfix.dylib is missing', result['report']['reasons'])
        self.assert_read_only_and_clean(vm, before)

    def test_sudo_reexec_keeps_the_check_arguments(self):
        # The real guard: a non-root run re-executes itself under sudo -E with
        # the same mode arguments. sudo is replaced by a recorder.
        vm, _ = self.make_vm(self.offline_versions())
        driver = self.root / 'scripts/reexec_probe.sh'
        source = (ROOT / 'scripts/cfw_install_host.sh').read_text()
        line = 'exec sudo ${SUDO_ASKPASS:+-A} -E /bin/zsh "$0" "${MODE_ARGS[@]}" "$VM_DIR"'
        self.assertIn(line, source)
        driver.write_text(source.replace('if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then', 'if true; then').replace(
            line, 'exec "$TEST_PYTHON" -c "import json,sys; print(json.dumps(sys.argv[1:]))" /bin/zsh "$0" '
                  '"${MODE_ARGS[@]}" "$VM_DIR"'))
        proc = subprocess.run(['/bin/zsh', str(driver), '--check-environment', '--report', str(self.report), str(vm)],
                              env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(json.loads(proc.stdout)[2:], ['--check-environment', '--report', str(self.report), str(vm)])

    def test_mount_timeout_is_reported_with_its_stage_and_cleaned_up(self):
        vm, _ = self.make_vm(self.offline_versions())
        before = self.snapshot(vm)
        rc, output, elapsed = self.run_check(vm, CFW_ENV_FAULTS='mount-hang', **self.sudo_invoker())
        self.assertEqual(rc, 5, output)
        self.assertLess(elapsed, 30)
        result = self.assert_report_returned(f'{os.getuid()}:{os.getgid()}')
        self.assertEqual((result['exit_code'], result['report']), (5, None))
        self.assertEqual((result['error']['kind'], result['error']['stage']), ('disk_access', 'mount'))
        self.assertIn('timed out after 1 s', result['error']['message'])
        self.assertTrue(result['error']['advice'])
        self.assertIn('stage mount', output)
        calls = self.calls()
        self.assertIn('harness detach /dev/disk91', calls)
        self.assertNotIn('harness mount ', calls)   # the production mount ran and was stopped
        self.assertEqual(self.snapshot(vm), before)
        self.assertEqual(self.mounts.read_text() if self.mounts.exists() else '', '')
        self.assertFalse(list(self.tmpdir.iterdir()))

    def test_report_directory_not_owned_by_the_invoker_is_refused(self):
        vm, _ = self.make_vm(self.offline_versions())
        before = self.snapshot(vm)
        rc, output, _ = self.run_check(vm, bare=True, VPHONE_INVOKER_UID=str(os.getuid() + 1),
                                       VPHONE_INVOKER_GID=str(os.getgid()))
        self.assertEqual(rc, 2, output)
        self.assertIn('owner', output)
        self.assertFalse(self.report.exists())
        self.assertNotIn('harness attach', self.calls())
        self.assertEqual(self.snapshot(vm), before)

    def test_malformed_invoker_or_arguments_are_refused_before_any_access(self):
        vm, _ = self.make_vm(self.offline_versions())
        before = self.snapshot(vm)
        cases = [
            (dict(bare=True, VPHONE_INVOKER_UID='501x'), None, 2),
            ({}, ['--check-environment'], 1),
            ({}, ['--report', str(self.report)], 1),
            ({}, ['--check-environment', '--report', str(self.report), '--update-environment'], 1),
        ]
        for env, args, code in cases:
            with self.subTest(env=env, args=args):
                rc, output, _ = self.run_check(vm, args=args, **env)
                self.assertEqual(rc, code, output)
                self.assertFalse(self.report.exists())
                self.assertNotIn('cfw_env_update.py', self.calls())
                self.assertEqual(self.snapshot(vm), before)


if __name__ == '__main__':
    unittest.main()
