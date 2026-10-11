import json, unittest
from attribution_filter import tcc, vm

class AttributionEvidenceTests(unittest.TestCase):
    def test_retains_frozen_identity_and_drops_coordinates_and_unknown_fields(self):
        event = {'timestamp': '2026-10-11T15:40:00.000Z', 'processID': 123, 'category': '37.123456',
                 'eventMessage': 'AUTH attribution vphone-vm responsible={identifier=com.vphone.cli, pid=10, binary_path=/frozen/vphone-vm, latitude=37.123456} location=121.987654'}
        result = tcc(event, {'/frozen/vphone-vm'}, {'vphone-vm', 'com.vphone.cli'})
        self.assertEqual(result['identities'], [{'role': 'responsible', 'identifier': 'com.vphone.cli', 'pid': 10, 'binary_path': '/frozen/vphone-vm'}])
        self.assertNotIn('37.123456', json.dumps(result))
        self.assertNotIn('121.987654', json.dumps(result))
        self.assertNotIn('eventMessage', result)

    def test_unknown_identity_remains_unconfirmed(self):
        result = tcc({'eventMessage': 'request vphone-vm accessing={identifier=37.123456, binary_path=/vphone-vm/121.987654, pid=<private>}', 'timestamp': '37.123456', 'processID': '121.987654'}, set(), {'vphone-vm'})
        self.assertEqual(result['identities'], [{'role': 'accessing'}])
        self.assertIsNone(result['timestamp'])
        self.assertIsNone(result['processID'])
        self.assertNotIn('37.123456', json.dumps(result))
        self.assertNotIn('121.987654', json.dumps(result))

    def test_unrelated_events_are_dropped(self):
        self.assertIsNone(tcc({'eventMessage': 'locationd got latitude=37.123456'}, set(), set()))

    def test_vm_sample_is_a_marker(self):
        self.assertEqual(vm('[location] got location: 37.123456,121.987654 (+/-5m)'), '[location] location sample received')
        self.assertEqual(vm('[location] authorization status: 3'), '[location] authorization status: 3')
        self.assertIsNone(vm('[location] authorization status: 3 latitude=37.123456'))
        self.assertIsNone(vm('[location] applied preset: 37.123456,121.987654'))

if __name__ == '__main__': unittest.main()
