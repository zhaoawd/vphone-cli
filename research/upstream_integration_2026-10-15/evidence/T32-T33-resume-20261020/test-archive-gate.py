"""Synthetic final-evidence gate checks; no real VM acceptance is created."""
import copy,importlib.util,unittest
from pathlib import Path
r=Path(__file__).resolve().parents[2]
def module(name,path):
 spec=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
oldtests=module('old_archive_tests',r/'.build/t32-cryptex-symlink-debug/test-archive.py')
archive=module('current_archive',Path(__file__).with_name('archive-acceptance.py'))
class CurrentArchiveGateTests(unittest.TestCase):
 def fixture(self):
  result,proofs=oldtests.ArchiveGateTests().fixture()
  for phase in ('installed','reapplied'):
   proofs[phase].update(verifiedOriginalCodePages=6885,verifiedInstalledCodePages=6885,originalInstruction={'value':0x548},installedInstruction={'value':0x560},originalSHA256=result['originalSHA256'],installedSHA256=result['installedSHA256'])
  proofs['restored'].update(verifiedRestoredCodePages=6885,restoredInstruction={'value':0x548},originalSHA256=result['originalSHA256'],parentTransactionID=result['transactions']['installed'],guestOrigin='unknown')
  for phase in ('restored','reapplied'):
   proofs['api-'+phase]['cycles']=[dict(guestStopped=True,forcedFrameworkStop=False,diskReleased=True,stopExitCode=0,vmExitCode=0,bootSessionUUID='session-'+str(i),bootSeconds=i,systemVersion={'ProductVersion':'26.0','ProductBuildVersion':'23A341'}) for i in (1,2)]
   proofs['postboot-'+phase].update(transactionID=result['transactions'][phase],commands=[{'exitCode':0},{'exitCode':0}])
  return result,proofs
 def test_complete_synthetic_proofs(self):archive.validate(*self.fixture())
 def test_rejects_page_instruction_parent_and_origin_changes(self):
  changes=[('installed','verifiedOriginalCodePages',6884),('reapplied','verifiedInstalledCodePages',6884),('restored','verifiedRestoredCodePages',6884),('installed','originalInstruction',{'value':0x560}),('reapplied','installedInstruction',{'value':0x548}),('restored','parentTransactionID','unrelated'),('restored','guestOrigin','trusted')]
  for phase,key,value in changes:
   result,proofs=self.fixture();proofs[phase][key]=value
   with self.subTest(phase=phase,key=key),self.assertRaises(ValueError):archive.validate(result,proofs)
 def test_rejects_boot_shutdown_and_postboot_changes(self):
  for phase in ('restored','reapplied'):
   for key,value in [('guestStopped',False),('forcedFrameworkStop',True),('diskReleased',False),('stopExitCode',1),('vmExitCode',1),('bootSessionUUID','session-1'),('bootSeconds',1),('systemVersion',{'ProductVersion':'26.1','ProductBuildVersion':'23B85'})]:
    result,proofs=self.fixture();proofs['api-'+phase]['cycles'][1][key]=value
    with self.subTest(phase=phase,key=key),self.assertRaises(ValueError):archive.validate(result,proofs)
   for key,value in [('transactionID','unrelated'),('commands',[{'exitCode':0}]),('commands',[{'exitCode':0},{'exitCode':1}])]:
    result,proofs=self.fixture();proofs['postboot-'+phase][key]=value
    with self.subTest(phase=phase,key=key),self.assertRaises(ValueError):archive.validate(result,proofs)
if __name__=='__main__':unittest.main(verbosity=2)
