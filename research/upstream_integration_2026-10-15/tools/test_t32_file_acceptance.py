"""Offline acceptance guards and assertions do not require VM access."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('t32_accept',Path(__file__).with_name('execute_t32_file_acceptance.py'))
accept=importlib.util.module_from_spec(spec);spec.loader.exec_module(accept)


class AcceptanceGuards(unittest.TestCase):
    def test_explicit_matching_approval_and_frozen_inputs_are_required(self):
        with tempfile.TemporaryDirectory() as folder:
            work=Path(folder);source=work/'producer';source.write_bytes(b'producer')
            plan=dict(VMStarts=0,securityWindows=0,frozenInputs={str(source):accept.evidence.digest(source)})
            path=work/'file-acceptance-plan.json';path.write_bytes(accept.evidence.canonical(plan))
            digest=accept.evidence.digest(path)
            with patch.object(accept,'WORK',work):
                with self.assertRaises(FileNotFoundError):accept.approved(digest)
                approval=work/'file-acceptance-approval.json';approval.write_text(json.dumps(dict(approved=False,planSHA256=digest)))
                with self.assertRaises(ValueError):accept.approved(digest)
                approval.write_text(json.dumps(dict(approved=True,planSHA256=digest)))
                self.assertEqual(accept.approved(digest),plan)
                source.write_bytes(b'changed')
                with self.assertRaisesRegex(ValueError,'Frozen'):accept.approved(digest)

    def test_full_original_bytes_metadata_and_actual_reapplication_are_required(self):
        original=dict(kind='file',sha256='a'*64,mode=0o755,uid=0,gid=80)
        on=dict(original,sha256='b'*64)
        targets=['system:/file'];originals={targets[0]:dict(state=original)}
        self.assertTrue(accept.transition({targets[0]:on},{targets[0]:original},{targets[0]:on},originals,targets)['passed'])
        for restored,reapplied in [(dict(original,gid=0),on),(original,dict(on,sha256='c'*64)),(on,on)]:
            with self.assertRaises(ValueError):accept.transition({targets[0]:on},{targets[0]:restored},{targets[0]:reapplied},originals,targets)
        with self.assertRaisesRegex(ValueError,'Incomplete'):accept.transition({}, {}, {},originals,targets)


if __name__=='__main__':unittest.main()
