import CoreLocation
import XCTest
@testable import vphone_cli

final class HostLocationReuseTests: XCTestCase {
    @MainActor func testOnlyFreshValidHostFixCanBeReused() {
        let now = Date(timeIntervalSince1970: 1000)
        func fix(_ age: Double, lat: Double = 31, accuracy: Double = 5) -> CLLocation {
            CLLocation(coordinate: .init(latitude: lat, longitude: 118), altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: now.addingTimeInterval(-age))
        }
        XCTAssertNotNil(VPhoneLocationProvider.reusableHostFix(fix(59), now: now))
        for location in [fix(60),fix(-60),fix(0,lat:91),fix(0,accuracy:-1)] {
            XCTAssertNil(VPhoneLocationProvider.reusableHostFix(location, now: now))
        }
        XCTAssertNil(VPhoneLocationProvider.reusableHostFix(nil, now: now))
    }
    @MainActor func testInvalidReplayIntervalCannotTrapOrChangeSource() {
        for interval in [Double.nan, .infinity, -.infinity, -1, 0, Double.greatestFiniteMagnitude] {
            XCTAssertNil(VPhoneLocationProvider.replayNanoseconds(interval))
        }
        XCTAssertEqual(VPhoneLocationProvider.replayNanoseconds(0.01), 100_000_000)
        XCTAssertEqual(VPhoneLocationProvider.replayNanoseconds(1.5), 1_500_000_000)
    }
}
