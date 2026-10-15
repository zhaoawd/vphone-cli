import Foundation
import XCTest
@testable import FirmwarePatcher

final class FirmwareKernelIOTimingTests: XCTestCase {
    func testPartialConsumerFailurePreservesErrorAndActualReadBytes() throws {
        final class Expected: Error {}
        let expected = Expected()
        let file = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("vphone-kernel-io-partial-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(repeating: 0x61, count: 2 << 20).write(to: file)
        var observed = 0
        do {
            try FirmwareGeneration.readFile(file) { bytes in
                observed += bytes.count
                throw expected
            }
            XCTFail("Expected the first consumer call to throw")
        } catch {
            XCTAssertTrue((error as AnyObject) === expected)
        }
        XCTAssertEqual(observed, 1 << 20)
    }
}
