import XCTest
import VPhoneCore
@testable import vphone_cli

/// UDS payload parsing coverage. Guest connection and source ownership require
/// integration tests with a running VM.
final class LocationHostControlParsingTests: XCTestCase {
    private func parsedJSON(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8))
                as? [String: Any])
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
                (error as? VPhoneSystemLocationError)?.code,
                "invalid_location_source")
        }
    }

    func testStreamFixRejectsBooleanAndWrongTypedNumbersFromJSON() throws {
        let invalidPayloads = [
            #"{"producer_sequence":false,"lat":31.2,"lon":118.8}"#,
            #"{"producer_sequence":0,"lat":true,"lon":118.8}"#,
            #"{"producer_sequence":0,"lat":31.2,"lon":118.8,"hacc":true}"#,
            #"{"producer_sequence":0,"lat":31.2,"lon":118.8,"alt":"0"}"#,
            #"{"producer_sequence":0,"lat":31.2,"lon":118.8,"timestamp":false}"#,
        ]

        for payload in invalidPayloads {
            XCTAssertThrowsError(
                try VPhoneHostControl.systemLocationFix(parsedJSON(payload)),
                "payload should be rejected: \(payload)"
            ) { error in
                XCTAssertEqual(
                    (error as? VPhoneSystemLocationError)?.code,
                    "invalid_location_source")
            }
        }
    }

    func testLocationCommandOptionsKeepJSONTypesDistinct() throws {
        let values = try parsedJSON(#"""
        {
          "heartbeat_s": true,
          "replace": 1,
          "on_timeout": false,
          "generation": 7
        }
        """#)

        XCTAssertThrowsError(try VPhoneHostControl.locationDouble(
            values, key: "heartbeat_s", defaultValue: 1))
        XCTAssertThrowsError(try VPhoneHostControl.locationBool(
            values, key: "replace", defaultValue: false))
        XCTAssertThrowsError(try VPhoneHostControl.locationString(
            values, key: "on_timeout", defaultValue: "hold"))
        XCTAssertThrowsError(try VPhoneHostControl.locationString(
            values, key: "generation"))
        XCTAssertThrowsError(try VPhoneHostControl.locationString(
            [:], key: "generation"))
        XCTAssertEqual(
            try VPhoneHostControl.locationDouble([:], key: "heartbeat_s", defaultValue: 1),
            1)
        XCTAssertEqual(
            try VPhoneHostControl.locationBool([:], key: "replace", defaultValue: false),
            false)
        XCTAssertEqual(
            try VPhoneHostControl.locationString([:], key: "on_timeout", defaultValue: "hold"),
            "hold")
    }

    func testProducerSequenceRejectsJSONIntegersOutsideExactRange() throws {
        let maximum = try parsedJSON(
            #"{"producer_sequence":9007199254740991}"#)
        let tooLarge = try parsedJSON(
            #"{"producer_sequence":9007199254740993}"#)

        XCTAssertEqual(
            try VPhoneHostControl.locationInteger(maximum, key: "producer_sequence"),
            9_007_199_254_740_991)
        XCTAssertThrowsError(
            try VPhoneHostControl.locationInteger(tooLarge, key: "producer_sequence")
        ) { error in
            XCTAssertEqual(
                (error as? VPhoneSystemLocationError)?.code,
                "invalid_location_source")
        }
    }

    @MainActor
    func testStructuredGuestErrorCodeSurvivesLocationAdapterMapping() {
        let mapped = VPhoneControlLocationGuestAdapter.map(
            VPhoneControl.ControlError.guestError(
                code: "location_sequence_conflict",
                message: "sequence rejected"))

        XCTAssertEqual(mapped.code, "location_sequence_conflict")
        XCTAssertEqual(mapped.message, "sequence rejected")
    }

    func testGuestErrorResponsePreservesStructuredCode() {
        let error = VPhoneControl.controlError(forGuestResponse: [
            "t": "err",
            "code": "location_generation_conflict",
            "msg": "stale generation",
        ])

        guard case let .guestError(code, message) = error else {
            return XCTFail("expected guestError")
        }
        XCTAssertEqual(code, "location_generation_conflict")
        XCTAssertEqual(message, "stale generation")
    }
}
