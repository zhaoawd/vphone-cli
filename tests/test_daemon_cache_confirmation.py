"""Cache confirmation must identify the cached file across canonical path aliases."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[1]
@unittest.skipUnless(sys.platform=='darwin' and shutil.which('clang'),'macOS clang required')
class CacheConfirmationTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cls.temp=tempfile.TemporaryDirectory(prefix='vphone-cache-build-');cls.binary=Path(cls.temp.name)/'probe'
  subprocess.run(['clang','-x','c','-Wno-deprecated-declarations',str(ROOT/'tests/fixtures/daemon_cache_confirmation/main.c'),'-o',str(cls.binary)],check=True,capture_output=True)
 @classmethod
 def tearDownClass(cls):cls.temp.cleanup()
 def check_confirmation(self,mode):
  with tempfile.TemporaryDirectory(prefix='vphone-cache-confirm-') as temp:
   root=Path(temp);physical=root/'physical';physical.mkdir();alias=root/'alias';alias.symlink_to(physical,target_is_directory=True)
   image=physical/'vphoned';image.write_bytes(b'cached executable fixture');pending=physical/'pending';pending.write_bytes(b'expected hash');marker=physical/'confirmed'
   configured=alias/'vphoned';running=image
   if mode=='other':running=physical/'other';running.write_bytes(b'other executable fixture')
   if mode=='symlink':configured=physical/'linked';configured.symlink_to(image)
   p=subprocess.run([str(self.binary),str(configured),str(pending),str(marker),str(running)],capture_output=True,text=True,timeout=5)
   confirmed=mode=='alias';self.assertEqual(p.returncode,0 if confirmed else 1,p.stderr)
   self.assertEqual(marker.exists(),confirmed);self.assertEqual(pending.exists(),not confirmed)
   self.assertEqual((marker if confirmed else pending).read_bytes(),b'expected hash')
 def test_canonical_directory_alias_confirms_the_same_cached_file(self):self.check_confirmation('alias')
 def test_different_executable_does_not_confirm(self):self.check_confirmation('other')
 def test_symlinked_cache_entry_is_not_confirmed(self):self.check_confirmation('symlink')
