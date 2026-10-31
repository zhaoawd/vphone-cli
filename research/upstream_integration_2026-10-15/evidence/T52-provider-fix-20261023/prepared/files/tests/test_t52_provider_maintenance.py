"""T52 provider candidate's one-file System transaction, with real file swap and guest writes.

Only the APFS mount boundary and system store receipt command are simulated.
The actual eligibility, library replacement, digests and recovery code execute.
"""
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / 'scripts'), str(ROOT / 'tests')]
from test_cfw_env_update import make_system, make_stage, make_bundle, tar_of, LOCAL, tree

spec = importlib.util.spec_from_file_location('t52_provider_maintenance', ROOT / 'research/upstream_integration_2026-10-15/tools/t52_provider_maintenance.py')
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


class ProviderMaintenanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.vm = make_bundle(self.root / 'vm', variant='regular')
        info = json.loads((self.vm / 'restore-info.json').read_text())
        info['guest_environment'] = 'v2'
        (self.vm / 'restore-info.json').write_text(json.dumps(info))
        for name in m.METADATA:
            if not (self.vm / name).exists():
                (self.vm / name).write_text('{}')
        (self.vm / 'launchpad.json').write_text(json.dumps({'bundle': m.VERSION}))
        self.resources = self.root / 'store' / m.VERSION / 'VPhone.bundle/Contents/Resources'
        stage = make_stage(self.resources / '.build/guest-components-v2/stage')
        self.system = make_system(self.root / 'system', versions={name: 'v2' for name in LOCAL if name not in m.TARGET_LIBRARIES}, misfix=False)
        import plistlib
        api = self.system / 'usr/bin/vphoned-api'
        api.write_bytes(b'old-api'); api.chmod(0o755)
        cache = self.system / '.fixture-data/root/Library/Caches/vphoned'
        cache.parent.mkdir(parents=True)
        cache.write_bytes(b'old-publisher'); cache.chmod(0o755)
        job_path = self.system / 'System/Library/xpc/launchd.plist'
        jobs = plistlib.loads(job_path.read_bytes())
        jobs['LaunchDaemons']['/System/Library/LaunchDaemons/vphoned-api.plist'] = {}
        job_path.write_bytes(plistlib.dumps(jobs))
        api_candidate = self.resources / '.build/daemon-api-v2/candidate-v2/vphoned'
        api_candidate.parent.mkdir(parents=True)
        api_candidate.write_bytes(b'old-api'); api_candidate.chmod(0o755)
        self.publisher = self.root / 'publisher'
        self.publisher.write_bytes(b'new-publisher'); self.publisher.chmod(0o755)
        (self.vm / 'Disk.img').write_bytes(tar_of(self.system))
        self.original = (self.vm / 'Disk.img').read_bytes()
        self.identity = m.image_identity(self.vm / 'Disk.img')
        self.before = tree(self.system)
        self.precheck = m.update.assess(self.system, self.vm, stage)
        approved = {k: v['sha256'] for k, v in m.update.candidates(stage, m.update.load_manifest()).items() if k in m.TARGET_LIBRARIES}
        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(patch.object(m, 'TARGET', self.vm))
        stack.enter_context(patch.object(m, 'GUEST_OWNER', os.getuid()))
        stack.enter_context(patch.object(m, 'API_SHA256', m.sha(b'old-api')))
        stack.enter_context(patch.object(m, 'BEFORE_API_SHA256', m.sha(b'old-api')))
        stack.enter_context(patch.object(m, 'STORE', self.root / 'store'))
        stack.enter_context(patch.object(m, 'APPROVED', approved))
        stack.enter_context(patch.object(m.subprocess, 'run'))
        stack.enter_context(patch.object(m.disk, 'require_unheld'))
        stack.enter_context(patch.object(m.disk, 'require_free_space'))
        stack.enter_context(patch.object(m, 'mounted', self.mount))
        self.plan = m.prepare(self.vm, self.resources, self.precheck)

    def mount(self, image, root, readonly, action, *, data_root=None):
        with tarfile.open(image) as archive:
            # The fixture creates /vh as the actual absolute guest load alias.
            # This archive is generated locally above; no external input is read.
            archive.extractall(root, filter='fully_trusted')
        before = tree(root)
        try:
            return action(root)
        finally:
            if readonly:
                self.assertEqual(tree(root), before)
            else:
                image.write_bytes(tar_of(root))
            # Simulate a detached APFS mount disappearing from its mountpoint.
            import shutil
            for path in root.iterdir():
                if path.is_dir() and not path.is_symlink():
                    shutil.rmtree(path)
                else:
                    path.unlink()

    def apply(self, fault=lambda phase: None):
        return m.apply_plan(self.plan, self.vm, self.resources, self.root, fault=fault)

    def pending(self):
        return next(self.vm.glob('.cfw_disk.*'))

    def test_only_approved_libraries_change_and_original_is_retained(self):
        result = self.apply()
        self.assertEqual(result['state'], 'published')
        archive = Path(result['archive'])
        self.assertEqual((archive / 'Disk.img').read_bytes(), self.original)
        self.assertEqual(m.image_identity(archive / 'Disk.img'), self.identity)
        self.assertFalse(m.pending(self.vm))
        self.assertFalse((self.vm / '.cfw-history').exists())
        self.assertEqual(result['firmwareAuthority'], 'unknown')
        self.assertEqual(result['undoAuthority'], 'unknown')
        root = self.root / 'readback'; root.mkdir()
        self.mount(self.vm / 'Disk.img', root, True, lambda root: self.assertEqual(
            sorted(k for k, v in tree(root).items() if self.before.get(k) != v),
            sorted(['usr/lib/' + name for name in m.TARGET_LIBRARIES])))
        self.assertEqual(m.metadata(self.vm), self.plan['metadata'])

    def test_failure_before_write_or_swap_preserves_original_and_is_recoverable(self):
        for phase in ('before-write', 'after-write', 'before-swap'):
            with self.subTest(phase=phase):
                def fault(at):
                    if at == phase:
                        raise RuntimeError('injected ' + phase)
                with self.assertRaisesRegex(RuntimeError, 'injected'):
                    self.apply(fault)
                self.assertEqual((self.vm / 'Disk.img').read_bytes(), self.original)
                work = self.pending()
                journal = json.loads((work / 'transaction.json').read_text())
                result = m.recover(work, journal, self.vm, self.resources)
                self.assertEqual(result['state'], 'aborted-original-preserved')
                self.assertFalse(m.pending(self.vm))
                self.plan['id'] = str(m.uuid.uuid4())

    def test_failure_after_atomic_swap_finishes_without_replacing_the_original(self):
        def fault(at):
            if at == 'after-swap':
                raise RuntimeError('power loss')
        with self.assertRaisesRegex(RuntimeError, 'power loss'):
            self.apply(fault)
        work = self.pending()
        journal = json.loads((work / 'transaction.json').read_text())
        self.assertEqual(journal['status'], 'swapping')
        self.assertNotEqual((self.vm / 'Disk.img').read_bytes(), self.original)
        result = m.recover(work, journal, self.vm, self.resources)
        self.assertEqual(result['state'], 'published')
        self.assertEqual((Path(result['archive']) / 'Disk.img').read_bytes(), self.original)

    def test_changed_disk_metadata_binding_and_plan_are_rejected_before_staging(self):
        for change in ('disk', 'metadata', 'binding', 'scope', 'authority', 'identifier'):
            with self.subTest(change=change):
                plan = json.loads(json.dumps(self.plan))
                if change == 'disk': plan['diskSHA256'] = '0' * 64
                if change == 'metadata': plan['metadata']['config.plist'] = '0' * 64
                if change == 'binding': plan['bundleVersion'] = 'other'
                if change == 'scope': plan['replace'] = ['libvlocation.dylib']
                if change == 'authority': plan['undoAuthority'] = 'verified'
                if change == 'identifier': plan['id'] = '../bad'
                with self.assertRaises(ValueError):
                    m.apply_plan(plan, self.vm, self.resources, self.root)
                self.assertFalse(m.pending(self.vm))

    def test_refuses_other_vm_pending_work_wrong_scope_and_candidate_bytes(self):
        with patch.object(m, 'TARGET', self.root / 'other'), self.assertRaises(ValueError):
            m.prepare(self.vm, self.resources, self.precheck)
        with patch.object(m, 'APPROVED', {}), self.assertRaises(ValueError):
            m.prepare(self.vm, self.resources, self.precheck)
        wrong = dict(self.precheck, replace=['libvlocation.dylib'])
        with self.assertRaises(ValueError): m.prepare(self.vm, self.resources, wrong)
        pending = self.vm / '.cfw_disk.other'; pending.mkdir()
        with self.assertRaises(ValueError): self.apply()
        self.assertEqual((self.vm / 'Disk.img').read_bytes(), self.original)

    def test_recovery_refuses_changed_metadata_or_retained_original(self):
        def fault(at):
            if at == 'after-swap': raise RuntimeError('fault')
        with self.assertRaises(RuntimeError): self.apply(fault)
        work = self.pending(); journal = json.loads((work / 'transaction.json').read_text())
        original_metadata = (self.vm / 'config.plist').read_bytes()
        (self.vm / 'config.plist').write_bytes(b'changed')
        with self.assertRaises(ValueError): m.recover(work, journal, self.vm, self.resources)
        (self.vm / 'config.plist').write_bytes(original_metadata)
        (work / 'Disk.img').write_bytes(b'tampered original')
        with self.assertRaises(ValueError): m.recover(work, journal, self.vm, self.resources)
        self.assertTrue(m.pending(self.vm))

    def test_symlinks_hardlinks_and_wrong_system_binding_are_refused(self):
        path = self.root / 'link'; path.symlink_to(self.vm / 'Disk.img')
        with self.assertRaises((OSError, ValueError)): m.strict(path)
        path.unlink(); os.link(self.vm / 'Disk.img', path)
        with self.assertRaises(ValueError): m.image_identity(self.vm / 'Disk.img')
        with self.assertRaises(ValueError): m.qualified_bundle(self.vm, self.root)

    def test_api_and_publisher_input_changes_refuse_before_publication(self):
        for change in ('api', 'mode', 'symlink', 'parent-symlink'):
            with self.subTest(change=change):
                # Mutate the mounted clone, keeping the bound original intact.
                original_mount = self.mount
                def changed_mount(image, root, readonly, action):
                    def mutate(system):
                        api = system / 'usr/bin/vphoned-api'
                        publisher = system / '.fixture-data/root/Library/Caches/vphoned'
                        if change == 'api': api.write_bytes(b'wrong')
                        if change == 'publisher': publisher.write_bytes(b'wrong')
                        if change == 'cache': (publisher.parent / 'vphoned-api').write_bytes(b'old override')
                        if change == 'pending': (publisher.parent / 'vphoned.api-v2.pending').write_bytes(b'pending')
                        if change == 'mode': api.chmod(0o777)
                        if change == 'symlink': api.unlink(); api.symlink_to(publisher)
                        if change == 'parent-symlink':
                            directory = api.parent
                            retained = directory.with_name('retained-cache')
                            directory.rename(retained); directory.symlink_to(retained)
                        return action(system)
                    return original_mount(image, root, readonly, mutate)
                with patch.object(m, 'mounted', changed_mount), self.assertRaises((ValueError, OSError)):
                    self.apply()
                self.assertEqual((self.vm / 'Disk.img').read_bytes(), self.original)
                work = self.pending()
                m.recover(work, json.loads((work / 'transaction.json').read_text()), self.vm, self.resources)
                self.plan['id'] = str(m.uuid.uuid4())

    def test_api_is_verified_but_never_rewritten(self):
        replace = m.update.replace_file
        def forbid_api(source, target):
            self.assertNotEqual(Path(target).name, 'vphoned-api')
            return replace(source, target)
        with patch.object(m.update, 'replace_file', forbid_api):
            result = self.apply()
        self.assertEqual(result['state'], 'published')
        self.assertEqual(result['plan']['extraCandidates'], {})
        self.assertEqual((Path(result['archive']) / 'Disk.img').read_bytes(), self.original)
