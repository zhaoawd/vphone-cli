"""New isolated acceptance requires a separate exact approval and safe clones."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('fresh_accept',Path(__file__).with_name('execute_t32_fresh_file_acceptance.py'))
fresh=importlib.util.module_from_spec(spec);spec.loader.exec_module(fresh)


class FreshAcceptanceGuards(unittest.TestCase):
    def test_old_approval_does_not_authorize_fresh_scope(self):
        with tempfile.TemporaryDirectory() as directory:
            work=Path(directory);source=work/'source';source.write_bytes(b'frozen')
            plan=dict(VMStarts=0,securityWindows=0,python=str(source),pythonResolved=str(source.resolve()),
                      frozenInputs={str(source):fresh.evidence.digest(source)})
            p=work/'fresh-file-acceptance-plan.json';p.write_bytes(fresh.evidence.canonical(plan));digest=fresh.evidence.digest(p)
            (work/'file-acceptance-approval.json').write_text(json.dumps(dict(approved=True,planSHA256=digest)))
            with patch.object(fresh,'WORK',work):
                with self.assertRaises(FileNotFoundError):fresh.approved(digest)
                approval=work/'fresh-file-acceptance-approval.json';approval.write_text(json.dumps(dict(approved=True,planSHA256=digest)))
                self.assertEqual(fresh.approved(digest),plan)
                source.write_bytes(b'changed')
                with self.assertRaisesRegex(ValueError,'Frozen'):fresh.approved(digest)

    def test_clone_has_distinct_inode_and_preserves_complete_bytes_without_source_write(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);source=root/'source';source.write_bytes(b'original'*8192)
            identity=fresh.evidence.image_identity(source.stat());target=root/'copy'
            fresh.clone_file(source,target)
            self.assertEqual(target.read_bytes(),source.read_bytes())
            self.assertNotEqual(target.stat().st_ino,source.stat().st_ino)
            self.assertEqual(fresh.evidence.image_identity(source.stat()),identity)
            with self.assertRaises(FileExistsError):fresh.clone_file(source,target)

    def test_linked_source_tree_refuses(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);source=root/'source';source.mkdir();outside=root/'outside';outside.write_bytes(b'original')
            (source/'linked').symlink_to(outside)
            with self.assertRaisesRegex(ValueError,'Linked'):fresh.clone_tree(source,root/'target')
            self.assertEqual(outside.read_bytes(),b'original')


if __name__=='__main__':unittest.main()
