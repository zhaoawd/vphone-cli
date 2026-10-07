"""Exercise the daemon error payload through real JSON serialization."""
import subprocess,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
class GuestOperationFailureTests(unittest.TestCase):
    def test_bundle_failure_details_and_machine_error_code_survive_json(self):
        with tempfile.TemporaryDirectory(prefix="vphone error ") as directory:
            root=Path(directory); main=root/"main.swift"; binary=root/"error"
            main.write_text(r'''import Foundation
import Darwin
let output: [String: Any] = ["failed":["/var/jb/Applications/Provider.app"],"unverified":["provider.extension"],"error":"refresh_incomplete"]
let response=GuestOperationFailure.response(code:"command_failed",message:"refresh failed",details:output)
let data=try JSONSerialization.data(withJSONObject:response)
let decoded=try JSONSerialization.jsonObject(with:data) as! [String: Any]
let details=decoded["details"] as! [String: Any]
if decoded["code"] as? String != "command_failed" || details["failed"] as? [String] != ["/var/jb/Applications/Provider.app"] || details["unverified"] as? [String] != ["provider.extension"] { exit(1) }
if GuestOperationFailure.response(code:"invalid_operation",message:"missing",details:nil)["details"] != nil { exit(2) }
''')
            result=subprocess.run(["swiftc",str(ROOT/"sources/VPhoneDaemon/Daemon/GuestOperationFailure.swift"),str(main),"-o",str(binary)],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            result=subprocess.run([str(binary)],capture_output=True,text=True,timeout=5)
            self.assertEqual(result.returncode,0,result.stderr)
