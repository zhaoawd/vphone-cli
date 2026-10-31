import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image
import observe_t32_runtime as observation


class RuntimeObservationTests(unittest.TestCase):
    def test_blank_and_unchanged_display_never_pass(self):
        with tempfile.TemporaryDirectory() as raw:
            root=Path(raw);a=root/'a.png';b=root/'b.png'
            Image.new('RGB',(128,128),'black').save(a)
            Image.new('RGB',(128,128),'black').save(b)
            with self.assertRaisesRegex(ValueError,'uniform'):observation.compare_images(a,b)
            image=Image.new('RGB',(128,128),'black');image.paste((255,255,255),(0,0,64,64));image.save(a);image.save(b)
            with self.assertRaisesRegex(ValueError,'did not change'):observation.compare_images(a,b)
            image.paste((255,0,0),(64,64,128,128));image.save(b)
            result=observation.compare_images(a,b)
            self.assertTrue(result['distinct']);self.assertIn('causality unproven',result['scope'])

    def test_plan_approval_tool_and_backup_tampering_refuse(self):
        with tempfile.TemporaryDirectory() as raw:
            root=Path(raw);tool=root/'frozen';tool.write_bytes(b'frozen')
            backup=root/'runtime-backup.json';backup.write_bytes(b'{}')
            plan=dict(frozenTools={str(tool):hashlib.sha256(tool.read_bytes()).hexdigest()},
                      backupManifestSHA256=hashlib.sha256(backup.read_bytes()).hexdigest())
            data=json.dumps(plan).encode();digest=hashlib.sha256(data).hexdigest()
            (root/'runtime-plan.json').write_bytes(data)
            with patch.object(observation,'WORK',root):
                with self.assertRaises(FileNotFoundError):observation.approved_plan(digest)
                (root/'runtime-approval.json').write_text(json.dumps(dict(approved=False,planSHA256=digest)))
                with self.assertRaises(ValueError):observation.approved_plan(digest)
                (root/'runtime-approval.json').write_text(json.dumps(dict(approved=True,planSHA256=digest)))
                self.assertEqual(observation.approved_plan(digest),plan)
                tool.write_bytes(b'changed')
                with self.assertRaisesRegex(ValueError,'Frozen input'):observation.approved_plan(digest)
                tool.write_bytes(b'frozen');backup.write_bytes(b'changed')
                with self.assertRaisesRegex(ValueError,'backup manifest'):observation.approved_plan(digest)


if __name__=='__main__':unittest.main()
