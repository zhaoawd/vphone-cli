import XCTest
@testable import VPhoneCore

final class SystemLocationValidationTests: XCTestCase {
    private func error(
        latitude: Double = 31.2304,
        longitude: Double = 121.4737,
        altitude: Double = 0,
        horizontalAccuracy: Double = 5,
        verticalAccuracy: Double = 5,
        speed: Double = 0,
        course: Double = -1
    ) -> String? {
        VPhoneSystemLocationValidation.error(
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy,
            speed: speed,
            course: course)
    }

    func testValidFixAccepted() {
        XCTAssertNil(error())
        XCTAssertNil(error(course: -1))
        XCTAssertNil(error(speed: -1))
        XCTAssertNotNil(error(speed: -2))
        XCTAssertNotNil(error(verticalAccuracy: -1))
    }

    func testLatitudeAndLongitudeRangeRejected() {
        XCTAssertNotNil(error(latitude: 121, longitude: 31))
        XCTAssertNotNil(error(latitude: 90.001))
        XCTAssertNotNil(error(latitude: -90.001))
        XCTAssertNotNil(error(longitude: 180.001))
        XCTAssertNotNil(error(longitude: -180.001))
        XCTAssertNil(error(latitude: 90, longitude: 180))
        XCTAssertNil(error(latitude: -90, longitude: -180))
    }

    func testNonPositiveAccuracyRejected() {
        XCTAssertNotNil(error(horizontalAccuracy: -1))
        XCTAssertNotNil(error(horizontalAccuracy: 0))
        XCTAssertNotNil(error(verticalAccuracy: 0))
    }

    func testCourseRangeRejected() {
        XCTAssertNotNil(error(course: 400))
        XCTAssertNotNil(error(course: -2))
        XCTAssertNotNil(error(course: 360))
        XCTAssertNil(error(course: 0))
        XCTAssertNil(error(course: 359.9))
    }

    func testNonFiniteValuesRejected() {
        XCTAssertNotNil(error(latitude: .nan))
        XCTAssertNotNil(error(longitude: .infinity))
        XCTAssertNotNil(error(altitude: .nan))
        XCTAssertNotNil(error(horizontalAccuracy: .infinity))
    }
}
