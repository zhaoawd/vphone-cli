import copy
import unittest

from verify_t52_application_observation import BUNDLE_ID, verify


class ApplicationObservationTests(unittest.TestCase):
    def setUp(self):
        # Synthetic unit-test inputs only. These are not VM acceptance evidence.
        self.expected = dict(latitude=31.2, longitude=121.5, altitude=20,
                             horizontalAccuracy=5, verticalAccuracy=6, speed=2, course=90)
        self.record = dict(schemaVersion=1, bundleID=BUNDLE_ID, runID='unit-run', pid=404,
                           mode='location', startedAt=100, events=[
            dict(type='location_callback', time=101, timestamp=101, **self.expected),
            dict(type='location_callback', time=102, timestamp=102, **self.expected)])

    def check(self, record=None, **changes):
        args = dict(run_id='unit-run', pid=404, mode='location', expected=self.expected)
        args.update(changes)
        return verify(self.record if record is None else record, **args)

    def test_location_requires_consumer_callbacks_not_control_state(self):
        self.assertEqual(self.check()['callbacks'], 2)
        for events in ([], [dict(type='location.current', time=101, **self.expected)], self.record['events'][:1]):
            with self.subTest(events=events), self.assertRaises(ValueError):
                self.check(dict(self.record, events=events))

    def test_identity_and_phase_must_match(self):
        for key, value in [('runID', 'old-run'), ('pid', 405), ('bundleID', 'other'), ('mode', 'camera')]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.check(dict(self.record, **{key: value}))

    def test_stale_invalid_and_mismatched_points_fail(self):
        for key, value in [('time', 99), ('timestamp', 90), ('longitude', -121.5), ('altitude', 21), ('speed', float('nan'))]:
            record = copy.deepcopy(self.record)
            record['events'][-1][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.check(record)

    def test_all_expected_location_fields_are_required(self):
        with self.assertRaises(ValueError):
            self.check(expected=dict(latitude=31.2, longitude=121.5))

    def test_camera_requires_started_virtual_device_and_exact_content(self):
        record = dict(self.record, mode='camera', events=[dict(type='camera_device', time=101, uniqueID='vphone:vcam:0'),
            dict(type='camera_started', time=102), dict(type='camera_metadata', time=103, message='unique-unit-qr')])
        self.assertEqual(self.check(record, mode='camera', expected='unique-unit-qr')['callbacks'], 1)
        for replacement in [dict(type='camera_device', time=101, uniqueID='other'),
                            dict(type='camera_metadata', time=103, message='old-qr')]:
            wrong = copy.deepcopy(record)
            wrong['events'][0 if replacement['type'] == 'camera_device' else 2] = replacement
            with self.subTest(replacement=replacement), self.assertRaises(ValueError):
                self.check(wrong, mode='camera', expected='unique-unit-qr')
        with self.assertRaises(ValueError):
            self.check(dict(record, events=record['events'][::2]), mode='camera', expected='unique-unit-qr')

    def test_errors_cannot_be_hidden_by_later_samples(self):
        record = copy.deepcopy(self.record)
        record['events'].append(dict(type='location_error', time=103, message='denied'))
        with self.assertRaises(ValueError):
            self.check(record)


if __name__ == '__main__':
    unittest.main()
