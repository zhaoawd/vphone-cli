"""fw_prepare.sh never reuses a cache entry it cannot identify.

A cancelled `vm create` ends fw_prepare.sh and its children (SIGINT, then
SIGKILL). The IPSW cache in IPSW_DIR is shared between VMs (B4 acceptance
2026-10-01: an orphaned unzip kept writing
~/.vphone/ipsws/iPhone17,3_26.1_23B85_Restore after vm create exited). B4 made
copies and extractions go through partial files; T14 makes every entry carry a
completion marker naming its content (scripts/ipsw_cache_entry.py), so nothing
is reused by name alone, and moves downloads onto the same partial path.

The functions under test are taken from the script and run with stand-in
commands. Downloads use a local HTTP server with Range support and injected
faults; no test reaches the network.
"""
import hashlib
import http.server
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
# FW_PREPARE_SCRIPT runs the same cases against another revision of the script
# (the record compares the script before and after the change).
SCRIPT = Path(os.environ.get('FW_PREPARE_SCRIPT', ROOT / 'scripts/fw_prepare.sh'))
HELPER = ROOT / 'scripts/ipsw_cache_entry.py'
OPTIONAL = ('partial_path', 'remove_stale_partials', 'cache_entry', 'curl_download')
FUNCTIONS = ('die', 'is_local', 'cache_entry', 'partial_path', 'remove_stale_partials',
             'curl_download', 'download_file', 'extract', 'fetch')
MARKER = '.vphone-extract-complete'


def harness_text():
    text = SCRIPT.read_text()
    parts = ['set -euo pipefail', f'PYTHON3={sys.executable!r}', f'SCRIPT_DIR={str(HELPER.parent)!r}']
    for setting in re.finditer(r'^(EXTRACT_MARKER|CURL_ATTEMPTS|CURL_RETRY_DELAY)=.*$', text, re.M):
        parts.append(setting.group(0))
    for name in FUNCTIONS:
        match = re.search(rf'^{name}\(\) {{\n.*?^}}\n', text, re.S | re.M)
        assert match or name in OPTIONAL, f'{name} missing from {SCRIPT}'
        if match:
            parts.append(match.group(0))
    parts.append('"$@"')
    return '\n'.join(parts) + '\n'


def make_ipsw(path, manifest='manifest', iboot='iboot' * 100):
    with zipfile.ZipFile(path, 'w') as archive:
        archive.writestr('BuildManifest.plist', manifest)
        archive.writestr('Firmware/all_flash/iBoot.im4p', iboot)
    return path


class IPSWServer(http.server.ThreadingHTTPServer):
    """Serves one payload with Range/If-Range and scripted faults.

    faults: per-request actions consumed in order; 'drop' closes the
    connection after `drop_after` body bytes, 'slow' sends one byte per 50 ms,
    an int answers with that status. Requests past the list are served
    normally. requests records (method, Range header) per request.
    """

    def __init__(self, payload, faults=(), drop_after=4096, ranges=True):
        super().__init__(('127.0.0.1', 0), IPSWHandler)
        self.payload = payload
        self.faults = list(faults)
        self.drop_after = drop_after
        self.ranges = ranges
        self.requests = []
        self.lock = threading.Lock()

    def handle_error(self, request, client_address):
        pass  # a client interrupted on purpose closes its connection mid-body

    @property
    def url(self):
        return f'http://127.0.0.1:{self.server_address[1]}/iPhone_Restore.ipsw'


class IPSWHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass

    def do_GET(self):
        server = self.server
        with server.lock:
            server.requests.append(('GET', self.headers.get('Range')))
            fault = server.faults.pop(0) if server.faults else None
        if isinstance(fault, int):
            self.send_response(fault)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        payload, start = server.payload, 0
        status = 200
        requested = self.headers.get('Range')
        if server.ranges and requested and requested.startswith('bytes=') and requested.endswith('-'):
            start = int(requested[6:-1])
            status = 206
        body = payload[start:]
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('ETag', '"payload-1"')
        if server.ranges:
            self.send_header('Accept-Ranges', 'bytes')
        if status == 206:
            self.send_header('Content-Range', f'bytes {start}-{len(payload) - 1}/{len(payload)}')
        self.end_headers()
        if fault == 'drop':
            self.wfile.write(body[:server.drop_after])
            self.wfile.flush()
            self.close_connection = True
            self.connection.shutdown(2)
            return
        if fault == 'slow':
            for index in range(len(body)):
                self.wfile.write(body[index:index + 1])
                self.wfile.flush()
                time.sleep(0.05)
            return
        self.wfile.write(body)


class FWPreparePartialTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='fw prepare partial ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.ipsws = self.root / 'ipsws'
        self.ipsws.mkdir()
        self.work = self.root / 'vm'
        self.work.mkdir()
        self.harness = self.root / 'harness.sh'
        self.harness.write_text(harness_text())
        self.source = make_ipsw(self.root / 'source.ipsw')
        self.zip = self.ipsws / 'iPhone_Restore.ipsw'
        self.cache = self.ipsws / 'iPhone_Restore'
        self.stubs = self.root / 'stubs'
        self.stubs.mkdir()
        self.ready = self.root / 'ready'

    def stub(self, name, body):
        path = self.stubs / name
        path.write_text('#!/bin/bash\n' + body)
        path.chmod(0o755)

    def run_harness(self, *args, stubs=False):
        path = (f'{self.stubs}:' if stubs else '') + '/usr/bin:/bin:/usr/sbin:/sbin'
        env = {k: v for k, v in os.environ.items() if not k.lower().endswith('_proxy')}
        env.update(PATH=path, READY=str(self.ready), CACHE=str(self.cache), ZIP=str(self.zip),
                   PYTHON=sys.executable, HELPER=str(HELPER), NO_PROXY='*', no_proxy='*',
                   CURL_RETRY_DELAY='0')
        return subprocess.Popen(['/bin/bash', str(self.harness), *args], cwd=self.work, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)

    def finish(self, proc, timeout=60):
        output, _ = proc.communicate(timeout=timeout)
        return proc.returncode, output.decode()

    def interrupt_when_ready(self, proc):
        self.addCleanup(lambda: proc.poll() is None and os.killpg(proc.pid, signal.SIGKILL))
        deadline = time.monotonic() + 15
        while not self.ready.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(self.ready.exists())
        os.killpg(proc.pid, signal.SIGINT)
        return self.finish(proc)

    def partials(self, target):
        return sorted(p.name for p in target.parent.glob(f'.{target.name}.partial.*'))

    def marker(self, target):
        return target.parent / f'.{target.name}.vphone-complete'

    def fetch(self, source, target=None, stubs=False):
        return self.finish(self.run_harness('fetch', str(source), str(target or self.zip), stubs=stubs))

    def cached_zip(self):
        rc, output = self.fetch(self.source)
        self.assertEqual(rc, 0, output)
        return self.zip

    def serve(self, payload, **options):
        server = IPSWServer(payload, **options)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return server

    def assert_complete_extraction(self, out, manifest='manifest'):
        self.assertEqual((out / 'BuildManifest.plist').read_text(), manifest)
        self.assertEqual((out / 'Firmware/all_flash/iBoot.im4p').read_text(), 'iboot' * 100)
        self.assertFalse((out / MARKER).exists(), 'the completion marker is not copied into the restore tree')
        self.assertTrue((self.cache / MARKER).exists())

    # MARK: - Extraction

    def test_interrupted_extraction_is_never_published_and_is_redone(self):
        self.cached_zip()
        # unzip stand-in: one file written, then a long run until interrupted.
        self.stub('unzip', 'mkdir -p "$4"; echo partial > "$4/BuildManifest.plist"; touch "$READY"; sleep 30\n')
        rc, output = self.interrupt_when_ready(self.run_harness('extract', str(self.zip), str(self.cache), 'iPhone_Restore', stubs=True))
        self.assertNotEqual(rc, 0, output)
        self.assertFalse(self.cache.exists(), 'an interrupted extraction is visible under the cache name')
        self.assertEqual(len(self.partials(self.cache)), 1)

        rc, output = self.finish(self.run_harness('extract', str(self.zip), str(self.cache), 'iPhone_Restore'))
        self.assertEqual(rc, 0, output)
        self.assertIn('Removing interrupted', output)
        self.assertIn('Extracting', output)
        self.assertEqual(self.partials(self.cache), [])
        self.assert_complete_extraction(self.work / 'iPhone_Restore')

    def test_cache_without_completion_marker_is_discarded(self):
        self.cached_zip()
        # What the script before B4 left after an interrupted unzip.
        (self.cache / 'Firmware').mkdir(parents=True)
        (self.cache / 'BuildManifest.plist').write_text('partial')
        rc, output = self.finish(self.run_harness('extract', str(self.zip), str(self.cache), 'iPhone_Restore'))
        self.assertEqual(rc, 0, output)
        self.assertIn('Discarding incomplete extraction', output)
        self.assert_complete_extraction(self.work / 'iPhone_Restore')
        self.assertEqual(self.partials(self.cache), [])

    def test_marker_from_before_t14_names_no_ipsw_and_is_discarded(self):
        self.cached_zip()
        # B4's marker was an empty file: complete, but extracted from what?
        (self.cache / 'Firmware/all_flash').mkdir(parents=True)
        (self.cache / 'BuildManifest.plist').write_text('stale')
        (self.cache / MARKER).write_text('')
        rc, output = self.finish(self.run_harness('extract', str(self.zip), str(self.cache), 'iPhone_Restore'))
        self.assertEqual(rc, 0, output)
        self.assertIn('Discarding incomplete extraction iPhone_Restore (no completion marker)', output)
        self.assert_complete_extraction(self.work / 'iPhone_Restore')

    def test_complete_cache_is_reused_without_extracting(self):
        self.cached_zip()
        rc, output = self.finish(self.run_harness('extract', str(self.zip), str(self.cache), 'iPhone_Restore'))
        self.assertEqual(rc, 0, output)
        self.stub('unzip', 'echo "unzip must not run" >&2; exit 9\n')
        rc, output = self.finish(self.run_harness('extract', str(self.zip), str(self.cache), 'iPhone_Restore', stubs=True))
        self.assertEqual(rc, 0, output)
        self.assertIn('Cached: iPhone_Restore', output)
        self.assert_complete_extraction(self.work / 'iPhone_Restore')

    def test_extraction_of_another_ipsw_with_the_same_name_is_redone(self):
        self.cached_zip()
        rc, output = self.finish(self.run_harness('extract', str(self.zip), str(self.cache), 'iPhone_Restore'))
        self.assertEqual(rc, 0, output)
        other = make_ipsw(self.root / 'other.ipsw', manifest='other manifest')
        rc, output = self.fetch(other)
        self.assertEqual(rc, 0, output)
        rc, output = self.finish(self.run_harness('extract', str(self.zip), str(self.cache), 'iPhone_Restore'))
        self.assertEqual(rc, 0, output)
        self.assertIn('extracted from another IPSW', output)
        self.assert_complete_extraction(self.work / 'iPhone_Restore', manifest='other manifest')

    def test_cache_published_by_a_concurrent_run_is_kept(self):
        self.cached_zip()
        # Another run publishes its complete cache while this one extracts.
        other = self.root / 'other-run'
        self.stub('unzip', f'/usr/bin/unzip "$@"; mkdir -p "{other}"; echo other > "{other}/BuildManifest.plist"; '
                           '"$PYTHON" "$HELPER" publish-dir "$CACHE" "' + str(other) + '" --parent "$ZIP"\n')
        rc, output = self.finish(self.run_harness('extract', str(self.zip), str(self.cache), 'iPhone_Restore', stubs=True))
        self.assertEqual(rc, 0, output)
        self.assertIn('extracted by another run', output)
        self.assertEqual((self.work / 'iPhone_Restore/BuildManifest.plist').read_text(), 'other\n')
        self.assertEqual(self.partials(self.cache), [])

    # MARK: - Local copies

    def test_interrupted_local_copy_is_not_taken_for_the_ipsw(self):
        self.stub('cp', 'head -c 100 "$1" > "$2"; touch "$READY"; sleep 30\n')
        rc, output = self.interrupt_when_ready(self.run_harness('fetch', str(self.source), str(self.zip), stubs=True))
        self.assertNotEqual(rc, 0, output)
        self.assertFalse(self.zip.exists(), 'an interrupted copy is visible under the IPSW name')

        rc, output = self.fetch(self.source)
        self.assertEqual(rc, 0, output)
        self.assertIn('Removing interrupted', output)
        self.assertEqual(self.zip.read_bytes(), self.source.read_bytes())
        self.assertTrue(self.marker(self.zip).exists())
        self.assertEqual(self.partials(self.zip), [])

    def test_identified_copy_is_reused_without_copying(self):
        self.cached_zip()
        self.stub('cp', 'echo "cp must not run" >&2; exit 9\n')
        rc, output = self.fetch(self.source, stubs=True)
        self.assertEqual(rc, 0, output)
        self.assertIn('Cached: iPhone_Restore.ipsw', output)

    def test_ipsw_cached_before_markers_is_discarded_and_copied_again(self):
        # What every run before T14 left: the IPSW under its name, no marker.
        self.zip.write_bytes(b'cached before markers')
        rc, output = self.fetch(self.source)
        self.assertEqual(rc, 0, output)
        self.assertIn('Discarding cached iPhone_Restore.ipsw (no completion marker)', output)
        self.assertEqual(self.zip.read_bytes(), self.source.read_bytes())
        marker = json.loads(self.marker(self.zip).read_text())
        self.assertEqual(marker['source']['path'], str(self.source))
        self.assertEqual(marker['size'], self.source.stat().st_size)

    def test_same_name_from_another_source_is_not_reused(self):
        self.cached_zip()
        other = make_ipsw(self.root / 'other.ipsw', manifest='other manifest')
        rc, output = self.fetch(other)
        self.assertEqual(rc, 0, output)
        self.assertIn('completion marker names another source', output)
        self.assertEqual(self.zip.read_bytes(), other.read_bytes())

    def test_changed_source_or_cache_file_is_not_reused(self):
        self.cached_zip()
        make_ipsw(self.source, manifest='edited in place')
        rc, output = self.fetch(self.source)
        self.assertEqual(rc, 0, output)
        self.assertIn('completion marker names another source', output)
        self.assertEqual(self.zip.read_bytes(), self.source.read_bytes())

        with open(self.zip, 'ab') as handle:
            handle.write(b'appended after publishing')
        rc, output = self.fetch(self.source)
        self.assertEqual(rc, 0, output)
        self.assertIn('file changed after its completion marker was written', output)
        self.assertEqual(self.zip.read_bytes(), self.source.read_bytes())

    def test_copy_that_is_not_an_ipsw_is_not_published(self):
        broken = self.root / 'broken.ipsw'
        broken.write_bytes(b'not a zip')
        rc, output = self.fetch(broken)
        self.assertNotEqual(rc, 0, output)
        self.assertIn('is not a complete IPSW', output)
        self.assertFalse(self.zip.exists())
        self.assertFalse(self.marker(self.zip).exists())

    # MARK: - Adopted entries (vphone-cli fw cache adopt)

    ADOPTED = 'adopted; source not verified by download'

    def write_adopted_marker(self, entry, source):
        """The marker VPhoneIPSWCacheAdoption.swift writes for a file entry."""
        info = os.stat(entry)
        self.marker(entry).write_text(json.dumps({
            'format': 'vphone-ipsw-cache/1', 'kind': 'file', 'source': source,
            'size': info.st_size, 'sha256': hashlib.sha256(entry.read_bytes()).hexdigest(),
            'file': {'inode': info.st_ino, 'mtime_ns': info.st_mtime_ns},
            'adopted': True, 'source_verified': False,
            'adoption': {'at': '2026-10-01T00:00:00Z', 'source_from': 'argument', 'checks': ['build-manifest']},
            'manifest': {'version': '26.1', 'build': '23B85', 'product_types': ['iPhone17,3'], 'device_classes': []},
        }, sort_keys=True))

    def test_adopted_ipsw_is_used_and_labelled(self):
        make_ipsw(self.zip)
        url = 'https://updates.example.invalid/iPhone_Restore.ipsw'
        self.write_adopted_marker(self.zip, {'url': url})
        self.stub('curl', 'echo "curl must not run" >&2; exit 9\n')
        before = self.zip.read_bytes()
        rc, output = self.fetch(url, stubs=True)
        self.assertEqual(rc, 0, output)
        self.assertIn(f'==> Cached: iPhone_Restore.ipsw ({self.ADOPTED})', output)
        self.assertEqual(self.zip.read_bytes(), before)

    def test_adopted_extraction_is_used_and_labelled(self):
        self.cached_zip()
        parent = json.loads(self.marker(self.zip).read_text())
        with zipfile.ZipFile(self.zip) as archive:
            archive.extractall(self.cache)
        (self.cache / MARKER).write_text(json.dumps({
            'format': 'vphone-ipsw-cache/1', 'kind': 'directory',
            'parent': {'size': parent['size'], 'sha256': parent['sha256']},
            'adopted': True, 'source_verified': False,
        }))
        self.stub('unzip', 'echo "unzip must not run" >&2; exit 9\n')
        rc, output = self.finish(self.run_harness('extract', str(self.zip), str(self.cache), 'iPhone_Restore', stubs=True))
        self.assertEqual(rc, 0, output)
        self.assertIn(f'==> Cached: iPhone_Restore ({self.ADOPTED})', output)
        self.assert_complete_extraction(self.work / 'iPhone_Restore')

    def test_unmarked_cache_entry_given_as_its_own_local_source_is_kept(self):
        # fw prepare given ~/.vphone/ipsws/<name>.ipsw by path: source and entry
        # are one file. Discarding the unmarked entry would delete the source.
        make_ipsw(self.zip)
        before = self.zip.read_bytes()
        rc, output = self.fetch(self.zip)
        self.assertNotEqual(rc, 0, output)
        self.assertIn('vphone-cli fw cache adopt', output)
        self.assertTrue(self.zip.exists(), 'the local source was deleted')
        self.assertEqual(self.zip.read_bytes(), before)
        self.assertFalse(self.marker(self.zip).exists())

    def test_cache_entry_adopted_as_its_own_local_source_is_used(self):
        make_ipsw(self.zip)
        identity = json.loads(subprocess.check_output([sys.executable, '-B', str(HELPER), 'identify', str(self.zip)]))
        self.write_adopted_marker(self.zip, identity)
        self.stub('cp', 'echo "cp must not run" >&2; exit 9\n')
        rc, output = self.fetch(self.zip, stubs=True)
        self.assertEqual(rc, 0, output)
        self.assertIn(f'==> Cached: iPhone_Restore.ipsw ({self.ADOPTED})', output)

    # MARK: - Downloads (local HTTP server)

    def test_download_resumes_after_a_dropped_connection(self):
        payload = make_ipsw(self.root / 'remote.ipsw', iboot='x' * 200_000).read_bytes()
        server = self.serve(payload, faults=['drop'], drop_after=50_000)
        rc, output = self.fetch(server.url)
        self.assertEqual(rc, 0, output)
        self.assertEqual(self.zip.read_bytes(), payload)
        self.assertEqual(server.requests[0], ('GET', None))
        self.assertTrue(any(r and r.startswith('bytes=') and r != 'bytes=0-' for _, r in server.requests[1:]),
                        server.requests)
        marker = json.loads(self.marker(self.zip).read_text())
        self.assertEqual(marker['source'], {'url': server.url})
        self.assertEqual(self.partials(self.zip), [])

        # Same URL again: no request at all.
        before = len(server.requests)
        rc, output = self.fetch(server.url)
        self.assertEqual(rc, 0, output)
        self.assertIn('Cached: iPhone_Restore.ipsw', output)
        self.assertEqual(len(server.requests), before)

    def test_failed_download_publishes_nothing(self):
        server = self.serve(b'', faults=[404] * 10)
        rc, output = self.fetch(server.url)
        self.assertNotEqual(rc, 0, output)
        self.assertIn('Failed to download', output)
        self.assertIn('HTTP 404', output)
        self.assertEqual(len(server.requests), 1, 'a client error is not retried')
        self.assertFalse(self.zip.exists())
        self.assertFalse(self.marker(self.zip).exists())

    def test_truncated_download_without_ranges_is_not_published(self):
        payload = make_ipsw(self.root / 'remote.ipsw', iboot='y' * 100_000).read_bytes()
        server = self.serve(payload, faults=['drop'] * 10, drop_after=10_000, ranges=False)
        rc, output = self.fetch(server.url)
        self.assertNotEqual(rc, 0, output)
        self.assertIn('Download failed after 5 attempts', output)
        self.assertEqual(len(server.requests), 5)
        self.assertFalse(self.zip.exists())
        self.assertFalse(self.marker(self.zip).exists())

    def test_interrupted_download_is_not_found_under_the_ipsw_name(self):
        payload = make_ipsw(self.root / 'remote.ipsw').read_bytes()
        server = self.serve(payload, faults=['slow'])
        proc = self.run_harness('fetch', server.url, str(self.zip))
        self.addCleanup(lambda: proc.poll() is None and os.killpg(proc.pid, signal.SIGKILL))
        deadline = time.monotonic() + 15
        while not self.partials(self.zip) and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertTrue(self.partials(self.zip))
        time.sleep(0.3)
        os.killpg(proc.pid, signal.SIGINT)
        rc, output = self.finish(proc)
        self.assertNotEqual(rc, 0, output)
        self.assertFalse(self.zip.exists(), 'an interrupted download is visible under the IPSW name')

        rc, output = self.fetch(server.url)
        self.assertEqual(rc, 0, output)
        self.assertIn('Removing interrupted', output)
        self.assertEqual(self.zip.read_bytes(), payload)
        self.assertEqual(self.partials(self.zip), [])


if __name__ == '__main__':
    unittest.main()
