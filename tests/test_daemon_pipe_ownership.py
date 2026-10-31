"""Exercise pinned NIO's early and initializer ownership failures."""
import os
import json
from pathlib import Path
import shutil
import subprocess
import unittest
ROOT=Path(__file__).resolve().parents[1]
class DaemonPipeOwnershipTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  packages=Path(os.environ.get('VPHONE_DAEMON_SOURCE_PACKAGES',str(ROOT/'.build/daemon-api-v2/Xcode/SourcePackages'))).resolve()
  nio=packages/'checkouts/swift-nio'
  if not nio.is_dir():raise unittest.SkipTest('Pinned NIO checkout absent')
  pins=json.loads((ROOT/'sources/VPhoneDaemon/VPhoneDaemon.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())['pins']
  expected=next(pin['state']['revision'] for pin in pins if pin['identity']=='swift-nio')
  actual=subprocess.check_output(['git','-C',str(nio),'rev-parse','HEAD'],text=True).strip()
  if actual!=expected:raise RuntimeError('NIO checkout differs from the pinned revision')
  stage=ROOT/'.build/test-daemon-pipe';source=stage/'Sources/Probe';source.mkdir(parents=True,exist_ok=True)
  shutil.copyfile(ROOT/'tests/fixtures/daemon_pipe_ownership/main.swift',source/'main.swift')
  production=ROOT/'sources/VPhoneDaemon/Daemon/GuestPipeChannel.swift'
  guarded=production.exists()
  if guarded:shutil.copyfile(production,source/production.name)
  else:(source/'GuestPipeChannel.swift').unlink(missing_ok=True)
  settings='[.define("GUARDED_PIPE")]' if guarded else '[]'
  (stage/'Package.swift').write_text('// swift-tools-version:6.0\nimport PackageDescription\nlet package=Package(name:"Probe",dependencies:[.package(path:"'+str(nio)+'")],targets:[.executableTarget(name:"Probe",dependencies:[.product(name:"NIOCore",package:"swift-nio"),.product(name:"NIOPosix",package:"swift-nio")],swiftSettings:'+settings+')])\n')
  subprocess.run(['swift','build','--package-path',str(stage),'--disable-sandbox','-j','4'],env={**os.environ,'SWIFTCI_USE_LOCAL_DEPS':'1'},check=True,timeout=240)
  cls.binary=stage/'.build/debug/Probe'
 def test_early_construction_failure_consumes_descriptors(self):subprocess.run([str(self.binary),'early'],check=True,timeout=15)
 def test_initializer_failure_does_not_close_reused_descriptors(self):subprocess.run([str(self.binary),'initialize'],check=True,timeout=15)
