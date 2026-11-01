import CoreFoundation
import Foundation
import VPhoneCoreKit

@MainActor
final class VPhoneSystemLocationAutomation {
    let controller: VPhoneSystemLocationController
    private let ownershipCheck: @MainActor @Sendable () throws -> Void

    init(control: VPhoneGuestControl, stateURL: URL, ownershipCheck: @escaping @MainActor @Sendable () throws -> Void) {
        self.ownershipCheck = ownershipCheck
        controller = VPhoneSystemLocationController(adapter: VPhoneOwnedLocationGuestAdapter(control: control),
            stateStore: VPhoneSystemLocationStateStore(url: stateURL))
    }

    func handle(_ type: String, _ json: [String: Any]) async -> [String: Any] {
        do {
            switch type {
            case "location_source_status": return controller.snapshot()
            case "location_source_set":
                guard json["mode"] as? String == "fixed" else {
                    throw VPhoneSystemLocationError(code: "invalid_location_source", message: "mode must be fixed")
                }
                try Self.requireWGS84(json)
                return try await controller.setFixed(owner: Self.locationString(json, key: "owner"),
                    fix: Self.systemLocationFix(json), heartbeatSeconds: Self.locationDouble(json, key: "heartbeat_s", defaultValue: 1),
                    replace: Self.locationBool(json, key: "replace", defaultValue: false),
                    persist: Self.locationBool(json, key: "persist", defaultValue: false), precommit: ownershipCheck)
            case "location_stream_start":
                try Self.requireWGS84(json)
                return try await controller.startStream(owner: Self.locationString(json, key: "owner"),
                    watchdogSeconds: Self.locationDouble(json, key: "watchdog_s", defaultValue: 3),
                    onTimeout: Self.locationString(json, key: "on_timeout", defaultValue: "hold"),
                    replace: Self.locationBool(json, key: "replace", defaultValue: false), precommit: ownershipCheck)
            case "location_stream_push":
                return try await controller.push(generation: Self.locationString(json, key: "generation"), fix: Self.systemLocationFix(json))
            case "location_source_control":
                return try await controller.setPaused(Self.locationBool(json, key: "paused"), generation: Self.locationString(json, key: "generation"))
            case "location_source_stop":
                return try await controller.stop(generation: Self.locationString(json, key: "generation"))
            default: throw VPhoneSystemLocationError(code: "invalid_location_source", message: "unknown source operation")
            }
        } catch let failure as VPhoneSystemLocationError {
            return ["ok": false, "code": failure.code, "error": failure.message]
        } catch { return ["ok": false, "code": "location_delivery_rejected", "error": String(describing: error)] }
    }

    private nonisolated static func requireWGS84(_ json: [String: Any]) throws {
        guard (json["coordinate_system"] as? String)?.lowercased() == "wgs84" else {
            throw VPhoneSystemLocationError(
                code: "invalid_location_source",
                message: "coordinate_system must be wgs84")
        }
    }

    nonisolated static func locationDouble(
        _ json: [String: Any],
        key: String,
        defaultValue: Double? = nil
    ) throws -> Double {
        guard let raw = json[key] else {
            if let defaultValue { return defaultValue }
            throw invalidLocationField(key, expected: "a number")
        }
        guard let number = strictJSONNumber(raw) else {
            throw invalidLocationField(key, expected: "a number")
        }
        return number.doubleValue
    }

    nonisolated static func locationInteger(
        _ json: [String: Any],
        key: String
    ) throws -> Int {
        let value = try locationDouble(json, key: key)
        let maximumSafeJSONInteger = 9_007_199_254_740_991.0
        guard value.isFinite,
              abs(value) <= maximumSafeJSONInteger,
              let integer = Int(exactly: value)
        else {
            throw invalidLocationField(key, expected: "a safe integer")
        }
        return integer
    }

    nonisolated static func locationBool(
        _ json: [String: Any],
        key: String,
        defaultValue: Bool? = nil
    ) throws -> Bool {
        guard let raw = json[key] else {
            if let defaultValue { return defaultValue }
            throw invalidLocationField(key, expected: "a boolean")
        }
        guard let number = raw as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else {
            throw invalidLocationField(key, expected: "a boolean")
        }
        return number.boolValue
    }

    nonisolated static func locationString(
        _ json: [String: Any],
        key: String,
        defaultValue: String? = nil
    ) throws -> String {
        guard let raw = json[key] else {
            if let defaultValue { return defaultValue }
            throw invalidLocationField(key, expected: "a string")
        }
        guard let value = raw as? String else {
            throw invalidLocationField(key, expected: "a string")
        }
        return value
    }

    private nonisolated static func strictJSONNumber(_ value: Any) -> NSNumber? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return number
    }

    private nonisolated static func invalidLocationField(
        _ key: String,
        expected: String
    ) -> VPhoneSystemLocationError {
        VPhoneSystemLocationError(
            code: "invalid_location_source",
            message: "\(key) must be \(expected)")
    }

    nonisolated static func systemLocationFix(
        _ json: [String: Any]
    ) throws -> VPhoneSystemLocationFix {
        let sequence = try locationInteger(json, key: "producer_sequence")
        let lat = try locationDouble(json, key: "lat")
        let lon = try locationDouble(json, key: "lon")
        let timestamp: TimeInterval
        if json["timestamp"] == nil {
            timestamp = 0
        } else if let text = json["timestamp"] as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let regular = ISO8601DateFormatter()
            guard let date = fractional.date(from: text) ?? regular.date(from: text) else {
                throw VPhoneSystemLocationError(
                    code: "invalid_location_source", message: "timestamp must be ISO-8601")
            }
            timestamp = date.timeIntervalSince1970
        } else if let raw = json["timestamp"], let numeric = strictJSONNumber(raw) {
            timestamp = numeric.doubleValue
        } else {
            throw invalidLocationField(
                "timestamp", expected: "a number or ISO-8601 string")
        }
        return VPhoneSystemLocationFix(
            producerSequence: sequence,
            latitude: lat, longitude: lon,
            altitude: try locationDouble(json, key: "alt", defaultValue: 0),
            horizontalAccuracy: try locationDouble(json, key: "hacc", defaultValue: 5),
            verticalAccuracy: try locationDouble(json, key: "vacc", defaultValue: 5),
            speed: try locationDouble(json, key: "speed", defaultValue: 0),
            course: try locationDouble(json, key: "course", defaultValue: -1),
            timestamp: timestamp)
    }

}
