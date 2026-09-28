"""Loopback HTTP/WebSocket fixture; never connects to a VM."""
import base64
import hashlib
import json
from pathlib import Path
import struct
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

root = Path(sys.argv[1])
token = '1234567890abcdef'


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def reply(self, status, value):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.headers.get('Authorization') != 'Bearer ' + token:
            return self.reply(401, {'error': 'unauthorized'})
        if self.path.startswith('/redirect/'):
            self.send_response(302)
            self.send_header('Location', '/followed/v1/health')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if self.path.startswith('/followed/'):
            (root / 'followed').write_text('redirect was followed')
        if self.path.endswith('/v1/events'):
            return self.websocket()
        if self.path.startswith('/slow/'):
            time.sleep(2)
        if self.path.startswith('/large/'):
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(8 * 1024 * 1024 + 1))
            self.end_headers()
            self.wfile.write(b'{')
            self.wfile.flush()
            return
        if self.path.startswith('/chunked-large/'):
            self.send_response(200)
            self.send_header('Transfer-Encoding', 'chunked')
            self.end_headers()
            chunk = b'x' * 65536
            for _ in range(129):
                self.wfile.write(b'10000\r\n' + chunk + b'\r\n')
            self.wfile.write(b'0\r\n\r\n')
            return
        self.reply(200, {'status': 'ok', 'api_version': 1, 'binary_hash': 'a' * 64,
                         'capabilities': ['files'], 'ios': '26.0'})

    def do_POST(self):
        if self.headers.get('Authorization') != 'Bearer ' + token:
            return self.reply(401, {'error': 'unauthorized'})
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        result = {'type': 'response', 'id': request['id'], 'result': request['params']}
        status = 200
        if self.path.startswith('/wrong/'):
            result['id'] = 'different'
        if self.path.startswith('/error/'):
            result.pop('result')
            result['error'] = {'code': 'denied', 'message': 'fixture error'}
            status = 400
        if self.path.startswith('/status/'):
            status = 503
        self.reply(status, result)

    def frame(self, value):
        data = json.dumps(value).encode()
        header = bytes([0x81, len(data)]) if len(data) < 126 else b'\x81\x7e' + struct.pack('!H', len(data))
        self.wfile.write(header + data)
        self.wfile.flush()

    def read_frame(self):
        header = self.rfile.read(2)
        if len(header) != 2 or header[0] & 15 == 8:
            return None
        size = header[1] & 127
        if size == 126:
            size = struct.unpack('!H', self.rfile.read(2))[0]
        elif size == 127:
            size = struct.unpack('!Q', self.rfile.read(8))[0]
        if size > 1024 * 1024 or not header[1] & 128:
            raise ValueError('Invalid client frame')
        mask = self.rfile.read(4)
        data = self.rfile.read(size)
        return json.loads(bytes(byte ^ mask[i % 4] for i, byte in enumerate(data)))

    def websocket(self):
        assert '?' not in self.path
        accept = base64.b64encode(hashlib.sha1((self.headers['Sec-WebSocket-Key'] +
                                              '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        self.send_response(101)
        self.send_header('Upgrade', 'websocket')
        self.send_header('Connection', 'Upgrade')
        self.send_header('Sec-WebSocket-Accept', accept)
        self.end_headers()
        self.frame({'type': 'event', 'event': 'connected', 'data': {'api_version': 1}})
        first = self.read_frame()
        second = self.read_frame()
        for value in [second, first]:
            if value:
                self.frame({'type': 'response', 'id': value['id'], 'result': value['method']})
        self.read_frame()  # Hold the connection until the client closes it.


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, *args):
        # Timeouts/size limits intentionally cause the client to close early.
        pass


server = Server(('127.0.0.1', 0), Handler)
(root / 'port').write_text(str(server.server_port))
server.serve_forever()
