"""Exercise the real diagnostic runner across download and stop failures."""
import base64
import contextlib
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import run_t52_capture_source_diagnostic as runner


class CaptureSourceCleanupTests(unittest.TestCase):
    def run_case(self, *, stop_timeout=False, download_failure=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); vm = root / 'vm'; vm.mkdir()
            (vm / '.vphone-runtime.json').write_text(json.dumps(dict(instanceID='test-instance')))
            original = root / 'original'; original.write_bytes(b'original-executable')
            original_sha = hashlib.sha256(original.read_bytes()).hexdigest()
            current_sha = hashlib.sha256(b'diagnostic-executable').hexdigest()
            output = root / 'evidence'; restored = False; stop_calls = 0; requests = []
            def restore(*args, **kwargs):
                nonlocal restored
                restored = True
                return subprocess.CompletedProcess(args[0], 0, '', '')
            def request(target, payload, recorder, timeout):
                nonlocal stop_calls
                requests.append(payload)
                if payload['t'] == 'rpc':
                    if payload['method'] == 'apps.terminate':
                        stop_calls += 1
                        if stop_timeout and stop_calls == 2:
                            return dict(ok=False, error='api_timeout', operation_may_continue=True)
                    return dict(ok=True, result={})
                if payload['t'] == 'file_put': return dict(ok=True)
                if payload['path'].endswith('/T52Acceptance'):
                    return dict(ok=True, data=base64.b64encode(original.read_bytes() if restored else b'diagnostic-executable').decode())
                if download_failure: return dict(ok=False, error='download_failed')
                # Model the actual host's inline limit and exclusive download.
                if not payload.get('save'): return dict(ok=False, error='file_too_large')
                phase = json.loads((output / 'request.json').read_text())
                record = dict(runID=phase['runID'], events=[dict(type='camera_discovery_readonly', devices=[])], padding='x' * (1024 * 1024 + 1))
                with Path(payload['save']).open('x') as stream: json.dump(record, stream)
                return dict(ok=True)
            argv = ['runner', '--instance-id', 'test-instance', '--expected-current', current_sha, '--output', str(output)]
            with patch.object(runner, 'VM', vm), patch.object(runner, 'RESTORE', original), patch.object(runner, 'RESTORE_SHA', original_sha), patch.object(runner, 'endpoint', return_value='endpoint'), patch.object(runner, 'request', side_effect=request), patch.object(runner.subprocess, 'run', side_effect=restore) as deploy, patch.object(sys, 'argv', argv), contextlib.redirect_stdout(io.StringIO()):
                code = runner.main()
            result = json.loads((output / 'result.json').read_text())
            self.assertTrue(result['probeRestored'])
            deploy.assert_called_once()
            self.assertIn('--expected-current', deploy.call_args.args[0])
            self.assertEqual(code, 1 if download_failure else 0)
            self.assertEqual(result.get('captured'), not download_failure)
            if stop_timeout: self.assertIn('api_timeout', result['probeStopError'])
            if not download_failure:
                self.assertGreater((output / 'record.json').stat().st_size, 1024 * 1024)
                self.assertTrue(any(p.get('save') for p in requests))

    def test_large_observation_downloads_and_restores(self):
        self.run_case()

    def test_uncertain_stop_still_restores(self):
        self.run_case(stop_timeout=True)

    def test_download_failure_still_restores(self):
        self.run_case(download_failure=True, stop_timeout=True)


if __name__ == '__main__': unittest.main()
