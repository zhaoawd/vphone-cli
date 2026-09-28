"""Loopback HTTP/WebSocket fixture; never connects to a VM."""
import base64
import hashlib
import json
from pathlib import Path
import struct
import sys
import time
import uuid
from urllib.parse import urlsplit, parse_qs
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

root = Path(sys.argv[1])
token = '1234567890abcdef'
behind_proxy = '--behind-proxy' in sys.argv[2:]
host_commands = '--host-commands' in sys.argv[2:]
managed = '--managed-session' in sys.argv[2:] or host_commands
health = {'status': 'ok', 'api_version': 1, 'binary_hash': 'a' * 64,
          'capabilities': ['files'], 'ios': '26.0'}
if managed:
    health.update(instance_id=str(uuid.uuid4()), capabilities=['files', 'session_identity', 'file_download_identity', 'file_upload_identity'])
if host_commands:
    health['capabilities'].append('apps')


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

    def authorized(self):
        if behind_proxy:
            return self.headers.get('Authorization') is None and self.headers.get('Host') == 'vphoned'
        return self.headers.get('Authorization') == 'Bearer ' + token

    def do_GET(self):
        if not self.authorized():
            return self.reply(401, {'error': 'unauthorized'})
        if urlsplit(self.path).path == '/v1/files/content':
            return self.download()
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
        self.reply(200, health)

    def download(self):
        query = parse_qs(urlsplit(self.path).query)
        assert set(query) == {'path'} and len(query['path']) == 1
        path = query['path'][0]
        (root / 'download-path').write_text(path)
        if path == '/redirect-file':
            self.send_response(302)
            self.send_header('Location', '/followed/v1/health')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        if path == '/missing':
            return self.reply(404, {'error': 'missing'})
        chunked = path.startswith('/chunked/')
        count = int(path.rsplit('/', 1)[1]) if path.startswith(('/bytes/', '/chunked/')) else 256
        self.send_response(200)
        self.send_header('Content-Type', 'text/plain' if path == '/wrong-type' else 'application/octet-stream')
        self.send_header('X-Vphone-Instance-ID', str(uuid.uuid4()) if path == '/wrong-instance' else health['instance_id'])
        self.send_header('X-Vphone-Binary-Hash', 'b' * 64 if path == '/wrong-hash' else health['binary_hash'])
        if chunked:
            self.send_header('Transfer-Encoding', 'chunked')
        else:
            self.send_header('Content-Length', str(count))
        self.send_header('Connection', 'close')
        self.end_headers()
        if path.startswith('/slow-file'):
            self.wfile.write(b'x')
            self.wfile.flush()
            (root / ('started-' + path[1:])).write_text('1')
            time.sleep(5)
            return
        if path == '/short':
            self.wfile.write(b'short')
            return
        chunk = bytes(range(256)) * 256
        while count:
            data = chunk[:min(count, len(chunk))]
            if chunked:
                self.wfile.write(f'{len(data):x}\r\n'.encode() + data + b'\r\n')
            else:
                self.wfile.write(data)
            count -= len(data)
        if chunked:
            self.wfile.write(b'0\r\n\r\n')

    def do_PUT(self):
        if not self.authorized():
            return self.reply(401, {'error': 'unauthorized'})
        if self.headers.get('X-Vphone-Instance-ID', '').lower() != health['instance_id'].lower() or self.headers.get('X-Vphone-Binary-Hash') != health['binary_hash']:
            return self.reply(409, {'error': 'identity'})
        query = parse_qs(urlsplit(self.path).query)
        path = query['path'][0]
        size = int(self.headers['Content-Length'])
        if size > 64 * 1024 * 1024:
            return self.reply(413, {'error': 'limit'})
        if path == '/redirect-upload':
            self.send_response(307)
            self.send_header('Connection', 'close')
            self.send_header('Location', '/followed/v1/health')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        temporary = root / ('upload-' + str(uuid.uuid4()))
        try:
            with temporary.open('wb') as stream:
                remaining = size
                while remaining:
                    data = self.rfile.read(min(65536, remaining))
                    if not data:
                        return
                    stream.write(data)
                    remaining -= len(data)
            temporary.replace(root / 'uploaded')
            (root / 'uploaded-mode').write_text(query['mode'][0])
            if path == '/lost-reply':
                self.close_connection = True
                return
            self.reply(200, {'result': {'path': path, 'size': size,
                'instance_id': health['instance_id'], 'binary_hash': health['binary_hash']}})
        finally:
            temporary.unlink(missing_ok=True)

    def do_POST(self):
        if not self.authorized():
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
        self.frame({'type': 'event', 'event': 'connected', 'data': health if managed else {'api_version': 1}})
        if managed:
            while value := self.read_frame():
                result = health if value['method'] == 'agent.health' else value['method']
                if host_commands and value['method'] == 'apps.list':
                    if value['params'] != {'filter': 'user'}:
                        raise ValueError('Unexpected mapped app filter')
                    result = {'apps': [{'bundle_id': 'loopback.app', 'name': 'Loopback',
                                       'type': 'user', 'state': 'running', 'pid': 42,
                                       'path': '/Applications/Loopback.app', 'data_path': '/data/loopback'}]}
                elif host_commands and value['method'] == 'apps.foreground':
                    if value['params']:
                        raise ValueError('Unexpected foreground parameters')
                    result = {'bundle_id': 'loopback.app', 'name': 'Loopback',
                              'pid': 42, 'source': 'fixture', 'verified': False}
                self.frame({'type': 'response', 'id': value['id'], 'result': result})
            return
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
