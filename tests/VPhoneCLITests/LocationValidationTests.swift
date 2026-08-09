import XCTest
@testable import vphone_cli

/// Unit coverage for the pure parameter validator on the `location` UDS command
/// boundary. The disconnect-race and location-source-ownership paths need a live
/// guest and are exercised by integration, not here.
final class LocationValidationTests: XCTestCase {
    private func err(
        lat: Double = 31.2304, lon: Double = 121.4737, alt: Double = 0,
        hacc: Double = 5, vacc: Double = 5, speed: Double = 0, course: Double = -1
    ) -> String? {
        VPhoneHostControl.locationValidationError(
            lat: lat, lon: lon, alt: alt, hacc: hacc,
            vacc: vacc, speed: speed, course: course)
    }

    func testValidFixAccepted() {
        XCTAssertNil(err())
        // course sentinel -1 (heading unknown) must stay valid.
        XCTAssertNil(err(course: -1))
        XCTAssertNil(err(speed: -1))
        XCTAssertNotNil(err(speed: -2))
        XCTAssertNotNil(err(vacc: -1))
    }

    func testLatLonRangeRejected() {
        XCTAssertNotNil(err(lat: 121, lon: 31))   // swapped lat/lon
        XCTAssertNotNil(err(lat: 90.001))
        XCTAssertNotNil(err(lat: -90.001))
        XCTAssertNotNil(err(lon: 180.001))
        XCTAssertNotNil(err(lon: -180.001))
        // Inclusive bounds are accepted.
        XCTAssertNil(err(lat: 90, lon: 180))
        XCTAssertNil(err(lat: -90, lon: -180))
    }

    func testNegativeAccuracyRejected() {
        XCTAssertNotNil(err(hacc: -1))
        XCTAssertNotNil(err(hacc: 0))
        XCTAssertNotNil(err(vacc: 0))
    }

    func testCourseRangeRejected() {
        XCTAssertNotNil(err(course: 400))
        XCTAssertNotNil(err(course: -2))
        XCTAssertNotNil(err(course: 360))     // 360 is out of [0,360)
        XCTAssertNil(err(course: 0))
        XCTAssertNil(err(course: 359.9))
    }

    func testNonFiniteRejected() {
        XCTAssertNotNil(err(lat: .nan))
        XCTAssertNotNil(err(lon: .infinity))
        XCTAssertNotNil(err(alt: .nan))
        XCTAssertNotNil(err(hacc: .infinity))
    }

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
                (error as? SystemLocationControllerError)?.code,
                "invalid_location_source")
        }
    }
}
