import Foundation

/// Serialize source ownership with the actual simulation call. Duplicate
/// deliveries return the recorded result and never submit a second write.
final class GuestOwnedLocation: @unchecked Sendable {
    static let shared = GuestOwnedLocation()

    struct Failure: Error, CustomStringConvertible {
        let code: String
        let description: String
    }

    private let lock = NSRecursiveLock()
    private var generation: String?
    private var lastCleared: String?
    private var sequence: Int?
    private var payload: Data?
    private var result: Result<[String: Any], Error>?

    func begin(_ value: String, clear: () throws -> [String: Any]) throws -> [String: Any] {
        try validate(value)
        lock.lock()
        defer { lock.unlock() }
        _ = try clear()
        generation = value
        lastCleared = nil
        sequence = nil
        payload = nil
        result = nil
        return ["generation": value, "activated": true]
    }

    func deliver(_ value: String, sequence candidate: Int, payload body: [String: Any],
                 apply: () throws -> [String: Any]) throws -> [String: Any] {
        try validate(value)
        guard candidate >= 0, candidate <= 9_007_199_254_740_991,
              JSONSerialization.isValidJSONObject(body)
        else { throw Failure(code: "invalid_location_source", description: "invalid delivery sequence or payload") }
        let bytes = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        lock.lock()
        defer { lock.unlock() }
        guard generation == value else { throw conflict() }
        if let sequence {
            if candidate == sequence {
                guard payload == bytes, let result else { throw sequenceConflict() }
                return try confirmation(result.get(), generation: value, sequence: candidate, idempotent: true)
            }
            guard result != nil, candidate == sequence + 1 else { throw sequenceConflict() }
            // A failed/unknown delivery must be explicitly reactivated or stopped.
            if case .failure? = result { throw sequenceConflict() }
        }
        sequence = candidate
        payload = bytes
        do {
            let delivered = try apply()
            result = .success(delivered)
            return confirmation(delivered, generation: value, sequence: candidate, idempotent: false)
        } catch {
            result = .failure(error)
            throw error
        }
    }

    func stop(_ value: String, clear: () throws -> [String: Any]) throws -> [String: Any] {
        try validate(value)
        lock.lock()
        defer { lock.unlock() }
        if generation == nil, lastCleared == value {
            return ["generation": value, "simulating": false, "idempotent": true]
        }
        guard generation == value else { throw conflict() }
        let stopped = try clear()
        generation = nil
        lastCleared = value
        sequence = nil
        payload = nil
        result = nil
        return stopped.merging(["generation": value, "idempotent": false]) { _, new in new }
    }

    func unowned(_ action: () throws -> [String: Any]) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        guard generation == nil else { throw conflict() }
        return try action()
    }

    private func confirmation(_ reading: [String: Any], generation: String, sequence: Int, idempotent: Bool) -> [String: Any] {
        reading.merging(["generation": generation, "delivery_sequence": sequence, "idempotent": idempotent]) { _, new in new }
    }

    private func validate(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 128, !value.utf8.contains(0) else {
            throw Failure(code: "invalid_location_source", description: "invalid location generation")
        }
    }

    private func conflict() -> Failure {
        Failure(code: "location_generation_conflict", description: "location generation does not own the guest source")
    }

    private func sequenceConflict() -> Failure {
        Failure(code: "location_sequence_conflict", description: "delivery sequence or payload conflicts with the recorded delivery")
    }
}
