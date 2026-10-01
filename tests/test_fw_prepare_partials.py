"""fw_prepare.sh never leaves an interrupted copy or extraction under its final name.

A cancelled `vm create` ends fw_prepare.sh and its children (SIGINT, then
SIGKILL). The extracted IPSW cache in IPSW_DIR is shared between VMs and reused
by name (B4 acceptance 2026-10-01: an orphaned unzip kept writing
~/.vphone/ipsws/iPhone17,3_26.1_23B85_Restore after vm create exited). The
functions under test are taken from the script and run with stand-in commands.
"""
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
# FW_PREPARE_SCRIPT runs the same cases against another revision of the script
# (the record compares the script before and after the change).
SCRIPT = Path(os.environ.get('FW_PREPARE_SCRIPT', ROOT / 'scripts/fw_prepare.sh'))
OPTIONAL = ('partial_path', 'remove_stale_partials')
FUNCTIONS = ('die', 'is_local', 'partial_path', 'remove_stale_partials', 'extract', 'fetch')
MARKER = '.vphone-extract-complete'


def harness_text():
    text = SCRIPT.read_text()
    parts = ['set -euo pipefail', f'PYTHON3={sys.executable!r}']
    marker = re.search(r'^EXTRACT_MARKER=.*$', text, re.M)
    if marker:
        parts.append(marker.group(0))
    for name in FUNCTIONS:
        match = re.search(rf'^{name}\(\) {{\n.*?^}}\n', text, re.S | re.M)
        assert match or name in OPTIONAL, f'{name} missing from {SCRIPT}'
        if match:
            parts.append(match.group(0))
    parts.append('"$@"')
    return '\n'.join(parts) + '\n'


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
        self.zip = self.ipsws / 'iPhone_Restore.ipsw'
        with zipfile.ZipFile(self.zip, 'w') as archive:
            archive.writestr('BuildManifest.plist', 'manifest')
            archive.writestr('Firmware/all_flash/iBoot.im4p', 'iboot' * 100)
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
        return subprocess.Popen(['/bin/bash', str(self.harness), *args], cwd=self.work,
                                env=dict(os.environ, PATH=path, READY=str(self.ready), CACHE=str(self.cache)),
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)

    def finish(self, proc, timeout=30):
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

    def assert_complete_extraction(self, out):
        self.assertEqual((out / 'BuildManifest.plist').read_text(), 'manifest')
        self.assertEqual((out / 'Firmware/all_flash/iBoot.im4p').read_text(), 'iboot' * 100)
        self.assertFalse((out / MARKER).exists(), 'the completion marker is not copied into the restore tree')
        self.assertTrue((self.cache / MARKER).exists())

    def test_interrupted_extraction_is_never_published_and_is_redone(self):
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
        # What the unchanged script leaves after an interrupted unzip.
        (self.cache / 'Firmware').mkdir(parents=True)
        (self.cache / 'BuildManifest.plist').write_text('partial')
        rc, output = self.finish(self.run_harness('extract', str(self.zip), str(self.cache), 'iPhone_Restore'))
        self.assertEqual(rc, 0, output)
        self.assertIn('Discarding incomplete extraction', output)
        self.assert_complete_extraction(self.work / 'iPhone_Restore')

    def test_complete_cache_is_reused_without_extracting(self):
        rc, output = self.finish(self.run_harness('extract', str(self.zip), str(self.cache), 'iPhone_Restore'))
        self.assertEqual(rc, 0, output)
        self.stub('unzip', 'echo "unzip must not run" >&2; exit 9\n')
        rc, output = self.finish(self.run_harness('extract', str(self.zip), str(self.cache), 'iPhone_Restore', stubs=True))
        self.assertEqual(rc, 0, output)
        self.assertIn('Cached: iPhone_Restore', output)
        self.assert_complete_extraction(self.work / 'iPhone_Restore')

    def test_cache_published_by_a_concurrent_run_is_kept(self):
        # Another run publishes its complete cache while this one extracts.
        self.stub('unzip', f'/usr/bin/unzip "$@"; mkdir -p "$CACHE"; echo other > "$CACHE/BuildManifest.plist"; '
                           f'touch "$CACHE/{MARKER}"\n')
        rc, output = self.finish(self.run_harness('extract', str(self.zip), str(self.cache), 'iPhone_Restore', stubs=True))
        self.assertEqual(rc, 0, output)
        self.assertEqual((self.work / 'iPhone_Restore/BuildManifest.plist').read_text(), 'other\n')
        self.assertEqual(self.partials(self.cache), [])

    def test_interrupted_local_copy_is_not_taken_for_the_ipsw(self):
        source = self.root / 'source.ipsw'
        source.write_bytes(b'ipsw' * 1000)
        target = self.ipsws / 'copied.ipsw'
        self.stub('cp', 'head -c 100 "$1" > "$2"; touch "$READY"; sleep 30\n')
        rc, output = self.interrupt_when_ready(self.run_harness('fetch', str(source), str(target), stubs=True))
        self.assertNotEqual(rc, 0, output)
        self.assertFalse(target.exists(), 'an interrupted copy is visible under the IPSW name')

        rc, output = self.finish(self.run_harness('fetch', str(source), str(target)))
        self.assertEqual(rc, 0, output)
        self.assertNotIn('already exists', output)
        self.assertEqual(target.read_bytes(), source.read_bytes())
        self.assertEqual(self.partials(target), [])


if __name__ == '__main__':
    unittest.main()
