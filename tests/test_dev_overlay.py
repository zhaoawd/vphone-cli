"""Preserve the exact archive contract while replacing one dev payload."""
import copy
import io
import json
import os
from pathlib import Path
import tarfile
import unittest
from unittest.mock import patch

from tests import test_patch_plan_gate as fixtures
from patchers import dev_overlay, guest_write


class DevOverlayTests(unittest.TestCase):
    setUp = fixtures.FrozenGateTests.setUp
    publish = fixtures.FrozenGateTests.publish

    def prepare(self):
        archive = self.vm / 'cfw_input/jb/iosbinpack64.tar'
        archive.parent.mkdir(parents=True)
        payload = self.root / 'replacement'; payload.write_bytes(b'new dev payload')
        with tarfile.open(archive, 'w:') as stream:
            for name, data in [('iosbinpack64/test', b'original test'),
                               ('iosbinpack64/._kept', b'existing sidecar'),
                               (dev_overlay.MEMBER, b'old payload')]:
                row = tarfile.TarInfo(name); row.size = len(data)
                row.mode = 0o755; row.uid = 23; row.gid = 80; row.mtime = 123456
                row.pax_headers = {'comment': 'preserved metadata'}
                stream.addfile(row, io.BytesIO(data))
            row = tarfile.TarInfo('iosbinpack64/link'); row.type = tarfile.SYMTYPE
            row.linkname = 'test'; stream.addfile(row)
        table, digest = guest_write.target_table()
        table = dict(table, archives=dict(table['archives']))
        with tarfile.open(archive) as stream:
            table['archives']['iosbinpack64.tar'] = {
                row.name: dict(type=row.type.decode(), link=row.linkname) for row in stream}
        self.table_patch = patch.object(guest_write, 'target_table', return_value=(table, digest))
        self.table_patch.start(); self.addCleanup(self.table_patch.stop)
        return archive, payload

    def contents(self, path):
        with tarfile.open(path) as stream:
            return {row.name: dict(type=row.type, link=row.linkname, mode=row.mode, uid=row.uid, gid=row.gid,
                mtime=row.mtime, pax=row.pax_headers,
                content=stream.extractfile(row).read() if row.isfile() else None) for row in stream}

    def test_only_payload_changes_and_existing_sidecars_and_metadata_survive(self):
        archive, payload = self.prepare(); before = self.contents(archive)
        mode = archive.stat().st_mode
        dev_overlay.replace_payload(archive, payload)
        after = self.contents(archive)
        expected = copy.deepcopy(before); expected[dev_overlay.MEMBER]['content'] = payload.read_bytes()
        self.assertEqual(after, expected)
        self.assertEqual(archive.stat().st_mode, mode)
        guest_write.archive_targets(archive, self.mount / 'mnt1')

    def test_same_payload_reapplication_is_byte_identical(self):
        archive, payload = self.prepare()
        dev_overlay.replace_payload(archive, payload); first = archive.read_bytes()
        dev_overlay.replace_payload(archive, payload)
        self.assertEqual(archive.read_bytes(), first)

    def test_already_matching_payload_does_not_rewrite_archive(self):
        archive, payload = self.prepare(); payload.write_bytes(b'old payload')
        before = archive.read_bytes(); identity = archive.stat()
        self.assertFalse(dev_overlay.replace_payload(archive, payload))
        self.assertEqual(archive.read_bytes(), before)
        self.assertEqual(archive.stat().st_ino, identity.st_ino)
        self.assertEqual(archive.stat().st_mtime_ns, identity.st_mtime_ns)

    def test_undeclared_member_cannot_be_removed_or_accepted(self):
        archive, payload = self.prepare()
        with tarfile.open(archive, 'a:') as stream:
            row = tarfile.TarInfo('iosbinpack64/._new'); row.size = 3
            stream.addfile(row, io.BytesIO(b'new'))
        before = archive.read_bytes()
        with self.assertRaisesRegex(ValueError, 'undeclared'):
            dev_overlay.replace_payload(archive, payload)
        self.assertEqual(archive.read_bytes(), before)

    def test_linked_payload_is_refused_without_changing_archive(self):
        archive, payload = self.prepare(); before = archive.read_bytes()
        alias = self.root / 'alias'; alias.symlink_to(payload)
        with self.assertRaises((ValueError, OSError)):
            dev_overlay.replace_payload(archive, alias)
        self.assertEqual(archive.read_bytes(), before)

    def test_missing_payload_member_is_refused_without_changing_archive(self):
        archive, payload = self.prepare()
        table, digest = guest_write.target_table()
        del table['archives']['iosbinpack64.tar'][dev_overlay.MEMBER]
        with tarfile.open(archive, 'w:') as stream:
            for name in table['archives']['iosbinpack64.tar']:
                row = tarfile.TarInfo(name)
                if name.endswith('/link'):
                    row.type = tarfile.SYMTYPE; row.linkname = 'test'
                stream.addfile(row)
        before = archive.read_bytes()
        with self.assertRaisesRegex(ValueError, 'Exactly one'):
            dev_overlay.replace_payload(archive, payload)
        self.assertEqual(archive.read_bytes(), before)

    def test_entrypoint_refuses_other_variant_and_payload_path_before_write(self):
        archive, payload = self.prepare(); before = archive.read_bytes()
        with self.assertRaisesRegex(ValueError, 'requires EXP'):
            dev_overlay.main([str(archive), str(payload)])
        self.plan['variant'] = 'exp'; self.plan['gates']['variant'] = 'exp'; self.context['variant'] = 'exp'; self.publish()
        os.environ.update(VPHONE_CFW_VARIANT='exp', VPHONE_FROZEN_PLAN_SHA256=self.digest,
                          VPHONE_FROZEN_CONTEXT=json.dumps(self.context))
        with self.assertRaisesRegex(ValueError, 'packaged dev resource'):
            dev_overlay.main([str(archive), str(payload)])
        self.assertEqual(archive.read_bytes(), before)

    def test_entrypoint_uses_the_current_plan_and_exact_packaged_payload(self):
        archive, _ = self.prepare()
        self.plan['variant'] = 'exp'; self.plan['gates']['variant'] = 'exp'; self.context['variant'] = 'exp'; self.publish()
        os.environ.update(VPHONE_CFW_VARIANT='exp', VPHONE_FROZEN_PLAN_SHA256=self.digest,
                          VPHONE_FROZEN_CONTEXT=json.dumps(self.context))
        payload = Path(dev_overlay.__file__).resolve().parents[1] / 'resources/cfw_dev/rpcserver_ios'
        if not payload.is_file():
            self.skipTest('Packaged dev resource unavailable')
        dev_overlay.main([str(archive), str(payload)])
        self.assertEqual(self.contents(archive)[dev_overlay.MEMBER]['content'], payload.read_bytes())


if __name__ == '__main__':
    unittest.main()
