import XCTest
import VPhoneCore
@testable import vphone_cli

/// UDS payload parsing coverage. Guest connection and source ownership require
/// integration tests with a running VM.
final class LocationHostControlParsingTests: XCTestCase {
    func testStreamFixParsesFractionalISO8601Deterministically() throws {
        let payload: [String: Any] = [
            "producer_sequence": 3,
            "lat": 31.2,
            "lon": 118.8,
            "timestamp": "2026-08-05T10:00:00.123456+08:00",
        ]
        let first = try VPhoneHostControl.systemLocationFix(payload)
        let retry = try VPhoneHostControl.systemLocationFix(payload)
        XCTAssertEqual(first, retry)
        XCTAssertEqual(first.producerSequence, 3)
        XCTAssertGreaterThan(first.timestamp, 0)
    }

    func testStreamFixRejectsInvalidTimestamp() {
        XCTAssertThrowsError(try VPhoneHostControl.systemLocationFix([
            "producer_sequence": 0,
            "lat": 31.2,
            "lon": 118.8,
            "timestamp": "not-a-time",
        ])) { error in
            XCTAssertEqual(
                (error as? VPhoneSystemLocationError)?.code,
                "invalid_location_source")
        }
    }
}
