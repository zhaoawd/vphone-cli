"""Read-only review regressions using tiny ordinary JSON files; no controller run.

These tests intentionally demonstrate the initial controller's accepted inputs.
They must be inverted when the implementation rejects those inputs.
"""
import importlib.util
import json
import math
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

E = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('benchmark_controller', E / 'run-benchmarks.py')
bench = importlib.util.module_from_spec(spec); spec.loader.exec_module(bench)
SIZE = (1 << 20) + 3


def sample():
    return dict(event='measurement-end', label='pure-review', operation='capture', pid=123,
                monotonic_start_ns=10, monotonic_end_ns=100, elapsed_ns=90, elapsed_seconds=90 / 1e9,
                bytes=SIZE, observed_size=SIZE, result='passed', error=None, offsets_match=True,
                offsets=[0, 524288, 1044480, 1048576], expected_offsets=[0, 524288, 1044480, 1048576],
                original_sha256='1' * 64, candidate_sha256='2' * 64, rss_peak_after_bytes=1000)


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


class InitialBoundaryReproductions(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='kernel-io-controller-pure-')
        self.root = Path(self.temporary.name)
        self.external = patch.object(subprocess, 'run', side_effect=AssertionError('Native command forbidden'))
        self.external.start()
    def tearDown(self): self.external.stop(); self.temporary.cleanup()
    def log(self, end):
        path = self.root / 'sample.log'
        start = dict(event='measurement-start', label='pure-review', operation='capture', pid=123, monotonic_ns=5)
        path.write_text('\n'.join('kernel-io-benchmark ' + json.dumps(row) for row in [start, end]) + '\n')
        return path
    def test_valid_sample_control(self):
        self.assertEqual(bench.sample_from_log(self.log(sample()), 'pure-review', 'capture', SIZE)['elapsed_ns'], 90)
    def test_nan_seconds_initially_accepted(self):
        value = sample(); value['elapsed_seconds'] = float('nan')
        actual = bench.sample_from_log(self.log(value), 'pure-review', 'capture', SIZE)
        self.assertTrue(math.isnan(actual['elapsed_seconds']))
    def test_negative_or_inconsistent_seconds_initially_accepted(self):
        for seconds in (-10.0, 900.0):
            value = sample(); value['elapsed_seconds'] = seconds
            self.assertEqual(bench.sample_from_log(self.log(value), 'pure-review', 'capture', SIZE)['elapsed_seconds'], seconds)
    def test_empty_expected_offsets_initially_accepted(self):
        value = sample(); value['offsets'] = []; value['expected_offsets'] = []
        self.assertEqual(bench.sample_from_log(self.log(value), 'pure-review', 'capture', SIZE)['offsets'], [])
    def test_valid_trace_control(self):
        path = self.root / 'trace.jsonl'; path.write_text('\n'.join(json.dumps(row) for row in trace()) + '\n')
        self.assertEqual(bench.helper_trace(path, sample())['sha_calls'], 5)
    def test_compare_outside_helper_initially_accepted(self):
        path = self.root / 'trace.jsonl'; path.write_text('\n'.join(json.dumps(row) for row in trace(outside_compare=True)) + '\n')
        self.assertEqual(bench.helper_trace(path, sample())['compare_ns'], 3)
    def test_sha_wrong_role_distribution_initially_accepted(self):
        path = self.root / 'trace.jsonl'; path.write_text('\n'.join(json.dumps(row) for row in trace(all_candidate_sha=True)) + '\n')
        actual = bench.helper_trace(path, sample())
        self.assertEqual({row['role'] for row in actual['sha_callsites']}, {'candidate_image'})
    def test_incomplete_stderr_and_footer_are_already_rejected(self):
        path = self.log(sample()); path.write_text(path.read_text() + '[kernel-io-trace] measurement incomplete\n')
        with self.assertRaises(RuntimeError): bench.sample_from_log(path, 'pure-review', 'capture', SIZE)
        path = self.root / 'trace.jsonl'; rows = trace(); rows[-1]['complete'] = False
        path.write_text('\n'.join(json.dumps(row) for row in rows) + '\n')
        with self.assertRaises(ValueError): bench.helper_trace(path, sample())


if __name__ == '__main__': unittest.main(verbosity=2)
