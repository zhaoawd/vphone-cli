import Foundation

public enum VPhoneSystemLocationValidation {
    public static func error(
        latitude: Double,
        longitude: Double,
        altitude: Double,
        horizontalAccuracy: Double,
        verticalAccuracy: Double,
        speed: Double,
        course: Double
    ) -> String? {
        for (name, value) in [
            ("lat", latitude), ("lon", longitude), ("alt", altitude),
            ("hacc", horizontalAccuracy), ("vacc", verticalAccuracy),
            ("speed", speed), ("course", course),
        ] where !value.isFinite {
            return "\(name) must be a finite number"
        }
        if latitude < -90 || latitude > 90 {
            return "lat out of range [-90, 90]: \(latitude)"
        }
        if longitude < -180 || longitude > 180 {
            return "lon out of range [-180, 180]: \(longitude)"
        }
        if horizontalAccuracy <= 0 {
            return "hacc must be > 0: \(horizontalAccuracy)"
        }
        if verticalAccuracy <= 0 {
            return "vacc must be > 0: \(verticalAccuracy)"
        }
        if speed != -1 && speed < 0 {
            return "speed must be -1 or >= 0: \(speed)"
        }
        if course != -1 && (course < 0 || course >= 360) {
            return "course must be -1 or in [0, 360): \(course)"
        }
        return nil
    }
}

public struct VPhoneSystemLocationFix: Codable, Equatable, Sendable {
    public let producerSequence: Int
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double
    public let horizontalAccuracy: Double
    public let verticalAccuracy: Double
    public let speed: Double
    public let course: Double
    public let timestamp: TimeInterval

    public init(
        producerSequence: Int,
        latitude: Double,
        longitude: Double,
        altitude: Double,
        horizontalAccuracy: Double,
        verticalAccuracy: Double,
        speed: Double,
        course: Double,
        timestamp: TimeInterval
    ) {
        self.producerSequence = producerSequence
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.course = course
        self.timestamp = timestamp
    }

    func validationError() -> String? {
        VPhoneSystemLocationValidation.error(
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: verticalAccuracy,
            speed: speed,
            course: course)
    }

    func refreshed(at date: Date, holding: Bool = false) -> VPhoneSystemLocationFix {
        VPhoneSystemLocationFix(
            producerSequence: producerSequence,
            latitude: latitude, longitude: longitude, altitude: altitude,
            horizontalAccuracy: horizontalAccuracy, verticalAccuracy: verticalAccuracy,
            speed: holding ? 0 : speed,
            course: course,
            timestamp: date.timeIntervalSince1970)
    }
}

public struct VPhoneSystemLocationError: Error, LocalizedError, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
}

@MainActor
public protocol VPhoneSystemLocationGuestAdapter: AnyObject {
    func activate(generation: String) async throws
    func deliver(
        _ fix: VPhoneSystemLocationFix,
        generation: String,
        deliverySequence: Int
    ) async throws
    func clear(generation: String?) async throws
}

private struct PersistedSystemLocationState: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let owner: String
    let fix: VPhoneSystemLocationFix
    let heartbeatSeconds: Double

    init(owner: String, fix: VPhoneSystemLocationFix, heartbeatSeconds: Double) {
        schemaVersion = Self.currentSchemaVersion
        self.owner = owner
        self.fix = fix
        self.heartbeatSeconds = heartbeatSeconds
    }
}

public final class VPhoneSystemLocationStateStore {
    let url: URL

    public init(url: URL) {
        self.url = url
    }

    fileprivate func load() throws -> PersistedSystemLocationState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let state = try JSONDecoder().decode(
            PersistedSystemLocationState.self,
            from: Data(contentsOf: url))
        guard state.schemaVersion == PersistedSystemLocationState.currentSchemaVersion else {
            throw VPhoneSystemLocationError(
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
public final class VPhoneSystemLocationController {
    private enum Mode: String { case fixed, stream }
    private enum State: String { case off, applying, running, holding, paused }
    private enum TimeoutAction: String { case hold, stop }

    private let adapter: VPhoneSystemLocationGuestAdapter
    private let stateStore: VPhoneSystemLocationStateStore?
    private let now: () -> Date
    private var mode: Mode?
    private var state: State = .off
    private var owner: String?
    public private(set) var generation: String?
    private var lastProducerFix: VPhoneSystemLocationFix?
    private var lastAppliedFix: VPhoneSystemLocationFix?
    private var lastProducerSequence: Int?
    private var deliverySequence = -1
    private var lastAckAt: Date?
    private var lastError: VPhoneSystemLocationError?
    private var fixedHeartbeatSeconds = 1.0
    private var persistent = false
    private var streamWatchdogSeconds = 3.0
    private var streamTimeoutAction: TimeoutAction = .hold
    private var heartbeatTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?

    public init(
        adapter: VPhoneSystemLocationGuestAdapter,
        stateStore: VPhoneSystemLocationStateStore? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.adapter = adapter
        self.stateStore = stateStore
        self.now = now
        restorePersistedFixedSource()
    }

    public var hasActiveSource: Bool { generation != nil }

    public func setFixed(
        owner: String,
        fix: VPhoneSystemLocationFix,
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

    public func startStream(
        owner: String,
        watchdogSeconds: Double,
        onTimeout: String = "hold",
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

    public func push(
        generation requestedGeneration: String,
        fix: VPhoneSystemLocationFix
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

    public func setPaused(
        _ paused: Bool,
        generation requestedGeneration: String
    ) async throws -> [String: Any] {
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

    public func stop(
        generation requestedGeneration: String? = nil
    ) async throws -> [String: Any] {
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

    public func clearLegacyLocation() async throws -> [String: Any] {
        try await adapter.clear(generation: generation)
        try clearPersistedState()
        resetState()
        return snapshot()
    }

    public func reapplyAfterReconnect() async {
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
        } catch let error as VPhoneSystemLocationError {
            lastError = error
            state = .applying
        } catch {
            lastError = failure("location_guest_unavailable", error.localizedDescription)
            state = .applying
        }
    }

    /// A GUI source becomes authoritative without clearing the fix it is about
    /// to replace. Pending external heartbeat/watchdog work is cancelled.
    public func relinquishForGUI() {
        do {
            try clearPersistedState()
        } catch {
            print("[location] failed to clear persisted fixed source: \(error)")
            stateStore?.quarantine()
        }
        resetState()
    }

    public func snapshot() -> [String: Any] {
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
        } catch let error as VPhoneSystemLocationError {
            lastError = error
            throw error
        } catch {
            let wrapped = failure("location_guest_unavailable", error.localizedDescription)
            lastError = wrapped
            throw wrapped
        }
    }

    private func deliver(_ fix: VPhoneSystemLocationFix) async throws {
        guard let generation else {
            throw failure("location_not_running", "no active location source")
        }
        let proposedDeliverySequence = deliverySequence + 1
        do {
            try await adapter.deliver(
                fix, generation: generation, deliverySequence: proposedDeliverySequence)
        } catch let error as VPhoneSystemLocationError {
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
                } catch let error as VPhoneSystemLocationError {
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
        } catch let error as VPhoneSystemLocationError {
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

    private func validateFix(_ fix: VPhoneSystemLocationFix) throws {
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

    private func failure(_ code: String, _ message: String) -> VPhoneSystemLocationError {
        VPhoneSystemLocationError(code: code, message: message)
    }

    private func fixDictionary(_ fix: VPhoneSystemLocationFix) -> [String: Any] {
        [
            "latitude": fix.latitude, "longitude": fix.longitude,
            "speed_mps": fix.speed, "course_deg": fix.course,
        ]
    }
}
