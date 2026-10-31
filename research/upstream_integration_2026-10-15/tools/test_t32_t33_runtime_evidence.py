"""Check rejection of incomplete and unrelated runtime evidence using fixtures."""
import base64
import copy
import hashlib
import io
import unittest

from PIL import Image

from t32_t33_runtime_evidence import complete_file_digest, settings_build_evidence


class RuntimeEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.front = dict(bundle_id='com.apple.Preferences', pid=123, verified=True)
        image = io.BytesIO(); Image.new('RGB', (100, 120), 'gray').save(image, format='JPEG')
        data = image.getvalue()
        self.description = dict(frontmost=copy.deepcopy(self.front), context_changed=False,
            elements=dict(source='ax', pid=123, truncated=False, elements=[
                dict(label='iOS Version', value='26.0 (23Z999999)', visible=True,
                     frame=dict(x=10, y=20, width=80, height=30))]),
            screenshot=dict(data=base64.b64encode(data).decode(), bytes=len(data),
                            width=100, height=120, mime_type='image/jpeg', coordinate_scale=1))

    def assess(self):
        return settings_build_evidence(self.front, self.description, self.front, '23Z999999')

    def test_visible_build_is_evidence_pending_visual_review(self):
        result = self.assess()
        self.assertEqual(result['visibleAXMatches'][0]['text'], '26.0 (23Z999999)')
        self.assertTrue(result['visualReviewRequired'])
        self.assertFalse(result['runtimeValidated'])
        self.assertFalse(result['patchCausalityValidated'])
        self.assertNotIn('data', result['screenshot'])

    def test_same_bundle_with_different_pid_is_rejected(self):
        after = dict(self.front, pid=124)
        with self.assertRaisesRegex(ValueError, 'process changed'):
            settings_build_evidence(self.front, self.description, after, '23Z999999')

    def test_unverified_or_invalid_pid_is_rejected(self):
        for update in (dict(verified=False), dict(pid=True), dict(pid=0)):
            with self.subTest(update=update), self.assertRaises(ValueError):
                settings_build_evidence(dict(self.front, **update), self.description, self.front, '23Z999999')

    def test_ax_must_be_complete_and_from_same_process(self):
        original = copy.deepcopy(self.description)
        for update in (dict(pid=124), dict(source='ocr'), dict(truncated=True), dict(error='AX failed')):
            self.description = copy.deepcopy(original)
            self.description['elements'].update(update)
            with self.subTest(update=update), self.assertRaises(ValueError): self.assess()

    def test_context_change_is_rejected(self):
        self.description['context_changed'] = True
        with self.assertRaises(ValueError): self.assess()

    def test_identifier_invisible_and_similar_tokens_do_not_prove_display(self):
        original = copy.deepcopy(self.description)
        for update in (dict(value='26.0', identifier='23Z999999'), dict(visible=False),
                       dict(value='23Z9999999'), dict(value='x23Z999999'), dict(value='23Z999999x')):
            self.description = copy.deepcopy(original)
            self.description['elements']['elements'][0].update(update)
            with self.subTest(update=update), self.assertRaises(ValueError): self.assess()

    def test_invalid_element_geometry_is_rejected(self):
        self.description['elements']['elements'][0]['frame']['width'] = float('nan')
        with self.assertRaises(ValueError): self.assess()

    def test_screenshot_must_decode_and_match_its_metadata(self):
        original = copy.deepcopy(self.description)
        for update in (dict(data='not base64'), dict(width=99), dict(bytes=0)):
            self.description = copy.deepcopy(original)
            self.description['screenshot'].update(update)
            with self.subTest(update=update), self.assertRaises(ValueError): self.assess()

    def test_complete_file_reply_returns_only_digest(self):
        data = b'fixture file'
        reply = dict(path='/private/xarts/AA.gl', encoding='base64', truncated=False,
                     size=len(data), content=base64.b64encode(data).decode())
        result = complete_file_digest(reply, reply['path'])
        self.assertEqual(result['sha256'], hashlib.sha256(data).hexdigest())
        self.assertNotIn('content', result)
        for update in (dict(truncated=True), dict(size=999), dict(size=True),
                       dict(path='/other'), dict(encoding='utf8'), dict(content='bad!')):
            with self.subTest(update=update), self.assertRaises(ValueError):
                complete_file_digest(dict(reply, **update), reply['path'])


if __name__ == '__main__':
    unittest.main()
