import importlib.util
from pathlib import Path
import stat
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    'retirement', Path(__file__).with_name('retire_migration_experiments_20261030.py'))
retirement = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retirement)


class RetirementTests(unittest.TestCase):
    def test_scope_is_four_build_children(self):
        self.assertEqual(len(retirement.TARGETS), 4)
        self.assertTrue(all(p.parent == retirement.ROOT / '.build' for p in retirement.TARGETS))

    def test_retains_sources_records_and_candidates_but_excludes_vm_payloads(self):
        info = {'mode': stat.S_IFREG | 0o600}
        for name in ['.build/x/source/tool.py', '.build/x/run.jsonl',
                     '.build/x/AVPBooter.vresearch1.bin',
                     '.build/t32-t33-completion-20261023/candidate.tar']:
            with self.subTest(name=name):
                self.assertTrue(retirement.preserve(name, info))
        for name in ['.build/x/Disk.img', '.build/x/effect-blobs/a.json',
                     '.build/x/iPhone_Restore/a.plist']:
            with self.subTest(name=name):
                self.assertFalse(retirement.preserve(name, info))

    def test_archive_member_tampering_is_rejected(self):
        with tempfile.TemporaryDirectory(dir=retirement.ROOT / '.build') as tmp:
            root = Path(tmp)
            record = root / 'record.json'
            record.write_text('{}')
            archive = root / 'retained-records-and-inputs.tar.gz'
            with tarfile.open(archive, 'w:gz') as tar:
                tar.add(record, arcname='record.json')
            manifest = {'archiveSHA256': retirement.sha(archive),
                        'files': {'record.json': {'sha256': retirement.sha(record)}}}
            with patch.object(retirement, 'OUT', root):
                retirement.verify_archive(manifest)
                manifest['files']['record.json']['sha256'] = '0' * 64
                with self.assertRaisesRegex(ValueError, 'Archived member differs'):
                    retirement.verify_archive(manifest)


if __name__ == '__main__':
    unittest.main()
