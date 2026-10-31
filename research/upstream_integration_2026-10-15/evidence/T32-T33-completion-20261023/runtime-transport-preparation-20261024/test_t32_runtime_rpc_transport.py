"""Run the real observer over an isolated Unix socket, without booting a VM."""
import base64
import contextlib
import hashlib
import io
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import observe_t32_runtime as observer
import t32_runtime_rpc_transport as transport
from host_control_client import request as raw_request
from PIL import Image


class RuntimeRPCTransportTests(unittest.TestCase):
    def observe(self, corrected, *, gigalocker_error=False, verified=True, delay=.25):
        with tempfile.TemporaryDirectory(prefix='t32rpc-', dir='/private/tmp') as temporary:
            root = Path(temporary); vm = root / 'vm'; vm.mkdir(); work = root / 'work'; work.mkdir()
            window = work / 'boot-window'; window.mkdir()
            image = vm / 'Disk.img'; image.write_bytes(b'isolated disk fixture')
            binary = root / 'vm-fixture'; binary.write_bytes(b'not executed')
            s = image.stat(); identity = dict(dev=s.st_dev, ino=s.st_ino, size=s.st_size, mtime_ns=s.st_mtime_ns)
            plan = dict(vm=str(vm), vmExecutable=str(binary), expectedDiskIdentity=dict(identity, ctime_ns=s.st_ctime_ns),
                        vmSHA256=hashlib.sha256(binary.read_bytes()).hexdigest())
            (work / 'runtime-backup.json').write_text(json.dumps(dict(files={'Disk.img':dict(sourceIdentity=identity)})))
            (vm / '.vphone-runtime.json').write_text(json.dumps(dict(pid=4242, operation='boot')))
            (window / 'helper-state.json').write_text(json.dumps(dict(state='running', attempt=1, deadline=time.time()+900)))
            (window / 'amfid-cleanup.json').write_text(json.dumps(dict(passed=True)))
            (window / 'supervisor-stop.json').write_text(json.dumps(dict(withinDeadline=True, workerPID=1, supervisorPID=2)))
            server = socket.socket(socket.AF_UNIX); server.bind(str(vm / 'vphone.sock')); server.listen()
            server.settimeout(.1); stopping = threading.Event(); backend_errors = []; received = []; budgets = []
            frames = []
            for offset in (0, 1):
                frame = Image.new('RGB', (100, 100))
                frame.putdata([((x*31+offset*17)%256, (x*7)%256, (x*13)%256) for x in range(10000)])
                content = io.BytesIO(); frame.save(content, format='PNG'); frames.append(content.getvalue())

            def serve():
                frame_index = 0
                while not stopping.is_set():
                    try: connection, _ = server.accept()
                    except socket.timeout: continue
                    except OSError: return
                    try:
                        with connection:
                            data = bytearray()
                            while b'\n' not in data:
                                part = connection.recv(4096)
                                if not part: break
                                data.extend(part)
                            if not data: continue
                            payload = json.loads(data); received.append(payload)
                            if payload['t'] == 'capabilities':
                                result = dict(ok=True, guest_connected=True, screen_available=True)
                            elif payload['t'] == 'file_get':
                                result = (dict(ok=False, msg='open failed: Operation not permitted') if gigalocker_error
                                          else dict(ok=True, data=base64.b64encode(b'fixture gigalocker').decode()))
                            elif payload['t'] == 'screenshot':
                                Path(payload['path']).write_bytes(frames[frame_index]); frame_index += 1
                                result = dict(ok=True)
                            else:
                                method = payload['method']
                                if method == 'apps.launch':
                                    # At this scale, 0.25 s models a valid 50 s RPC:
                                    # it exceeds the caller's 20 s but fits 75 s.
                                    threading.Event().wait(delay)
                                value = (dict(bundle_id='com.apple.Preferences', verified=verified)
                                         if method == 'apps.foreground' else {})
                                result = dict(ok=True, result=value)
                            try: connection.sendall(json.dumps(result).encode()+b'\n')
                            except BrokenPipeError: pass
                    except Exception as error:
                        backend_errors.append(error)

            class Child:
                pid = 4242
                def __init__(self, *args, **kwargs):
                    self.stopped = False; self.log = Path(kwargs['stdout'].name)
                def poll(self): return 0 if self.stopped else None
                def wait(self, timeout):
                    self.stopped = True
                    with self.log.open('ab') as output: output.write(b'Guest stopped\n')
                    return 0

            def scaled_request(target, payload, recorder, timeout):
                budgets.append((payload.copy(), timeout))
                return raw_request(target, payload, recorder, timeout*.005)

            thread = threading.Thread(target=serve); thread.start()
            try:
                with patch.object(observer, 'WORK', work), patch.object(observer, 'approved_plan', return_value=plan), \
                     patch.object(observer.subprocess, 'Popen', Child), \
                     patch.object(observer.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)), \
                     patch.object(observer.time, 'sleep'), \
                     patch.object(observer, 'request', transport.request if corrected else scaled_request), \
                     patch.object(transport, 'host_request', scaled_request), \
                     patch.object(sys, 'argv', ['observer', '--execute-approved-runtime-plan', 'fixture']), \
                     contextlib.redirect_stdout(io.StringIO()):
                    code = observer.main()
                result = json.loads((work / 'runtime-observation/result.json').read_text())
            finally:
                stopping.set(); thread.join(timeout=2); server.close()
            self.assertFalse(thread.is_alive()); self.assertEqual(backend_errors, [])
            return code, result, received, budgets

    def test_rpc_budget_covers_a_valid_slow_reply_through_actual_observer(self):
        code, result, _, budgets = self.observe(True)
        self.assertEqual(code, 0, result)
        self.assertEqual(result['state'], 'observed')
        self.assertTrue(result['guestStopped'])
        self.assertEqual([b for p, b in budgets if p['t'] == 'capabilities'], [5])
        self.assertTrue(all(b == 20 for p, b in budgets if p['t'] in ('file_get', 'screenshot')))
        self.assertTrue(all(75 < b <= 100 for p, b in budgets if p['t'] == 'rpc'))

    def test_legacy_observer_reproduces_outer_socket_timeout(self):
        code, result, requests, _ = self.observe(False)
        self.assertEqual(code, 1); self.assertEqual(result['state'], 'failed')
        self.assertEqual(result['observations']['display']['state'], 'failed')
        self.assertIn('timed out', result['observations']['display']['error'])
        self.assertTrue(any(p.get('method') == 'apps.launch' for p in requests))

    def test_current_deadline_accepts_immediate_valid_reply(self):
        code, result, _, _ = self.observe(False, delay=0)
        self.assertEqual(code, 0, result)
        self.assertEqual(result['observations']['display']['state'], 'passed')

    def test_gigalocker_failure_is_preserved_when_display_passes(self):
        code, result, _, _ = self.observe(True, gigalocker_error=True)
        self.assertEqual(code, 1); self.assertEqual(result['state'], 'failed')
        self.assertEqual(result['observations']['display']['state'], 'passed')
        self.assertEqual(result['observations']['gigalocker']['state'], 'failed')
        self.assertIn('Operation not permitted', result['observations']['gigalocker']['error'])

    def test_unverified_foreground_still_fails_display(self):
        code, result, _, _ = self.observe(True, verified=False)
        self.assertEqual(code, 1); self.assertEqual(result['observations']['display']['state'], 'failed')
        self.assertIn('foreground not confirmed', result['observations']['display']['error'])


if __name__ == '__main__':
    unittest.main()
