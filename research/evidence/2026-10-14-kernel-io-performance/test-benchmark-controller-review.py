"""Rejection and timeout regressions using tiny ordinary files and mocked APIs.

No real controller, Popen, process inspection, signal, build or benchmark runs.
"""
import argparse
import contextlib
import copy
import importlib.util
import io
import os
import plistlib
import signal
import json
import math
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import MagicMock, call, patch

E = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('benchmark_controller', E / 'run-benchmarks.py')
bench = importlib.util.module_from_spec(spec); spec.loader.exec_module(bench)
spec = importlib.util.spec_from_file_location('recorded_runner', E / 'run-recorded.py')
recorded = importlib.util.module_from_spec(spec); spec.loader.exec_module(recorded)
spec = importlib.util.spec_from_file_location('prepare_manifest', E / 'prepare-test-manifest.py')
prepare = importlib.util.module_from_spec(spec); spec.loader.exec_module(prepare)
SIZE = (1 << 20) + 3


def sample():
    return dict(event='measurement-end', label='pure-review', operation='capture', pid=123,
                monotonic_start_ns=10, monotonic_end_ns=100, elapsed_ns=90, elapsed_seconds=90 / 1e9,
                bytes=SIZE, observed_size=SIZE, result='passed', error=None, offsets_match=True,
                offsets=[0, 524288, 1044480, 1048576], expected_offsets=[0, 524288, 1044480, 1048576],
                original_sha256='1' * 64, candidate_sha256='2' * 64, rss_peak_after_bytes=1000, rss_peak_before_bytes=500, rss_peak_growth_bytes=500, readsize=4096)


def event(token, phase, start, elapsed, parent=None, counts=None):
    return dict(type='span', schema_version=1, id=token, parent_id=parent, pid=123, thread_id=1,
                phase=phase, caller_file='test/Fixture.swift', caller_line=1, caller_function='pureFixture',
                started_ns=start, elapsed_ns=elapsed, inclusive=True, outcome='success',
                counts=counts or {}, labels={})


def trace(outside_compare=False, all_candidate_sha=False):
    rows = [event('helper', 'kernelDisk.capture', 20, 60)]
    roles = ['live_disk', 'candidate_image', 'live_disk', 'original_disk_snapshot', 'candidate_disk_snapshot']
    for index, role in enumerate(roles):
        row = event('sha' + str(index), 'generation.fileSHA256', 21 + index * 3, 2, 'helper', {'bytes': SIZE})
        row['labels'] = dict(role='candidate_image' if all_candidate_sha else role, byte_semantics='consumer_actual')
        rows.append(row)
    compare = event('compare', 'kernelDisk.capture.compare', 1 if outside_compare else 40,
                    3 if outside_compare else 10, None if outside_compare else 'helper',
                    dict(blocks=(SIZE + 4095) // 4096, logical_bytes=SIZE, old_bytes=SIZE, new_bytes=SIZE))
    rows.append(compare)
    return rows + [dict(type='measurement_end', schema_version=1, pid=123, complete=True,
                        events=len(rows), dropped=0, open_spans=0, io_error=None)]


def variant_fixture():
    manifest = {'variants': [], 'xctest': '/Applications/Xcode.app/Contents/Developer/usr/bin/xctest', 'xctest_sha256': '9' * 64}
    digests = {manifest['xctest']: '9' * 64}; texts, records = {}, {}
    for index, (name, tracing, read_bytes) in enumerate([('baseline', False, 4096), ('timed4k', True, 4096), ('buffered1m', True, 1048576)]):
        root = '/private/tmp/vphone-kernel-io-pure-' + name
        bundle = root + '/.build/arm64-apple-macosx/release/vphone-cliPackageTests.xctest'
        path = '/private/tmp/pure-build-' + name + '.json'
        variant = dict(name=name, root=root, bundle=bundle, trace=tracing, read_bytes=read_bytes,
                       binary_sha256=str(index + 1) * 64, benchmark_test_sha256='4' * 64, package_sha256='5' * 64,
                       kernel_disk_source_sha256='6' * 64, build_record=path, build_record_sha256='7' * 64,
                       compiled_source_root=root, build_flags=dict(configuration='release', language='swift-tools-version:6.0', platform='macOS15', automatic_resolution=False))
        manifest['variants'].append(variant)
        for suffix, field in [('/Contents/MacOS/vphone-cliPackageTests', 'binary_sha256')]: digests[bundle + suffix] = variant[field]
        for suffix, field in [('/tests/FirmwarePatcherTests/FirmwareKernelIOBenchmarkTests.swift', 'benchmark_test_sha256'),
                              ('/Package.swift', 'package_sha256'), ('/sources/FirmwarePatcher/Pipeline/FirmwareKernelDisk.swift', 'kernel_disk_source_sha256')]: digests[root + suffix] = variant[field]
        digests[path] = variant['build_record_sha256']
        records[path] = dict(exit_code=0, command=['swift', 'test', '--package-path', root, '--scratch-path', root + '/.build',
                                                 '--cache-path', root + '/.swiftpm-cache', '--disable-automatic-resolution', '-c', 'release', '--filter', 'PureTests'])
        texts[root + '/Package.swift'] = '// swift-tools-version:6.0\nplatforms: [.macOS(.v15)]\n'
    return manifest, digests, texts, records


class ControllerRejectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='kernel-io-controller-pure-')
        self.root = Path(self.temporary.name)
        self.external = patch.object(subprocess, 'run', side_effect=AssertionError('Native command forbidden'))
        self.external.start()
        self.popen_guard = patch.object(subprocess, 'Popen', side_effect=AssertionError('Real process forbidden')); self.popen_guard.start()
        self.signal_guard = patch.object(os, 'killpg', side_effect=AssertionError('Real signal forbidden')); self.signal_guard.start()
    def tearDown(self):
        self.signal_guard.stop(); self.popen_guard.stop(); self.external.stop(); self.temporary.cleanup()
    def log(self, end):
        path = self.root / 'sample.log'
        start = dict(event='measurement-start', label='pure-review', operation='capture', pid=123, monotonic_ns=5)
        path.write_text('\n'.join('kernel-io-benchmark ' + json.dumps(row) for row in [start, end]) + '\n')
        return path
    def test_valid_sample_control(self):
        self.assertEqual(bench.sample_from_log(self.log(sample()), 'pure-review', 'capture', SIZE)['elapsed_ns'], 90)
    def test_nan_seconds_rejected(self):
        value = sample(); value['elapsed_seconds'] = float('nan')
        with self.assertRaises(ValueError): bench.sample_from_log(self.log(value), 'pure-review', 'capture', SIZE)
    def test_negative_or_inconsistent_seconds_rejected(self):
        for seconds in (-10.0, 900.0):
            value = sample(); value['elapsed_seconds'] = seconds
            with self.assertRaises(RuntimeError): bench.sample_from_log(self.log(value), 'pure-review', 'capture', SIZE)
    def test_empty_expected_offsets_rejected(self):
        value = sample(); value['offsets'] = []; value['expected_offsets'] = []
        with self.assertRaises(RuntimeError): bench.sample_from_log(self.log(value), 'pure-review', 'capture', SIZE)
    def test_valid_trace_control(self):
        path = self.root / 'trace.jsonl'; path.write_text('\n'.join(json.dumps(row) for row in trace()) + '\n')
        self.assertEqual(bench.helper_trace(path, sample())['sha_calls'], 5)
    def test_compare_outside_helper_rejected(self):
        path = self.root / 'trace.jsonl'; path.write_text('\n'.join(json.dumps(row) for row in trace(outside_compare=True)) + '\n')
        with self.assertRaises(RuntimeError): bench.helper_trace(path, sample())
    def test_sha_wrong_role_distribution_rejected(self):
        path = self.root / 'trace.jsonl'; path.write_text('\n'.join(json.dumps(row) for row in trace(all_candidate_sha=True)) + '\n')
        with self.assertRaises(RuntimeError): bench.helper_trace(path, sample())
    def test_incomplete_stderr_and_footer_are_already_rejected(self):
        path = self.log(sample()); path.write_text(path.read_text() + '[kernel-io-trace] measurement incomplete\n')
        with self.assertRaises(RuntimeError): bench.sample_from_log(path, 'pure-review', 'capture', SIZE)
        path = self.root / 'trace.jsonl'; rows = trace(); rows[-1]['complete'] = False
        path.write_text('\n'.join(json.dumps(row) for row in rows) + '\n')
        with self.assertRaises(ValueError): bench.helper_trace(path, sample())
    def test_owned_child_term_is_bounded_and_reaped(self):
        child = MagicMock(pid=222, returncode=-15)
        child.poll.side_effect = [None, -15]; child.wait.return_value = -15
        with patch.object(os, 'killpg') as send:
            result = recorded.terminate_owned(child)
        self.assertEqual(result, dict(signals=['SIGTERM'], complete=True, error=None))
        send.assert_called_once_with(222, signal.SIGTERM); child.wait.assert_called_once_with(timeout=5)
    def test_owned_child_term_timeout_uses_kill_and_reaps(self):
        child = MagicMock(pid=222, returncode=-9)
        child.poll.side_effect = [None, -9]
        child.wait.side_effect = [subprocess.TimeoutExpired('owned', 5), -9]
        with patch.object(os, 'killpg') as send: result = recorded.terminate_owned(child)
        self.assertEqual(result, dict(signals=['SIGTERM', 'SIGKILL'], complete=True, error=None))
        self.assertEqual(send.call_args_list, [call(222, signal.SIGTERM), call(222, signal.SIGKILL)])
        self.assertEqual(child.wait.call_args_list, [call(timeout=5), call(timeout=5)])
    def test_owned_child_reap_timeout_is_incomplete(self):
        child = MagicMock(pid=222, returncode=None); child.poll.return_value = None
        child.wait.side_effect = subprocess.TimeoutExpired('owned', 5)
        with patch.object(os, 'killpg') as send: result = recorded.terminate_owned(child)
        self.assertEqual(result, dict(signals=['SIGTERM', 'SIGKILL'], complete=False, error='TimeoutExpired'))
        self.assertEqual(send.call_args_list, [call(222, signal.SIGTERM), call(222, signal.SIGKILL)])
    def test_already_reaped_child_receives_no_signal(self):
        child = MagicMock(pid=222, returncode=0); child.poll.return_value = 0
        with patch.object(os, 'killpg') as send: result = recorded.terminate_owned(child)
        self.assertEqual(result, dict(signals=[], complete=True, error=None)); send.assert_not_called(); child.wait.assert_not_called()
    def test_wrapper_success_owns_new_session(self):
        child = MagicMock(pid=333, returncode=0); child.communicate.return_value = ('out', 'err')
        with patch.object(subprocess, 'Popen', return_value=child) as create, patch.object(os, 'killpg') as send:
            self.assertEqual(bench.bounded_wrapper(['fake-wrapper']), (0, 'out', 'err'))
        self.assertTrue(create.call_args.kwargs['start_new_session']); send.assert_not_called()
        child.communicate.assert_called_once_with(timeout=165)
    def test_wrapper_timeout_remains_failure_after_term_cleanup(self):
        child = MagicMock(pid=333, returncode=0)
        child.communicate.side_effect = [subprocess.TimeoutExpired('wrapper', 165), ('out', 'err')]
        with patch.object(subprocess, 'Popen', return_value=child), patch.object(os, 'killpg') as send:
            with self.assertRaisesRegex(RuntimeError, 'wrapper timeout'): bench.bounded_wrapper(['fake-wrapper'])
        send.assert_called_once_with(333, signal.SIGTERM)
        self.assertEqual(child.communicate.call_args_list, [call(timeout=165), call(timeout=15)])
    def test_wrapper_term_timeout_kills_and_reaps(self):
        child = MagicMock(pid=333, returncode=-9)
        child.communicate.side_effect = [subprocess.TimeoutExpired('wrapper', 165), subprocess.TimeoutExpired('wrapper', 15), ('out', 'err')]
        with patch.object(subprocess, 'Popen', return_value=child), patch.object(os, 'killpg') as send:
            with self.assertRaisesRegex(RuntimeError, 'wrapper timeout'): bench.bounded_wrapper(['fake-wrapper'])
        self.assertEqual(send.call_args_list, [call(333, signal.SIGTERM), call(333, signal.SIGKILL)])
        self.assertEqual(child.communicate.call_args_list, [call(timeout=165), call(timeout=15), call(timeout=5)])
    def test_wrapper_original_interrupt_is_reraised_after_owned_cleanup(self):
        failure = KeyboardInterrupt('pure test')
        child = MagicMock(pid=333, returncode=-15); child.poll.return_value = None
        child.communicate.side_effect = [failure, ('out', 'err')]
        with patch.object(subprocess, 'Popen', return_value=child), patch.object(os, 'killpg') as send:
            with self.assertRaises(KeyboardInterrupt) as result: bench.bounded_wrapper(['fake-wrapper'])
        self.assertIs(result.exception, failure); send.assert_called_once_with(333, signal.SIGTERM)
    def test_recorded_timeout_failure_has_evidence_and_releases_both_locks(self):
        args = argparse.Namespace(artifact_root=Path('/private/tmp/vphone-kernel-io-pure-copy'), guard_task8=True, label='pure-timeout', timeout=1)
        child = MagicMock(pid=222, returncode=None); child.wait.side_effect = subprocess.TimeoutExpired('owned', 1)
        cleanup = dict(signals=['SIGTERM', 'SIGKILL'], complete=False, error='TimeoutExpired')
        with patch.object(recorded, 'E', self.root), patch.object(Path, 'resolve', lambda value: value), \
             patch.object(os, 'open', side_effect=[701, 702]), patch.object(os, 'close') as close, \
             patch.object(recorded.fcntl, 'flock') as flock, patch.object(os, 'lstat', side_effect=FileNotFoundError), \
             patch.object(subprocess, 'check_output', side_effect=['', plistlib.dumps({'images': []})]), \
             patch.object(subprocess, 'Popen', return_value=child) as create, patch.object(recorded, 'terminate_owned', return_value=cleanup), \
             patch.object(signal, 'signal'), contextlib.redirect_stdout(io.StringIO()):
            code = recorded.run(args, ['fake-owned-child'], {}, {})
        result = json.loads((self.root / 'pure-timeout.json').read_text())
        self.assertEqual(code, 124); self.assertTrue(result['timed_out']); self.assertFalse(result['cleanup_complete'])
        self.assertEqual(result['cleanup_error'], 'TimeoutExpired'); self.assertEqual(result['child_pid'], 222)
        self.assertTrue(create.call_args.kwargs['start_new_session'])
        self.assertEqual(close.call_args_list, [call(701), call(702)]); self.assertEqual(flock.call_count, 2)
    def test_task8_tmp_alias_refuses_before_child_and_releases_lock(self):
        args = argparse.Namespace(artifact_root=None, guard_task8=True, label='pure-guard', timeout=1)
        with patch.object(recorded, 'E', self.root), patch.object(os, 'open', return_value=702), patch.object(os, 'close') as close, \
             patch.object(recorded.fcntl, 'flock'), patch.object(os, 'lstat', side_effect=FileNotFoundError), \
             patch.object(subprocess, 'check_output', return_value='12 vphone-vm --config /tmp/vphone-task8-acceptance-vms/task8-copy/config.plist'), \
             patch.object(subprocess, 'Popen') as create:
            with self.assertRaisesRegex(RuntimeError, 'VM is running'): recorded.run(args, ['fake'], {}, {})
        create.assert_not_called(); close.assert_called_once_with(702)
    def validate_virtual_variants(self, manifest, digests, texts, records):
        def read_text(path, *unused, **kwargs):
            return json.dumps(records[str(path)]) if str(path) in records else texts[str(path)]
        with patch.object(bench, 'digest', side_effect=lambda path: digests[str(path)]), \
             patch.object(Path, 'resolve', lambda value: value), patch.object(Path, 'read_text', read_text):
            return bench.validate_variants(manifest)
    def test_same_source_flags_and_distinct_virtual_artifacts_qualify(self):
        fixture = variant_fixture(); self.assertEqual(len(self.validate_virtual_variants(*fixture)), 3)
    def test_extra_compiler_flags_wrong_source_and_contract_are_rejected(self):
        for kind in ('extra_flags', 'wrong_test', 'untraced_timed', 'wrong_read_bytes', 'same_binary', 'wrong_platform', 'failed_build'):
            manifest, digests, texts, records = variant_fixture()
            second = manifest['variants'][1]
            if kind == 'extra_flags': records[second['build_record']]['command'] += ['-Xswiftc', '-Onone']
            elif kind == 'wrong_test':
                second['benchmark_test_sha256'] = '8' * 64
                digests[second['root'] + '/tests/FirmwarePatcherTests/FirmwareKernelIOBenchmarkTests.swift'] = '8' * 64
            elif kind == 'untraced_timed': second['trace'] = False
            elif kind == 'wrong_read_bytes': second['read_bytes'] = 1048576
            elif kind == 'same_binary':
                second['binary_sha256'] = manifest['variants'][0]['binary_sha256']
                digests[second['bundle'] + '/Contents/MacOS/vphone-cliPackageTests'] = second['binary_sha256']
            elif kind == 'wrong_platform': texts[second['root'] + '/Package.swift'] = '// swift-tools-version:6.0\nplatforms: [.macOS(.v14)]\n'
            else: records[second['build_record']]['exit_code'] = 1
            with self.subTest(kind=kind), self.assertRaises(RuntimeError): self.validate_virtual_variants(manifest, digests, texts, records)
    def prepare_fixture(self, directory, label='pure-manifest'):
        package = directory / 'Package.swift'
        declarations = ['.target(name: "' + name + '")' for name in ['VPhoneArchiveKit', 'VPhoneCore', 'VPhoneBundleStore', 'FirmwarePatcher']]
        declarations += ['.testTarget(name: "' + name + '")' for name in ['FirmwarePatcherTests', 'VPhoneBundleStoreTests']]
        raw = ('// swift-tools-version:6.0\nimport PackageDescription\nlet package = Package(\n    dependencies: [],\n    targets: [' + ',\n'.join(declarations) + '])\n').encode()
        package.write_bytes(raw)
        return package, raw, label
    def prepare_main(self, root, label):
        with patch.object(prepare, '__file__', str(self.root / 'prepare-test-manifest.py')), \
             patch.object(prepare.sys if hasattr(prepare, 'sys') else __import__('sys'), 'argv', ['prepare-test-manifest.py', str(root), '--label', label]), \
             contextlib.redirect_stdout(io.StringIO()):
            prepare.main()
    def test_prepare_manifest_collision_does_not_modify_ordinary_package(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp', prefix='vphone-kernel-io-pure-manifest-') as name:
            root = Path(name); package, original, label = self.prepare_fixture(root)
            (self.root / (label + '-manifest.json')).write_bytes(b'previous')
            with self.assertRaises(AssertionError): self.prepare_main(root, label)
            self.assertEqual(package.read_bytes(), original)
            self.assertEqual((self.root / (label + '-manifest.json')).read_bytes(), b'previous')
    def test_prepare_package_symlink_and_hardlink_are_rejected(self):
        for kind in ('symlink', 'hardlink'):
            with tempfile.TemporaryDirectory(dir='/private/tmp', prefix='vphone-kernel-io-pure-manifest-') as name:
                root = Path(name); package, original, label = self.prepare_fixture(root, 'pure-' + kind)
                backing = root / 'ordinary'; package.rename(backing)
                if kind == 'symlink': package.symlink_to(backing)
                else: os.link(backing, package)
                with self.subTest(kind=kind), self.assertRaises((OSError, AssertionError)): self.prepare_main(root, label)
                self.assertEqual(backing.read_bytes(), original)
    def test_prepare_evidence_is_reserved_before_ordinary_file_write(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp', prefix='vphone-kernel-io-pure-manifest-') as name:
            root = Path(name); package, original, label = self.prepare_fixture(root)
            # Both actual writes and locks are restricted to new ordinary test dirs.
            self.prepare_main(root, label)
            metadata = json.loads((self.root / (label + '-manifest.json')).read_text())
            self.assertEqual((self.root / (label + '-Package-full.swift')).read_bytes(), original)
            self.assertEqual(bench.hashlib.sha256(package.read_bytes()).hexdigest(), metadata['test_manifest_sha256'])


if __name__ == '__main__': unittest.main(verbosity=2)
