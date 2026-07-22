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
        // negative vacc / speed are CoreLocation "unknown" sentinels — permissive.
        XCTAssertNil(err(vacc: -1, speed: -1))
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
        XCTAssertNil(err(hacc: 0))
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
}
