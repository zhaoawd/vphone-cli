import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('analysis', Path(__file__).with_name('analyze-trace.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class TraceTests(unittest.TestCase):
    def events(self):
        span = dict(type='span', schema_version=1, id=1, parent_id=None, pid=42, thread_id=1,
                    phase='sha', caller_file='File.swift', caller_line=10, caller_function='test',
                    started_ns=10, elapsed_ns=20, inclusive=True, outcome='success', counts={'bytes': 4096},
                    labels={'role': 'live_disk', 'byte_semantics': 'consumer_actual'})
        end = dict(type='measurement_end', schema_version=1, pid=42, complete=True, events=1, dropped=0, open_spans=0, io_error=None)
        return [span, end]

    def run_events(self, events):
        return module.analyze('\n'.join(json.dumps(event) for event in events))

    def test_actual_counts_and_inclusive_time(self):
        result = self.run_events(self.events())
        self.assertEqual(result['groups'][0]['counts']['bytes'], 4096)
        self.assertEqual(result['groups'][0]['cumulative_inclusive_ns'], 20)

    def test_missing_footer(self):
        with self.assertRaises(ValueError): self.run_events(self.events()[:-1])

    def test_incomplete_or_truncated_trace(self):
        for key, value in [('complete', False), ('dropped', 1), ('open_spans', 1), ('events', 2), ('io_error', 'failure')]:
            events = self.events(); events[-1][key] = value
            with self.assertRaises(ValueError): self.run_events(events)

    def test_invalid_counts_and_intervals(self):
        for key, value in [('elapsed_ns', -1), ('started_ns', -1), ('inclusive', False), ('outcome', 'unknown')]:
            events = self.events(); events[0][key] = value
            with self.assertRaises(ValueError): self.run_events(events)
        events = self.events(); events[0]['counts']['bytes'] = True
        with self.assertRaises(ValueError): self.run_events(events)

    def test_parent_must_exist(self):
        events = self.events(); events[0]['parent_id'] = 2
        with self.assertRaises(ValueError): self.run_events(events)

    def test_nested_spans_not_summed(self):
        events = self.events(); child = dict(events[0], id=2, parent_id=1, phase='read', started_ns=12, elapsed_ns=5)
        events.insert(1, child); events[-1]['events'] = 2
        result = self.run_events(events)
        self.assertEqual(len(result['groups']), 2)
        self.assertNotIn('total_ns', result)

    def test_wrong_parent_interval_and_thread(self):
        for update in [dict(started_ns=0), dict(elapsed_ns=40), dict(thread_id=2)]:
            events = self.events(); child = dict(events[0], id=2, parent_id=1, phase='read', started_ns=12, elapsed_ns=5)
            child.update(update); events.insert(1, child); events[-1]['events'] = 2
            with self.assertRaises(ValueError): self.run_events(events)

    def test_duplicate_keys_and_ids(self):
        with self.assertRaises(ValueError): module.analyze('{"type":"span","type":"span"}')
        events = self.events(); events.insert(1, dict(events[0])); events[-1]['events'] = 2
        with self.assertRaises(ValueError): self.run_events(events)

    def test_strict_protocol_types(self):
        for index, key, value in [(1, 'schema_version', True), (1, 'pid', None), (1, 'dropped', False),
                                  (1, 'open_spans', False), (1, 'io_error', ''), (0, 'thread_id', None),
                                  (0, 'parent_id', False), (0, 'caller_file', ''), (0, 'caller_line', True),
                                  (0, 'caller_function', None)]:
            events = self.events(); events[index][key] = value
            with self.assertRaises(ValueError): self.run_events(events)

    def test_same_group_overlap_is_explicit(self):
        events = self.events(); events.insert(1, dict(events[0], id=2, parent_id=1, started_ns=12, elapsed_ns=5))
        events[-1]['events'] = 2
        group = self.run_events(events)['groups'][0]
        self.assertEqual(group['cumulative_inclusive_ns'], 25)
        self.assertEqual(group['interval_union_ns_by_thread'], {'1': 20})
        self.assertTrue(group['overlapping_spans_same_thread'])


if __name__ == '__main__': unittest.main()
