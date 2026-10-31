import copy
import json
from pathlib import Path
import tempfile
import unittest
from run_t52_camera_consumer import check_neutral, check_receipt, read_application_record


class CameraConsumerTests(unittest.TestCase):
    def test_oversized_previous_observation_downloads_without_accepting_stale_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            previous = self.record(); previous['padding'] = 'x' * (1024 * 1024 + 1)
            calls = []
            def call(payload):
                calls.append(payload)
                if 'save' not in payload: return dict(ok=False, code='file_too_large')
                with Path(payload['save']).open('x') as stream: json.dump(previous, stream)
                return dict(ok=True)
            record = read_application_record(call, output)
            self.assertEqual(record, previous)
            self.assertEqual(len(calls), 2)
            self.assertGreater(Path(calls[1]['save']).stat().st_size, 1024 * 1024)
            with self.assertRaises(ValueError): check_neutral(record, 'different-current-run', 42)

    def record(self):
        return dict(schemaVersion=1, bundleID='org.vphone.acceptance.t52.20261022', runID='named', pid=42,
                    mode='camera', startedAt=100, events=[dict(type='camera_device', uniqueID='vphone:vcam:0', time=101),
                                                          dict(type='camera_started', time=102)])

    def test_neutral_requires_named_active_virtual_consumer_and_no_metadata(self):
        check_neutral(self.record(), 'named', 42)
        for changed in ('pid', 'device', 'error', 'metadata', 'missing_start', 'stale'):
            record = self.record()
            if changed == 'pid': record['pid'] = 2
            if changed == 'device': record['events'][0]['uniqueID'] = 'physical'
            if changed == 'error': record['events'].append(dict(type='camera_error', time=103))
            if changed == 'metadata': record['events'].append(dict(type='camera_metadata', message='QR', time=103))
            if changed == 'missing_start': record['events'].pop()
            if changed == 'stale': record['events'][1]['time'] = 10
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                check_neutral(record, 'named', 42)

    def test_transport_requires_both_indices_and_exact_generation_and_presentation(self):
        receipt = dict(semantics='presentation_frame_copied', presentation_id='one', generation='named',
                       vphoned_published_frame_index=10, libvcam_observed_frame_index=9)
        response = dict(ok=True, protocol_version=3, generation='named', presentation_id='one', transport_receipt=receipt)
        self.assertEqual(check_receipt(response, 'named'), receipt)
        for key, value in [('generation', 'other'), ('presentation_id', 'old'),
                           ('vphoned_published_frame_index', 0), ('libvcam_observed_frame_index', 11),
                           ('libvcam_observed_frame_index', True)]:
            wrong = copy.deepcopy(response); wrong['transport_receipt'][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                check_receipt(wrong, 'named')


if __name__ == '__main__': unittest.main()
