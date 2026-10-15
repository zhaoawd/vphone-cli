"""Execute the production APIWire operation boundary with real ObjC temporaries."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('swiftc'), 'macOS Swift required')
class DaemonOperationPoolTests(unittest.TestCase):
    def test_success_and_error_release_temporaries_before_returning(self):
        with tempfile.TemporaryDirectory(prefix='vphone-operation-pool-') as temporary:
            root = Path(temporary)
            probe = root / 'probe.m'
            probe.write_text('''#import <Foundation/Foundation.h>
static int live = 0;
@interface APITracked : NSObject @end
@implementation APITracked
- (id)init { self = [super init]; if (self) live++; return self; }
- (void)dealloc { live--; [super dealloc]; }
@end
void fixture_create_autoreleased(void) { [[[APITracked alloc] init] autorelease]; }
int fixture_live_count(void) { return live; }
''')
            subprocess.run(['clang', '-c', str(probe), '-o', str(root / 'probe.o')], check=True, capture_output=True)
            # Compile the actual request execution implementation; the platform
            # services and NIO event hub are outside this allocation-lifetime test.
            source = (ROOT / 'sources/VPhoneDaemon/Daemon/APIWire.swift').read_text()
            boundary = source.split('/// A client receives guest events', 1)[0]
            boundary = '\n'.join(line for line in boundary.splitlines() if line not in
                                 ('import IcliSystem', 'import NIOCore', 'import NIOWebSocket'))
            stubs = '''
@_silgen_name("fixture_create_autoreleased") func createTemporary()
@_silgen_name("fixture_live_count") func liveCount() -> Int32
struct APIRequest {
    let method: String
    let params: [String: Any] = [:]
    let id: String? = "request"
    static func decode(_ data: Data) throws -> Self { Self(method: "ok") }
}
enum IcliError: Error, @unchecked Sendable {
    case commandFailed([String: Any])
    var code: String { "command_failed" }
    var message: String { "fixture failure" }
}
enum GuestAPIError: Error { case invalid }
enum GuestOperationFailure {
    static func response(code: String, message: String, details: [String: Any]?) -> [String: Any] {
        ["code": code, "message": message]
    }
}
enum GuestAPI {
    static func execute(method: String, params: [String: Any], externalProxy: Bool) throws -> [String: Any] {
        createTemporary()
        if method == "fail" { throw IcliError.commandFailed([:]) }
        return ["value": "retained response"]
    }
}
// An enclosing pool deliberately stays alive across all requests. Each API
// operation must release its own ObjC temporary on both result paths.
autoreleasepool {
    for method in ["ok", "fail", "ok", "fail"] {
        let reply = APIWire.execute(APIRequest(method: method), externalProxy: false)
        guard liveCount() == 0 else {
            fputs("temporary survived operation return\\n", stderr); exit(1)
        }
        guard (try? JSONSerialization.jsonObject(with: reply.data)) != nil else { exit(2) }
        guard reply.status == (method == "fail" ? 400 : 200) else { exit(3) }
    }
}
'''
            main = root / 'main.swift'
            main.write_text(boundary + '\n' + stubs)
            binary = root / 'probe'
            compile_result = subprocess.run(['swiftc', str(main), str(root / 'probe.o'), '-o', str(binary)],
                                            capture_output=True, text=True, timeout=90)
            self.assertEqual(compile_result.returncode, 0, compile_result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
