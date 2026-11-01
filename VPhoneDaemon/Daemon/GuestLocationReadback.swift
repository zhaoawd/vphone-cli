import CoreFoundation
import Foundation

/// Confirm the dependency's response at the API boundary. A cached fix after
/// its matching wait expires must not acknowledge a different requested point.
enum GuestLocationReadback {
    struct Failure: Error, CustomStringConvertible {
        let clearError: String?
        var description: String {
            if let clearError {
                return "locationd did not confirm the requested simulated location; clear failed: \(clearError)"
            }
            return "locationd did not confirm the requested simulated location"
        }
    }

    static func set(
        latitude: Double, longitude: Double,
        simulate: () throws -> [String: Any], clear: () throws -> [String: Any]
    ) throws -> [String: Any] {
        // The dependency cleans up its own failures; never replay the write.
        let result = try simulate()
        guard isTrue(result["simulating"]),
              let reading = result["location"] as? [String: Any],
              isTrue(reading["fresh"]), isTrue(reading["simulated"]),
              let reportedLatitude = number(reading["latitude"]),
              let reportedLongitude = number(reading["longitude"]),
              abs(reportedLatitude - latitude) < 1e-7,
              abs(reportedLongitude - longitude) < 1e-7
        else {
            do {
                let stopped = try clear()
                guard let value = stopped["simulating"] as? NSNumber,
                      CFGetTypeID(value) == CFBooleanGetTypeID(), !value.boolValue
                else { throw Failure(clearError: "stop was not confirmed") }
            } catch {
                throw Failure(clearError: String(describing: error))
            }
            throw Failure(clearError: nil)
        }
        return result
    }

    private static func isTrue(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return false }
        return number.boolValue
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite
        else { return nil }
        return number.doubleValue
    }
}
