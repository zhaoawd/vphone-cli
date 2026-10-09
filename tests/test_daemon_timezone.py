"""Compile the production timezone dispatch with deterministic service boundaries."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
@unittest.skipUnless(shutil.which('swiftc'),'Swift compiler required')
class DaemonTimeZoneTests(unittest.TestCase):
    def test_query_and_both_setters_dispatch_to_pinned_iclikit(self):
        source=(ROOT/'sources/VPhoneDaemon/Daemon/GuestAPI+TimeZone.swift').read_text().replace('import IcliKit','')
        stubs='''
struct GuestAPI {
 static func optionalString(_ params:[String:Any],_ key:String)->String? {
  guard let s=params[key] as? String,!s.isEmpty else{return nil};return s
 }
}
func timeZone() throws->[String:Any]{["operation":"get"]}
func setTimeZone(_ s:String)throws->[String:Any]{["operation":"zone","value":s]}
func setAutomaticTimeZone(_ b:Bool)throws->[String:Any]{["operation":"automatic","value":b]}
func require(_ b:Bool){if !b{fatalError("wrong timezone operation")}}
require(try GuestAPI.executeTimeZone("other",[:]) == nil)
require(try GuestAPI.executeTimeZone("time.timezone",[:])?["operation"] as? String == "get")
require(try GuestAPI.executeTimeZone("time.timezone",["identifier":"Asia/Shanghai"])?["value"] as? String == "Asia/Shanghai")
require(try GuestAPI.executeTimeZone("time.timezone",["automatic":false])?["value"] as? Bool == false)
require(try GuestAPI.executeTimeZone("time.timezone",["automatic":true])?["value"] as? Bool == true)
print("timezone dispatch passed")
'''
        with tempfile.TemporaryDirectory(prefix='vphone-timezone-') as temp:
            p=Path(temp);(p/'main.swift').write_text(source+'\n'+stubs)
            subprocess.run(['swiftc',str(p/'main.swift'),'-o',str(p/'probe')],check=True,capture_output=True)
            result=subprocess.run([str(p/'probe')],capture_output=True,text=True,check=True,timeout=10)
            self.assertIn('timezone dispatch passed',result.stdout)
