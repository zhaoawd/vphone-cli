import Foundation

// Keep firmware-dependent tests in this target so `make test` never needs IPSWs.
let firmwareFixtureDirectory: URL = {
    if let directory = ProcessInfo.processInfo.environment["VPHONE_TEST_FIXTURES"],
       !directory.isEmpty {
        return URL(fileURLWithPath: directory)
    }
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ipsws/patch_refactor_input")
}()
