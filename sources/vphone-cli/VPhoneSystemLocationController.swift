import Foundation

struct SystemLocationFix: Codable, Equatable, Sendable {
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

    func refreshed(at date: Date, holding: Bool = false) -> SystemLocationFix {
        SystemLocationFix(
            producerSequence: producerSequence,
            latitude: latitude, longitude: longitude, altitude: altitude,
            horizontalAccuracy: horizontalAccuracy, verticalAccuracy: verticalAccuracy,
            speed: holding ? 0 : speed,
            course: course,
            timestamp: date.timeIntervalSince1970)
    }
}

struct SystemLocationControllerError: Error, LocalizedError, Equatable {
    let code: String
    let message: String

    var errorDescription: String? { message }
}

@MainActor
protocol SystemLocationGuestAdapter: AnyObject {
    func activate(generation: String) async throws
    func deliver(
        _ fix: SystemLocationFix,
        generation: String,
        deliverySequence: Int
    ) async throws
    func clear(generation: String?) async throws
}

@MainActor
final class VPhoneControlLocationGuestAdapter: SystemLocationGuestAdapter {
    private weak var control: VPhoneControl?

    init(control: VPhoneControl) {
        self.control = control
    }

    func activate(generation: String) async throws {
        let response = try await request([
            "t": "location_source_begin",
            "generation": generation,
        ])
        try Self.requireOK(response, fallback: "guest rejected location source")
    }

    func deliver(
        _ fix: SystemLocationFix,
        generation: String,
        deliverySequence: Int
    ) async throws {
        let response = try await request([
            "t": "location",
            "generation": generation,
            "delivery_sequence": deliverySequence,
            "lat": fix.latitude, "lon": fix.longitude, "alt": fix.altitude,
            "hacc": fix.horizontalAccuracy, "vacc": fix.verticalAccuracy,
            "speed": fix.speed, "course": fix.course, "ts": fix.timestamp,
        ])
        try Self.requireOK(response, fallback: "guest rejected location")
    }

    func clear(generation: String?) async throws {
        var payload: [String: Any] = ["t": "location_stop"]
        if let generation { payload["generation"] = generation }
        let response = try await request(payload)
        try Self.requireOK(response, fallback: "guest rejected location_stop")
    }

    private func request(_ payload: [String: Any]) async throws -> [String: Any] {
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
            (response, _) = try await control.sendRequest(payload)
        } catch let error as VPhoneControl.ControlError {
            throw Self.map(error)
        }
        return response
    }

    private static func requireOK(
        _ response: [String: Any],
        fallback: String
    ) throws {
        guard (response["t"] as? String) == "ok" else {
            throw SystemLocationControllerError(
                code: response["code"] as? String ?? "location_delivery_rejected",
                message: response["msg"] as? String ?? fallback)
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

private struct PersistedSystemLocationState: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let owner: String
    let fix: SystemLocationFix
    let heartbeatSeconds: Double

    init(owner: String, fix: SystemLocationFix, heartbeatSeconds: Double) {
        schemaVersion = Self.currentSchemaVersion
        self.owner = owner
        self.fix = fix
        self.heartbeatSeconds = heartbeatSeconds
    }
}

final class SystemLocationStateStore {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    fileprivate func load() throws -> PersistedSystemLocationState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let state = try JSONDecoder().decode(
            PersistedSystemLocationState.self,
            from: Data(contentsOf: url))
        guard state.schemaVersion == PersistedSystemLocationState.currentSchemaVersion else {
            throw SystemLocationControllerError(
                code: "location_persistence_version",
                message: "unsupported system location state schema")
        }
        return state
    }

    fileprivate func save(_ state: PersistedSystemLocationState) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: url, options: .atomic)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    fileprivate func quarantine() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let suffix = UUID().uuidString.lowercased()
        let destination = url.appendingPathExtension("corrupt-\(suffix)")
        try? FileManager.default.moveItem(at: url, to: destination)
    }
}

/// Device-scoped owner of external fixed and stream location sources.
///
/// Producer sequence advances only after a guest ACK. Delivery sequence is
/// independent and covers heartbeat, watchdog and reconnect re-delivery.
@MainActor
final class VPhoneSystemLocationController {
    private enum Mode: String { case fixed, stream }
    private enum State: String { case off, applying, running, holding, paused }
    private enum TimeoutAction: String { case hold, stop }

    private let adapter: SystemLocationGuestAdapter
    private let stateStore: SystemLocationStateStore?
    private let now: () -> Date
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
    private var fixedHeartbeatSeconds = 1.0
    private var persistent = false
    private var streamWatchdogSeconds = 3.0
    private var streamTimeoutAction: TimeoutAction = .hold
    private var heartbeatTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    init(
        adapter: SystemLocationGuestAdapter,
        stateStore: SystemLocationStateStore? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.adapter = adapter
        self.stateStore = stateStore
        self.now = now
        restorePersistedFixedSource()
    }

    var hasActiveSource: Bool { generation != nil }

    func setFixed(
        owner: String,
        fix: SystemLocationFix,
        heartbeatSeconds: Double,
        replace: Bool = false,
        persist: Bool = false
    ) async throws -> [String: Any] {
        try validateOwner(owner)
        try validateFix(fix)
        guard fix.producerSequence == 0 else {
            throw failure(
                "location_sequence_conflict",
                "fixed source producer_sequence must be 0")
        }
        guard heartbeatSeconds.isFinite, heartbeatSeconds > 0 else {
            throw failure("invalid_location_source", "heartbeat_s must be > 0")
        }
        if persist && stateStore == nil {
            throw failure(
                "location_persistence_unavailable",
                "fixed location persistence is not configured")
        }
        try clearPersistedState()
        try replaceSource(mode: .fixed, owner: owner, allowReplace: replace)
        lastProducerFix = fix
        lastProducerSequence = fix.producerSequence
        fixedHeartbeatSeconds = heartbeatSeconds
        try await activateGuest()
        try await deliver(fix.refreshed(at: now()))
        if persist {
            do {
                try stateStore?.save(PersistedSystemLocationState(
                    owner: owner,
                    fix: fix,
                    heartbeatSeconds: heartbeatSeconds))
                persistent = stateStore != nil
            } catch {
                let activeGeneration = generation
                if let activeGeneration {
                    try? await adapter.clear(generation: activeGeneration)
                }
                resetState()
                throw failure(
                    "location_persistence_failed",
                    "failed to persist fixed location: \(error.localizedDescription)")
            }
        }
        startHeartbeat(seconds: heartbeatSeconds)
        return snapshot()
    }

    func startStream(
        owner: String,
        watchdogSeconds: Double,
        onTimeout: String = TimeoutAction.hold.rawValue,
        replace: Bool = false
    ) async throws -> [String: Any] {
        try validateOwner(owner)
        guard watchdogSeconds.isFinite, watchdogSeconds > 0 else {
            throw failure("invalid_location_source", "watchdog_s must be > 0")
        }
        guard let timeoutAction = TimeoutAction(rawValue: onTimeout) else {
            throw failure("invalid_location_source", "on_timeout must be hold or stop")
        }
        try clearPersistedState()
        try replaceSource(mode: .stream, owner: owner, allowReplace: replace)
        streamWatchdogSeconds = watchdogSeconds
        streamTimeoutAction = timeoutAction
        try await activateGuest()
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
        try await deliver(fix.refreshed(at: now(), holding: paused))
        state = paused ? .paused : .running
        if mode == .stream {
            if paused {
                startHoldingHeartbeat(
                    seconds: min(1.0, streamWatchdogSeconds),
                    resultingState: .paused)
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
        do {
            try clearPersistedState()
        } catch {
            throw failure(
                "location_persistence_failed",
                "failed to clear fixed location state: \(error.localizedDescription)")
        }
        resetState()
        return snapshot()
    }

    func clearLegacyLocation() async throws -> [String: Any] {
        try await adapter.clear(generation: generation)
        try clearPersistedState()
        resetState()
        return snapshot()
    }

    func reapplyAfterReconnect() async {
        guard let generation else { return }
        let wasPaused = state == .paused
        let wasHolding = state == .holding
        do {
            try await adapter.activate(generation: generation)
            if let fix = lastAppliedFix ?? lastProducerFix {
                try await deliver(fix.refreshed(
                    at: now(),
                    holding: wasPaused || wasHolding))
            }
            if wasPaused { state = .paused }
            if wasHolding { state = .holding }
            if mode == .fixed {
                startHeartbeat(seconds: fixedHeartbeatSeconds)
            } else if mode == .stream {
                if wasPaused || wasHolding {
                    startHoldingHeartbeat(
                        seconds: min(1.0, streamWatchdogSeconds),
                        resultingState: wasPaused ? .paused : .holding)
                } else {
                    scheduleWatchdog(seconds: streamWatchdogSeconds)
                }
            }
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
        do {
            try clearPersistedState()
        } catch {
            print("[location] failed to clear persisted fixed source: \(error)")
            stateStore?.quarantine()
        }
        resetState()
    }

    func snapshot() -> [String: Any] {
        var desired: [String: Any] = [:]
        if let mode { desired["mode"] = mode.rawValue }
        if let owner { desired["owner"] = owner }
        if let generation { desired["generation"] = generation }
        desired["paused"] = state == .paused
        desired["persistent"] = persistent
        if mode == .stream { desired["on_timeout"] = streamTimeoutAction.rawValue }

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
        fixedHeartbeatSeconds = 1.0
        persistent = false
        streamWatchdogSeconds = 3.0
        streamTimeoutAction = .hold
    }

    private func activateGuest() async throws {
        guard let generation else {
            throw failure("location_not_running", "no active location source")
        }
        do {
            try await adapter.activate(generation: generation)
        } catch let error as SystemLocationControllerError {
            lastError = error
            throw error
        } catch {
            let wrapped = failure("location_guest_unavailable", error.localizedDescription)
            lastError = wrapped
            throw wrapped
        }
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
        lastAckAt = now()
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
                let desiredState = self.state
                try? await self.deliver(fix.refreshed(
                    at: self.now(),
                    holding: desiredState == .paused || desiredState == .holding))
                if self.generation == activeGeneration,
                   desiredState == .paused || desiredState == .holding {
                    self.state = desiredState
                }
            }
        }
    }

    private func scheduleWatchdog(seconds: Double) {
        watchdogTask?.cancel()
        guard let activeGeneration = generation else { return }
        watchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self,
                  self.generation == activeGeneration else { return }
            switch self.streamTimeoutAction {
            case .hold:
                guard let fix = self.lastProducerFix else { return }
                do {
                    try await self.deliver(fix.refreshed(at: self.now(), holding: true))
                    self.state = .holding
                    self.startHoldingHeartbeat(
                        seconds: min(1.0, seconds),
                        resultingState: .holding)
                } catch {
                    self.state = .applying
                    self.startHoldingHeartbeat(
                        seconds: min(1.0, seconds),
                        resultingState: .holding)
                }
            case .stop:
                do {
                    try await self.adapter.clear(generation: activeGeneration)
                    self.resetState()
                } catch let error as SystemLocationControllerError {
                    self.lastError = error
                    self.state = .applying
                    self.scheduleWatchdog(seconds: seconds)
                } catch {
                    self.lastError = self.failure(
                        "location_delivery_rejected", error.localizedDescription)
                    self.state = .applying
                    self.scheduleWatchdog(seconds: seconds)
                }
            }
        }
    }

    private func startHoldingHeartbeat(seconds: Double, resultingState: State) {
        heartbeatTask?.cancel()
        guard let activeGeneration = generation else { return }
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self,
                      self.generation == activeGeneration,
                      let fix = self.lastProducerFix else { return }
                do {
                    try await self.deliver(fix.refreshed(at: self.now(), holding: true))
                    if self.generation == activeGeneration { self.state = resultingState }
                } catch {
                    self.state = .applying
                }
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
        fixedHeartbeatSeconds = 1.0
        persistent = false
        streamWatchdogSeconds = 3.0
        streamTimeoutAction = .hold
    }

    private func restorePersistedFixedSource() {
        guard let stateStore else { return }
        do {
            guard let saved = try stateStore.load() else { return }
            try validateOwner(saved.owner)
            try validateFix(saved.fix)
            guard saved.fix.producerSequence == 0 else {
                throw failure(
                    "location_persistence_corrupt",
                    "persisted fixed source producer_sequence must be 0")
            }
            guard saved.heartbeatSeconds.isFinite, saved.heartbeatSeconds > 0 else {
                throw failure(
                    "location_persistence_corrupt",
                    "persisted heartbeat_s must be > 0")
            }
            mode = .fixed
            state = .applying
            owner = saved.owner
            generation = "loc-" + UUID().uuidString.lowercased()
            lastProducerFix = saved.fix
            lastProducerSequence = saved.fix.producerSequence
            fixedHeartbeatSeconds = saved.heartbeatSeconds
            persistent = true
        } catch let error as SystemLocationControllerError {
            lastError = error
            stateStore.quarantine()
        } catch {
            lastError = failure(
                "location_persistence_corrupt",
                "failed to restore fixed location: \(error.localizedDescription)")
            stateStore.quarantine()
        }
    }

    private func clearPersistedState() throws {
        try stateStore?.clear()
        persistent = false
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
        guard fix.timestamp.isFinite, fix.timestamp > 0 else {
            throw failure("invalid_location_source", "timestamp must be > 0")
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
