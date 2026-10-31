import base64
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image
import observe_t32_runtime as observation

class UnlockIsolationTests(unittest.TestCase):
    def test_unlock_timeout_is_preserved_while_display_is_observed(self):
        result={};events=[]
        with tempfile.TemporaryDirectory() as raw:
            def call(payload):
                if payload['t']=='file_get':return {'ok':True,'data':base64.b64encode(b'fixture').decode()}
                image=Image.new('RGB',(128,128),'black');image.paste('white',(0,0,64,64))
                if Path(payload['path']).name=='settings.png':image.paste('red',(64,64,128,128))
                image.save(payload['path']);return {'ok':True}
            def rpc(method,params):
                events.append(method)
                if method=='screen.unlock':raise RuntimeError('api_timeout; operation_may_continue=True')
                return {'bundle_id':'com.apple.Preferences','verified':True} if method=='apps.foreground' else {}
            with patch.object(observation.time,'sleep'):
                passed=observation.collect_observations(call,rpc,Path(raw),result)
            self.assertFalse(passed)
            self.assertEqual(result['observations']['display']['state'],'passed')
            self.assertEqual(result['observations']['unlock']['state'],'failed')
            self.assertIn('api_timeout',result['observations']['unlock']['error'])
            self.assertIn('apps.launch',events)
            self.assertEqual(events[-1],'apps.terminate')

    def test_unlock_and_display_failures_are_both_preserved(self):
        result={};events=[]
        def call(payload):
            if payload['t']=='file_get':return {'data':base64.b64encode(b'fixture').decode()}
            raise RuntimeError('screenshot unavailable')
        def rpc(method,params):
            events.append(method)
            if method=='screen.unlock':raise RuntimeError('api_timeout')
            return {}
        with tempfile.TemporaryDirectory() as raw, patch.object(observation.time,'sleep'):
            self.assertFalse(observation.collect_observations(call,rpc,Path(raw),result))
        self.assertIn('api_timeout',result['observations']['unlock']['error'])
        self.assertIn('screenshot unavailable',result['observations']['display']['error'])
        self.assertEqual(events[-1],'apps.terminate')

    def test_success_still_requires_verified_foreground_and_distinct_frames(self):
        result={}
        def call(payload):
            if payload['t']=='file_get':return {'data':base64.b64encode(b'fixture').decode()}
            image=Image.new('RGB',(128,128),'black');image.paste('white',(0,0,64,64))
            if Path(payload['path']).name=='settings.png':image.paste('red',(64,64,128,128))
            image.save(payload['path']);return {'ok':True}
        def rpc(method,params):
            return {'bundle_id':'com.apple.Preferences','verified':True} if method=='apps.foreground' else {}
        with tempfile.TemporaryDirectory() as raw, patch.object(observation.time,'sleep'):
            self.assertTrue(observation.collect_observations(call,rpc,Path(raw),result))
        self.assertEqual(result['observations']['unlock']['state'],'passed')
        self.assertEqual(result['observations']['display']['state'],'passed')

if __name__=='__main__':unittest.main()
