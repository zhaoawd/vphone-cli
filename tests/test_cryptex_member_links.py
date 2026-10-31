"""Reproduce EXP Cryptex tree observation with a contained hard-link group."""
import hashlib
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from patchers import cryptex_source


class CryptexMemberLinkTests(unittest.TestCase):
    def observe_members(self, hardlinked):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = root / 'first'; first.write_bytes(b'fixture Cryptex member')
            second = root / 'second'
            if hardlinked:
                os.link(first, second)
            else:
                second.write_bytes(first.read_bytes())
            return cryptex_source.tree(root)

    def expected(self):
        value = dict(kind='file', sha256=hashlib.sha256(b'fixture Cryptex member').hexdigest())
        return {'.': dict(kind='directory'), 'first': value, 'second': value}

    def test_single_link_control_is_hashable(self):
        self.assertEqual(self.observe_members(False), self.expected())

    def test_contained_hardlink_group_is_hashable(self):
        self.assertEqual(self.observe_members(True), self.expected())

    def test_external_alias_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent=Path(temporary);root=parent/'tree';root.mkdir()
            first=root/'first';first.write_bytes(b'fixture')
            os.link(first,root/'second');os.link(first,parent/'external')
            with self.assertRaisesRegex(ValueError,'extends outside observed tree'):
                cryptex_source.tree(root)

    def test_nested_contained_alias_is_hashable(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);first=root/'first';first.write_bytes(b'fixture')
            (root/'nested').mkdir();os.link(first,root/'nested/second')
            result=cryptex_source.tree(root)
            self.assertEqual(result['first'],result['nested/second'])

    def test_patch_snapshot_still_refuses_even_a_contained_group(self):
        from patchers import component_effects
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);first=root/'first';first.write_bytes(b'fixture')
            os.link(first,root/'second')
            for read in (cryptex_source.file_sha,component_effects.state):
                with self.subTest(read=read.__name__), self.assertRaisesRegex(ValueError,
                        'effect input is not an unlinked regular file'):
                    read(first)

    def test_readonly_source_flag_does_not_allow_a_writable_filesystem(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);first=root/'first';first.write_bytes(b'fixture')
            os.link(first,root/'second')
            with self.assertRaisesRegex(ValueError,'filesystem is not readonly'):
                cryptex_source.tree(root,readonly_source=True)

    def test_mutation_during_linked_file_read_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);first=root/'first';first.write_bytes(b'fixture')
            os.link(first,root/'second');read=os.read;changed=False
            def change(fd,size):
                nonlocal changed
                data=read(fd,size)
                if not changed:
                    changed=True;(root/'second').write_bytes(b'changed fixture')
                return data
            with patch.object(cryptex_source.os,'read',side_effect=change):
                with self.assertRaisesRegex(ValueError,'group changed during read'):
                    cryptex_source.tree(root)

    def test_new_tree_entry_during_read_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);(root/'first').write_bytes(b'fixture')
            original=cryptex_source.file_sha
            def change(path,**kwargs):
                digest=original(path,**kwargs);(root/'new').write_bytes(b'added')
                return digest
            with patch.object(cryptex_source,'file_sha',side_effect=change):
                with self.assertRaisesRegex(ValueError,'tree changed during read'):
                    cryptex_source.tree(root)

    def test_symlink_is_recorded_without_reading_its_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent=Path(temporary);root=parent/'tree';root.mkdir()
            external=parent/'external';external.write_bytes(b'outside')
            (root/'link').symlink_to(external)
            result=cryptex_source.tree(root)
            self.assertEqual(result['link'],dict(kind='link',link=str(external)))


if __name__ == '__main__':
    unittest.main()
