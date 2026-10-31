import hashlib
from pathlib import Path
import tempfile
import time
import unittest

from t52_serial_evidence import read_launch_serial


class SerialEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / 'serial.log'

    def test_new_launch_file_does_not_reuse_old_file_offset(self):
        before = time.time() - .001
        self.path.write_bytes(b'Guest stopped\n')
        serial, selection = read_launch_serial(self.path, dict(observedAt=before, serialOffset=1000), time.time() + .001)
        self.assertEqual(serial, 'Guest stopped\n')
        self.assertEqual(selection['offset'], 0)

    def test_old_file_cannot_supply_new_stop_evidence(self):
        self.path.write_bytes(b'Guest stopped\n')
        with self.assertRaises(AssertionError):
            read_launch_serial(self.path, dict(observedAt=time.time() + 1, serialOffset=1000), time.time() + 2)

    def test_append_requires_same_identity_and_unchanged_prefix(self):
        prefix = b'old Guest stopped\n'
        self.path.write_bytes(prefix)
        info = self.path.stat()
        baseline = dict(observedAt=time.time(), serialOffset=len(prefix),
            serialIdentity=dict(device=info.st_dev, inode=info.st_ino, birth=info.st_birthtime),
            serialPrefixSHA256=hashlib.sha256(prefix).hexdigest())
        with self.path.open('ab') as stream:
            stream.write(b'new log\n')
        serial, _ = read_launch_serial(self.path, baseline, time.time())
        self.assertEqual(serial, 'new log\n')
        self.path.write_bytes(b'x' * (len(prefix) + 8))
        with self.assertRaises(AssertionError):
            read_launch_serial(self.path, baseline, time.time())

    def test_file_created_after_running_observation_is_refused(self):
        self.path.write_bytes(b'Guest stopped\n')
        birth = self.path.stat().st_birthtime
        with self.assertRaises(AssertionError):
            read_launch_serial(self.path, dict(observedAt=birth - 1, serialOffset=0), birth - .001)


if __name__ == '__main__':
    unittest.main()
