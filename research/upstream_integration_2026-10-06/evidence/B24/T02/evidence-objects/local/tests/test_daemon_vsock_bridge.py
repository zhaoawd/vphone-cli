"""Exercise the production blocking transport with real bounded pipe backpressure."""
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]

@unittest.skipUnless(sys.platform=='darwin' and shutil.which('clang'),'macOS clang required')
class VsockBridgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix='vphone-bridge-')
        cls.binary=Path(cls.temp.name)/'bridge'
        subprocess.run(['clang','-Wall','-Wextra','-Werror','-pthread',str(ROOT/'tests/fixtures/daemon_vsock_bridge/main.c'),'-o',str(cls.binary)],check=True,capture_output=True)
    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()

    def run_bridge(self,early=False,slow=False,hold_open=False):
        p=subprocess.Popen([str(self.binary)]+(["hold-open"] if hold_open else []),stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            port=int(p.stdout.readline())
            with socket.create_connection(('127.0.0.1',port),timeout=5) as s:
                payload=bytes(range(251))*37
                s.sendall(payload)
                if not hold_open:s.shutdown(socket.SHUT_WR)
                if early:
                    s.recv(8192)
                else:
                    data=bytearray()
                    while True:
                        chunk=s.recv(1024 if slow else 65536)
                        if not chunk:break
                        data.extend(chunk)
                    expected=bytes(range(251))*8356
                    self.assertEqual(bytes(data),expected)
                if hold_open:
                    out,err=p.communicate(timeout=8)
                    self.assertEqual(p.returncode,0,(out,err))
                    self.assertIn("active=0",out)
            out,err=p.communicate(timeout=8)
            self.assertEqual(p.returncode,0,(out,err))
            self.assertIn('active=0',out)
        finally:
            if p.poll() is None:p.kill()
            p.communicate(timeout=5)

    def test_response_after_request_half_close_and_complete_tail(self):self.run_bridge()
    def test_small_reads_preserve_large_response(self):self.run_bridge(slow=True)
    def test_early_close_releases_both_directions(self):self.run_bridge(early=True)

    def test_nio_output_close_releases_peer_with_open_send_direction(self):self.run_bridge(hold_open=True)
