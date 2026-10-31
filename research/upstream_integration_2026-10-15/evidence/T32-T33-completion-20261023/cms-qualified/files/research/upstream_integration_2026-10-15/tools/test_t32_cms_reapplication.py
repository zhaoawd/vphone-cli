import json
from pathlib import Path
import tempfile
import unittest

import verify_t32_cms_reapplication as check

ROOT=Path(__file__).resolve().parents[3]
WORK=ROOT/'.build/t32-t33-completion-20261023'

class CMSReapplicationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        first=WORK/'resumed-offline-acceptance/on.json'
        if not first.exists():raise unittest.SkipTest('Actual T32 saved publications required')
        on=json.loads(first.read_text());vm=WORK/'fresh-library/t32-t33-file-acceptance-20261023'
        last=vm/'.cfw-history/20261023T093802Z-XHDHXIve'
        final=json.loads((last/'guest-effects-final.json').read_text())
        cls.pairs=[]
        for row in final['outputs']:
            t=row['target']
            if t in on['targets']:
                cls.pairs.append((vm/'.cfw-history'/on['transactionID']/'effect-blobs'/on['targets'][t]['sha256'],last/'effect-blobs'/row['state']['sha256']))

    def test_real_reapplication_has_only_verified_cms_time_difference(self):
        self.assertEqual(len(self.pairs),3)
        for a,b in self.pairs:
            with self.subTest(file=str(a)):
                r=check.compare(a,b)
                self.assertTrue(r['qualifiedSignatureTimeDifference'])
                self.assertFalse(r['exactFileBytesEqual'])
                self.assertGreater(r['verifiedCodePages'],0)
                self.assertNotEqual(r['firstSigningTime'],r['reappliedSigningTime'])

    def test_corrupted_cms_signature_is_rejected(self):
        a,b=self.pairs[0];data=bytearray(b.read_bytes())
        start,count=check.cms_region(b)
        data[start+count-1]^=1
        with tempfile.TemporaryDirectory() as raw:
            p=Path(raw)/'bad';p.write_bytes(data)
            with self.assertRaises(ValueError):check.compare(a,p)

    def test_valid_time_tampering_without_resigning_is_rejected(self):
        a,b=self.pairs[0];data=bytearray(b.read_bytes())
        start,count=check.cms_region(b)
        _,stamp=check.normalized(data[start:start+count]);offset=data.index(stamp.encode(),start,start+count)
        # Another valid calendar year; only the CMS signature is now invalid.
        data[offset:offset+2]=b'27' if stamp[:2]!='27' else b'28'
        with tempfile.TemporaryDirectory() as raw:
            p=Path(raw)/'bad';p.write_bytes(data)
            with self.assertRaisesRegex(ValueError,'cryptographic'):check.compare(a,p)

    def test_cms_certificate_or_other_fields_change_is_rejected(self):
        a,b=self.pairs[0];data=bytearray(b.read_bytes());start,count=check.cms_region(b)
        data[start+100]^=1
        with tempfile.TemporaryDirectory() as raw:
            p=Path(raw)/'bad';p.write_bytes(data)
            with self.assertRaises(ValueError):check.compare(a,p)

    def test_unsigned_file_change_is_rejected(self):
        a,b=self.pairs[0];data=bytearray(b.read_bytes());data[4096]^=1
        with tempfile.TemporaryDirectory() as raw:
            p=Path(raw)/'bad';p.write_bytes(data)
            with self.assertRaises(ValueError):check.compare(a,p)

    def test_invalid_time_is_rejected(self):
        a,b=self.pairs[0];data=bytearray(b.read_bytes())
        start,count=check.cms_region(b)
        _,time=check.normalized(data[start:start+count]);stamp=time.encode()
        offset=data.index(stamp,start,start+count);data[offset:offset+len(stamp)]=b'0'*len(stamp)
        with tempfile.TemporaryDirectory() as raw:
            p=Path(raw)/'bad';p.write_bytes(data)
            with self.assertRaises(ValueError):check.compare(a,p)

if __name__=='__main__':unittest.main()
