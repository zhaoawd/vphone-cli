"""Check binary log redaction while preserving the caller's actual response."""
import base64
import copy
import hashlib
import unittest
from unittest.mock import patch

import t32_runtime_hash_only_transport as transport


class Recorder:
    def __init__(self):
        self.rows = []

    def record(self, target, payload, response):
        self.rows.append((target, payload, copy.deepcopy(response)))


class RuntimeHashOnlyTransportTests(unittest.TestCase):
    raw = b'fixture-only-gigalocker'

    def observe(self, payload, response, recorder=None):
        recorder = recorder or Recorder()

        def backend(target, request, log, timeout):
            self.assertEqual(timeout, 20)
            log.record(target, request, response)
            return response

        with patch.object(transport, 'budgeted_request', side_effect=backend):
            actual = transport.request('fixture-target', payload, recorder, 20)
        self.assertIs(actual, response)
        return recorder

    def binary(self):
        return base64.b64encode(self.raw).decode()

    def test_nested_file_content_is_hashed_and_caller_still_receives_bytes(self):
        payload = dict(t='rpc', method='files.read', params=dict(path='/private/xarts/AA.gl', binary=True))
        response = dict(ok=True, result=dict(path='/private/xarts/AA.gl', encoding='base64',
            content=self.binary(), size=len(self.raw), truncated=False))
        recorder = self.observe(payload, response)
        logged = recorder.rows[0][2]['result']
        self.assertNotIn('content', logged)
        self.assertEqual(logged['contentBytes'], len(self.raw))
        self.assertEqual(logged['contentSHA256'], hashlib.sha256(self.raw).hexdigest())
        self.assertEqual(response['result']['content'], self.binary())
        self.assertFalse(logged['truncated'])

    def test_ui_description_image_is_hashed_and_ax_text_is_preserved(self):
        payload = dict(t='rpc', method='ui.describe', params={})
        response = dict(ok=True, result=dict(screenshot=dict(data=self.binary(), bytes=len(self.raw)),
            elements=dict(elements=[dict(label='26.0 (23Z999999)', visible=True)]), context_changed=False))
        logged = self.observe(payload, response).rows[0][2]['result']
        self.assertNotIn('data', logged['screenshot'])
        self.assertEqual(logged['screenshot']['dataSHA256'], hashlib.sha256(self.raw).hexdigest())
        self.assertEqual(logged['elements'], response['result']['elements'])
        self.assertFalse(logged['context_changed'])

    def test_classic_binary_fields_are_hashed(self):
        response = dict(ok=True, data=self.binary(), image=self.binary())
        logged = self.observe(dict(t='file_get', path='/private/xarts/AA.gl'), response).rows[0][2]
        for key in ('data', 'image'):
            self.assertNotIn(key, logged)
            self.assertEqual(logged[key+'Bytes'], len(self.raw))

    def test_malformed_binary_does_not_reach_log(self):
        recorder = Recorder()
        payload = dict(t='rpc', method='files.read', params=dict(binary=True))
        response = dict(ok=True, result=dict(encoding='base64', content='not!base64'))
        with self.assertRaises(ValueError):
            self.observe(payload, response, recorder)
        self.assertEqual(recorder.rows, [])

    def test_unexpected_text_for_binary_read_does_not_reach_log(self):
        recorder = Recorder()
        payload = dict(t='rpc', method='files.read', params=dict(binary=True))
        response = dict(ok=True, result=dict(encoding='utf8', content='fixture secret'))
        with self.assertRaises(ValueError):
            self.observe(payload, response, recorder)
        self.assertEqual(recorder.rows, [])

    def test_errors_and_truncation_are_preserved(self):
        error = dict(ok=False, error='open failed: Operation not permitted')
        payload = dict(t='rpc', method='files.read', params=dict(binary=True))
        self.assertEqual(self.observe(payload, error).rows[0][2], error)
        response = dict(ok=True, result=dict(encoding='base64', content=self.binary(),
                                             size=9999, truncated=True))
        logged = self.observe(payload, response).rows[0][2]['result']
        self.assertTrue(logged['truncated'])
        self.assertEqual(logged['size'], 9999)
        self.assertNotIn('content', logged)


if __name__ == '__main__':
    unittest.main()
