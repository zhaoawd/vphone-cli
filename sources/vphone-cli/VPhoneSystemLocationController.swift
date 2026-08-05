import Foundation

struct SystemLocationFix: Equatable, Sendable {
    let producerSequence: Int
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    let speed: Double
    let course: Double
    let timestamp: TimeInterval

    func validationError() -> String? {
        VPhoneHostControl.locationValidationError(
            lat: latitude, lon: longitude, alt: altitude,
            hacc: horizontalAccuracy, vacc: verticalAccuracy,
            speed: speed, course: course)
    }

    func holdingPosition() -> SystemLocationFix {
        SystemLocationFix(
            producerSequence: producerSequence,
            latitude: latitude, longitude: longitude, altitude: altitude,
            horizontalAccuracy: horizontalAccuracy, verticalAccuracy: verticalAccuracy,
            speed: 0, course: course, timestamp: Date().timeIntervalSince1970)
    }
}

struct SystemLocationControllerError: Error, LocalizedError, Equatable {
    let code: String
    let message: String

    var errorDescription: String? { message }
}

@MainActor
protocol SystemLocationGuestAdapter: AnyObject {
    func deliver(
        _ fix: SystemLocationFix,
        generation: String,
        deliverySequence: Int
    ) async throws
    func clear(generation: String) async throws
}

@MainActor
final class VPhoneControlLocationGuestAdapter: SystemLocationGuestAdapter {
    private weak var control: VPhoneControl?

    init(control: VPhoneControl) {
        self.control = control
    }

    func deliver(
        _ fix: SystemLocationFix,
        generation: String,
        deliverySequence: Int
    ) async throws {
        guard let control, control.isConnected else {
            throw SystemLocationControllerError(
                code: "location_guest_unavailable", message: "guest not connected")
        }
        guard control.guestCaps.contains("location") else {
            throw SystemLocationControllerError(
                code: "location_guest_unavailable",
                message: "guest does not support location simulation")
        }
        let response: [String: Any]
        do {
            (response, _) = try await control.sendRequest([
                "t": "location",
                "generation": generation,
                "delivery_sequence": deliverySequence,
                "lat": fix.latitude, "lon": fix.longitude, "alt": fix.altitude,
                "hacc": fix.horizontalAccuracy, "vacc": fix.verticalAccuracy,
                "speed": fix.speed, "course": fix.course, "ts": fix.timestamp,
            ])
        } catch let error as VPhoneControl.ControlError {
            throw Self.map(error)
        }
        guard (response["t"] as? String) == "ok" else {
            throw SystemLocationControllerError(
                code: "location_delivery_rejected",
                message: response["msg"] as? String ?? "guest rejected location")
        }
    }

    func clear(generation: String) async throws {
        guard let control, control.isConnected else {
            throw SystemLocationControllerError(
                code: "location_guest_unavailable", message: "guest not connected")
        }
        let response: [String: Any]
        do {
            (response, _) = try await control.sendRequest([
                "t": "location_stop", "generation": generation,
            ])
        } catch let error as VPhoneControl.ControlError {
            throw Self.map(error)
        }
        guard (response["t"] as? String) == "ok" else {
            throw SystemLocationControllerError(
                code: "location_delivery_rejected",
                message: response["msg"] as? String ?? "guest rejected location_stop")
        }
    }

    private static func map(_ error: VPhoneControl.ControlError) -> SystemLocationControllerError {
        switch error {
        case .notConnected, .unsupportedCapability:
            SystemLocationControllerError(
                code: "location_guest_unavailable", message: error.description)
        case .requestTimedOut:
            SystemLocationControllerError(
                code: "location_delivery_timeout", message: error.description)
        default:
            SystemLocationControllerError(
                code: "location_delivery_rejected", message: error.description)
        }
    }
}

/// Device-scoped owner of external fixed and stream location sources.
///
/// Producer sequence advances only after a guest ACK. Delivery sequence is
/// independent and covers heartbeat, watchdog and reconnect re-delivery.
@MainActor
final class VPhoneSystemLocationController {
    private enum Mode: String { case fixed, stream }
    private enum State: String { case off, applying, running, paused }

    private let adapter: SystemLocationGuestAdapter
    private var mode: Mode?
    private var state: State = .off
    private var owner: String?
    private(set) var generation: String?
    private var lastProducerFix: SystemLocationFix?
    private var lastAppliedFix: SystemLocationFix?
    private var lastProducerSequence: Int?
    private var deliverySequence = -1
    private var lastAckAt: Date?
    private var lastError: SystemLocationControllerError?
    private var streamWatchdogSeconds = 3.0
    private var heartbeatTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    init(adapter: SystemLocationGuestAdapter) {
        self.adapter = adapter
    }

    func setFixed(
        owner: String,
        fix: SystemLocationFix,
        heartbeatSeconds: Double,
        replace: Bool = false
    ) async throws -> [String: Any] {
        try validateOwner(owner)
        try validateFix(fix)
        guard heartbeatSeconds.isFinite, heartbeatSeconds > 0 else {
            throw failure("invalid_location_source", "heartbeat_s must be > 0")
        }
        try replaceSource(mode: .fixed, owner: owner, allowReplace: replace)
        lastProducerFix = fix
        lastProducerSequence = fix.producerSequence
        try await deliver(fix)
        startHeartbeat(seconds: heartbeatSeconds)
        return snapshot()
    }

    func startStream(
        owner: String,
        watchdogSeconds: Double,
        replace: Bool = false
    ) throws -> [String: Any] {
        try validateOwner(owner)
        guard watchdogSeconds.isFinite, watchdogSeconds > 0 else {
            throw failure("invalid_location_source", "watchdog_s must be > 0")
        }
        try replaceSource(mode: .stream, owner: owner, allowReplace: replace)
        streamWatchdogSeconds = watchdogSeconds
        scheduleWatchdog(seconds: watchdogSeconds)
        return snapshot()
    }

    func push(
        generation requestedGeneration: String,
        fix: SystemLocationFix
    ) async throws -> [String: Any] {
        try requireGeneration(requestedGeneration, mode: .stream)
        try validateFix(fix)
        if let lastProducerSequence {
            if fix.producerSequence == lastProducerSequence {
                guard fix == lastProducerFix else {
                    throw failure(
                        "location_sequence_conflict",
                        "producer sequence reused with a different payload")
                }
                return snapshot()
            }
            guard fix.producerSequence == lastProducerSequence + 1 else {
                throw failure(
                    "location_sequence_conflict",
                    "producer sequence must advance by one")
            }
        } else if fix.producerSequence != 0 {
            throw failure(
                "location_sequence_conflict", "first producer sequence must be 0")
        }

        try await deliver(fix)
        lastProducerFix = fix
        lastProducerSequence = fix.producerSequence
        scheduleWatchdog(seconds: streamWatchdogSeconds)
        return snapshot()
    }

    func setPaused(_ paused: Bool, generation requestedGeneration: String) async throws -> [String: Any] {
        try requireGeneration(requestedGeneration)
        guard let fix = lastProducerFix else {
            throw failure("location_not_running", "no accepted location sample")
        }
        if mode == .stream {
            watchdogTask?.cancel()
            heartbeatTask?.cancel()
        }
        try await deliver(paused ? fix.holdingPosition() : fix)
        state = paused ? .paused : .running
        if mode == .stream {
            if paused {
                startHoldingHeartbeat(seconds: min(1.0, streamWatchdogSeconds))
            } else {
                scheduleWatchdog(seconds: streamWatchdogSeconds)
            }
        }
        return snapshot()
    }

    func stop(generation requestedGeneration: String? = nil) async throws -> [String: Any] {
        guard let activeGeneration = generation else { return snapshot() }
        if let requestedGeneration, requestedGeneration != activeGeneration {
            throw failure(
                "location_generation_conflict", "generation does not own current source")
        }
        try await adapter.clear(generation: activeGeneration)
        resetState()
        return snapshot()
    }

    func clearLegacyLocation() async throws -> [String: Any] {
        let clearGeneration = generation ?? "legacy-uds-clear"
        try await adapter.clear(generation: clearGeneration)
        resetState()
        return snapshot()
    }

    func reapplyAfterReconnect() async {
        guard generation != nil, let fix = lastAppliedFix ?? lastProducerFix else { return }
        let wasPaused = state == .paused
        do {
            try await deliver(fix)
            if wasPaused { state = .paused }
        } catch let error as SystemLocationControllerError {
            lastError = error
            state = .applying
        } catch {
            lastError = failure("location_guest_unavailable", error.localizedDescription)
            state = .applying
        }
    }

    /// A GUI source becomes authoritative without clearing the fix it is about
    /// to replace. Pending external heartbeat/watchdog work is cancelled.
    func relinquishForGUI() {
        resetState()
    }

    func snapshot() -> [String: Any] {
        var desired: [String: Any] = [:]
        if let mode { desired["mode"] = mode.rawValue }
        if let owner { desired["owner"] = owner }
        if let generation { desired["generation"] = generation }
        desired["paused"] = state == .paused

        var applied: [String: Any] = ["last_delivery_sequence": deliverySequence]
        if let lastProducerSequence {
            applied["last_producer_sequence"] = lastProducerSequence
        }
        if let lastAckAt {
            applied["last_ack_at"] = ISO8601DateFormatter().string(from: lastAckAt)
        }
        if let fix = lastAppliedFix {
            applied["last_fix"] = fixDictionary(fix)
        }
        if let lastError {
            applied["last_error"] = ["code": lastError.code, "message": lastError.message]
        }
        return [
            "ok": true,
            "state": state.rawValue,
            "generation": generation.map { $0 as Any } ?? NSNull(),
            "desired": desired,
            "applied": applied,
        ]
    }

    private func replaceSource(mode: Mode, owner: String, allowReplace: Bool) throws {
        if let activeOwner = self.owner, activeOwner != owner, !allowReplace {
            throw failure(
                "location_owner_conflict",
                "location source is owned by \(activeOwner)")
        }
        heartbeatTask?.cancel()
        watchdogTask?.cancel()
        self.mode = mode
        self.owner = owner
        generation = "loc-" + UUID().uuidString.lowercased()
        state = .applying
        lastProducerFix = nil
        lastAppliedFix = nil
        lastProducerSequence = nil
        deliverySequence = -1
        lastAckAt = nil
        lastError = nil
        streamWatchdogSeconds = 3.0
    }

    private func deliver(_ fix: SystemLocationFix) async throws {
        guard let generation else {
            throw failure("location_not_running", "no active location source")
        }
        let proposedDeliverySequence = deliverySequence + 1
        do {
            try await adapter.deliver(
                fix, generation: generation, deliverySequence: proposedDeliverySequence)
        } catch let error as SystemLocationControllerError {
            lastError = error
            throw error
        } catch {
            let wrapped = failure("location_delivery_rejected", error.localizedDescription)
            lastError = wrapped
            throw wrapped
        }
        deliverySequence = proposedDeliverySequence
        lastAppliedFix = fix
        lastAckAt = Date()
        lastError = nil
        state = .running
    }

    private func startHeartbeat(seconds: Double) {
        heartbeatTask?.cancel()
        guard let activeGeneration = generation else { return }
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self,
                      self.generation == activeGeneration,
                      let fix = self.lastProducerFix else { return }
                try? await self.deliver(fix)
            }
        }
    }

    private func scheduleWatchdog(seconds: Double) {
        watchdogTask?.cancel()
        guard let activeGeneration = generation else { return }
        watchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self,
                  self.generation == activeGeneration,
                  let fix = self.lastProducerFix else { return }
            try? await self.deliver(fix.holdingPosition())
        }
    }

    private func startHoldingHeartbeat(seconds: Double) {
        heartbeatTask?.cancel()
        guard let activeGeneration = generation else { return }
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self,
                      self.generation == activeGeneration,
                      let fix = self.lastProducerFix else { return }
                try? await self.deliver(fix.holdingPosition())
                if self.generation == activeGeneration { self.state = .paused }
            }
        }
    }

    private func resetState() {
        heartbeatTask?.cancel()
        watchdogTask?.cancel()
        heartbeatTask = nil
        watchdogTask = nil
        mode = nil
        owner = nil
        generation = nil
        state = .off
        lastProducerFix = nil
        lastAppliedFix = nil
        lastProducerSequence = nil
        deliverySequence = -1
        lastAckAt = nil
        lastError = nil
    }

    private func requireGeneration(_ requested: String, mode expectedMode: Mode? = nil) throws {
        guard let generation, requested == generation else {
            throw failure("location_generation_conflict", "stale location generation")
        }
        if let expectedMode, mode != expectedMode {
            throw failure("location_not_running", "location source mode is not \(expectedMode.rawValue)")
        }
    }

    private func validateOwner(_ owner: String) throws {
        guard !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw failure("invalid_location_source", "owner is required")
        }
    }

    private func validateFix(_ fix: SystemLocationFix) throws {
        guard fix.producerSequence >= 0 else {
            throw failure("invalid_location_source", "producer_sequence must be non-negative")
        }
        if let error = fix.validationError() {
            throw failure("invalid_location_source", error)
        }
    }

    private func failure(_ code: String, _ message: String) -> SystemLocationControllerError {
        SystemLocationControllerError(code: code, message: message)
    }

    private func fixDictionary(_ fix: SystemLocationFix) -> [String: Any] {
        [
            "latitude": fix.latitude, "longitude": fix.longitude,
            "speed_mps": fix.speed, "course_deg": fix.course,
        ]
    }
}
