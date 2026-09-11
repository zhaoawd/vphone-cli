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
            latitude: latitude, longitude: longitude, altitude: altitude,
            horizontalAccuracy: horizontalAccuracy, verticalAccuracy: verticalAccuracy,
            speed: speed, course: course)
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

    func withHoldingSpeed(_ holding: Bool) -> VPhoneSystemLocationFix {
        VPhoneSystemLocationFix(
            producerSequence: producerSequence,
            latitude: latitude, longitude: longitude, altitude: altitude,
            horizontalAccuracy: horizontalAccuracy, verticalAccuracy: verticalAccuracy,
            speed: holding ? 0 : speed,
            course: course,
            timestamp: timestamp)
    }

    func hasSameDeliverySemantics(as other: VPhoneSystemLocationFix) -> Bool {
        producerSequence == other.producerSequence
            && latitude == other.latitude
            && longitude == other.longitude
            && altitude == other.altitude
            && horizontalAccuracy == other.horizontalAccuracy
            && verticalAccuracy == other.verticalAccuracy
            && speed == other.speed
            && course == other.course
    }
}

public struct VPhoneSystemLocationError: Error, LocalizedError, Equatable {
    public let code: String
    public let message: String
    public let definitiveGuestRejection: Bool

    public init(
        code: String,
        message: String,
        definitiveGuestRejection: Bool = false
    ) {
        self.code = code
        self.message = message
        self.definitiveGuestRejection = definitiveGuestRejection
    }

    public var errorDescription: String? { message }
}

@MainActor
public protocol VPhoneSystemLocationGuestAdapter: AnyObject {
    func requireOwnedLocationCapability() throws
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
    struct StagedClear {
        let containedState: Bool
    }

    let url: URL
    private let beforeStageClear: (() throws -> Void)?
    private let beforeCommitClear: (() throws -> Void)?
    private let beforeRollbackClear: (() throws -> Void)?
    private let beforeClear: (() throws -> Void)?
    private let beforeQuarantine: (() throws -> Void)?

    private var pendingDeleteURL: URL {
        url.appendingPathExtension("pending-delete")
    }

    public convenience init(url: URL) {
        self.init(url: url, beforeStageClear: nil)
    }

    init(
        url: URL,
        beforeStageClear: (() throws -> Void)? = nil,
        beforeCommitClear: (() throws -> Void)? = nil,
        beforeRollbackClear: (() throws -> Void)? = nil,
        beforeClear: (() throws -> Void)? = nil,
        beforeQuarantine: (() throws -> Void)? = nil
    ) {
        self.url = url
        self.beforeStageClear = beforeStageClear
        self.beforeCommitClear = beforeCommitClear
        self.beforeRollbackClear = beforeRollbackClear
        self.beforeClear = beforeClear
        self.beforeQuarantine = beforeQuarantine
    }

    fileprivate func load() throws -> PersistedSystemLocationState? {
        try recoverInterruptedClear()
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
        try? removeIfPresent(pendingDeleteURL)
    }

    func clear() throws {
        try beforeClear?()
        try removeIfPresent(pendingDeleteURL)
        try removeIfPresent(url)
    }

    func stageClear() throws -> StagedClear {
        try beforeStageClear?()
        let manager = FileManager.default
        let canonicalExists = manager.fileExists(atPath: url.path)
        let pendingExists = manager.fileExists(atPath: pendingDeleteURL.path)
        if canonicalExists {
            if pendingExists {
                try manager.removeItem(at: pendingDeleteURL)
            }
            try manager.moveItem(at: url, to: pendingDeleteURL)
            return StagedClear(containedState: true)
        }
        return StagedClear(containedState: pendingExists)
    }

    func commitClear(_ staged: StagedClear) throws {
        try beforeCommitClear?()
        if staged.containedState {
            try removeIfPresent(pendingDeleteURL)
        }
    }

    func rollbackClear(_ staged: StagedClear) throws {
        guard staged.containedState else { return }
        try beforeRollbackClear?()
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            try removeIfPresent(pendingDeleteURL)
            return
        }
        guard manager.fileExists(atPath: pendingDeleteURL.path) else {
            throw VPhoneSystemLocationError(
                code: "location_persistence_failed",
                message: "staged system location state is missing")
        }
        try manager.moveItem(at: pendingDeleteURL, to: url)
    }

    fileprivate func quarantine() throws {
        try beforeQuarantine?()
        let suffix = UUID().uuidString.lowercased()
        for source in [url, pendingDeleteURL] {
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destination = source.appendingPathExtension("corrupt-\(suffix)")
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    private func recoverInterruptedClear() throws {
        let manager = FileManager.default
        let canonicalExists = manager.fileExists(atPath: url.path)
        let pendingExists = manager.fileExists(atPath: pendingDeleteURL.path)
        guard pendingExists else { return }
        if canonicalExists {
            try? manager.removeItem(at: pendingDeleteURL)
        } else {
            try manager.moveItem(at: pendingDeleteURL, to: url)
        }
    }

    private func removeIfPresent(_ target: URL) throws {
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.removeItem(at: target)
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

    private struct PendingDelivery: Equatable {
        let generation: String
        let sequence: Int
        let fix: VPhoneSystemLocationFix
    }

    private struct PendingProducer: Equatable {
        let generation: String
        let fix: VPhoneSystemLocationFix
        let deliveryFix: VPhoneSystemLocationFix
    }

    private struct ControlToken: Equatable {
        let generation: String
        let revision: UInt64
    }

    private enum DeliveryTurnGrant: Sendable {
        case acquired
        case cancelled
    }

    private struct DeliveryTurnWaiter {
        let id: UUID
        let continuation: CheckedContinuation<DeliveryTurnGrant, Never>
    }

    private static let minimumTimerSeconds = 0.01
    private static let maximumTimerSeconds = 86_400.0

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
    private var desiredPaused = false
    private var watchdogHolding = false
    private var heartbeatTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var reapplyRetryTask: Task<Void, Never>?
    private var pendingDelivery: PendingDelivery?
    private var pendingProducer: PendingProducer?
    private var guestActivationRequired = false
    private var controlRevision: UInt64 = 0
    private var deliveryTurnOwned = false
    private var deliveryTurnWaiters: [DeliveryTurnWaiter] = []

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
    var deliveryTurnWaiterCount: Int { deliveryTurnWaiters.count }
    var hasScheduledHeartbeat: Bool { heartbeatTask != nil }

    public func preflightFixedSource(
        owner: String,
        fix: VPhoneSystemLocationFix,
        heartbeatSeconds: Double,
        replace: Bool,
        persist: Bool
    ) throws {
        try validateOwner(owner)
        try validateFix(fix)
        guard fix.producerSequence == 0 else {
            throw failure(
                "location_sequence_conflict",
                "fixed source producer_sequence must be 0")
        }
        try validateTimerSeconds(heartbeatSeconds, field: "heartbeat_s")
        if persist && stateStore == nil {
            throw failure(
                "location_persistence_unavailable",
                "fixed location persistence is not configured")
        }
        try requireReplacementAllowed(owner: owner, allowReplace: replace)
        try adapter.requireOwnedLocationCapability()
    }

    public func preflightStreamSource(
        owner: String,
        watchdogSeconds: Double,
        onTimeout: String,
        replace: Bool
    ) throws {
        try validateOwner(owner)
        try validateTimerSeconds(watchdogSeconds, field: "watchdog_s")
        guard TimeoutAction(rawValue: onTimeout) != nil else {
            throw failure("invalid_location_source", "on_timeout must be hold or stop")
        }
        try requireReplacementAllowed(owner: owner, allowReplace: replace)
        try adapter.requireOwnedLocationCapability()
    }

    public func setFixed(
        owner: String,
        fix: VPhoneSystemLocationFix,
        heartbeatSeconds: Double,
        replace: Bool = false,
        persist: Bool = false,
        precommit: (@MainActor () throws -> Void)? = nil
    ) async throws -> [String: Any] {
        try preflightFixedSource(
            owner: owner,
            fix: fix,
            heartbeatSeconds: heartbeatSeconds,
            replace: replace,
            persist: persist)
        try await acquireDeliveryTurn()
        defer { releaseDeliveryTurn() }
        try Task.checkCancellation()
        try precommit?()
        try requireReplacementAllowed(owner: owner, allowReplace: replace)
        try adapter.requireOwnedLocationCapability()
        try commitPersistence(persist ? PersistedSystemLocationState(
            owner: owner,
            fix: fix,
            heartbeatSeconds: heartbeatSeconds) : nil)
        let sourceToken = replaceSource(mode: .fixed, owner: owner)
        lastProducerFix = fix
        lastProducerSequence = fix.producerSequence
        fixedHeartbeatSeconds = heartbeatSeconds
        persistent = persist
        try requireCurrentGeneration(sourceToken.generation)
        try await activateGuest(expectedGeneration: sourceToken.generation)
        try await deliverWhileHoldingTurn(
            fix.refreshed(at: now()),
            expectedGeneration: sourceToken.generation)
        try requireCurrentGeneration(sourceToken.generation)
        startHeartbeat(seconds: heartbeatSeconds)
        return snapshot()
    }

    public func startStream(
        owner: String,
        watchdogSeconds: Double,
        onTimeout: String = "hold",
        replace: Bool = false,
        precommit: (@MainActor () throws -> Void)? = nil
    ) async throws -> [String: Any] {
        try preflightStreamSource(
            owner: owner,
            watchdogSeconds: watchdogSeconds,
            onTimeout: onTimeout,
            replace: replace)
        guard let timeoutAction = TimeoutAction(rawValue: onTimeout) else {
            throw failure("invalid_location_source", "on_timeout must be hold or stop")
        }
        try await acquireDeliveryTurn()
        defer { releaseDeliveryTurn() }
        try Task.checkCancellation()
        try precommit?()
        try requireReplacementAllowed(owner: owner, allowReplace: replace)
        try adapter.requireOwnedLocationCapability()
        try commitPersistence(nil)
        let sourceToken = replaceSource(mode: .stream, owner: owner)
        streamWatchdogSeconds = watchdogSeconds
        streamTimeoutAction = timeoutAction
        try requireCurrentGeneration(sourceToken.generation)
        try await activateGuest(expectedGeneration: sourceToken.generation)
        try requireCurrentGeneration(sourceToken.generation)
        scheduleWatchdog(seconds: watchdogSeconds)
        return snapshot()
    }

    public func push(
        generation requestedGeneration: String,
        fix: VPhoneSystemLocationFix
    ) async throws -> [String: Any] {
        try requireGeneration(requestedGeneration, mode: .stream)
        try validateFix(fix)
        try await acquireDeliveryTurn()
        defer { releaseDeliveryTurn() }
        try Task.checkCancellation()
        try requireGeneration(requestedGeneration, mode: .stream)
        try validateFix(fix)

        if let lastProducerSequence {
            if fix.producerSequence == lastProducerSequence {
                guard fix == lastProducerFix else {
                    throw failure(
                        "location_sequence_conflict",
                        "producer sequence reused with a different payload")
                }
                let needsGuestRepair = guestActivationRequired || pendingDelivery != nil
                if needsGuestRepair {
                    let repairFix: VPhoneSystemLocationFix
                    if let producer = pendingProducer,
                       producer.generation == requestedGeneration {
                        repairFix = producer.deliveryFix
                    } else {
                        let desiredFix = fix.refreshed(
                            at: now(),
                            holding: desiredPaused || watchdogHolding)
                        if let delivery = pendingDelivery,
                           delivery.generation == requestedGeneration,
                           delivery.fix.hasSameDeliverySemantics(as: desiredFix) {
                            repairFix = delivery.fix
                        } else {
                            repairFix = desiredFix
                        }
                    }
                    if guestActivationRequired {
                        try await activateGuest(expectedGeneration: requestedGeneration)
                    }
                    try await deliverWhileHoldingTurn(
                        repairFix,
                        expectedGeneration: requestedGeneration)
                    try requireCurrentGeneration(requestedGeneration)
                    if desiredPaused {
                        state = .paused
                    } else if watchdogHolding {
                        state = .holding
                    } else {
                        state = .running
                    }
                    restoreTimersAfterGuestRepair(restoredFix: true)
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

        let preservePausedState = desiredPaused
        controlRevision &+= 1
        let deliveryFix: VPhoneSystemLocationFix
        let producer: PendingProducer
        if let pendingProducer {
            guard pendingProducer.generation == requestedGeneration,
                  pendingProducer.fix == fix else {
                throw failure(
                    "location_sequence_conflict",
                    "producer sequence is already bound to another payload")
            }
            producer = pendingProducer
            deliveryFix = pendingProducer.deliveryFix
        } else {
            deliveryFix = fix.withHoldingSpeed(preservePausedState)
            producer = PendingProducer(
                generation: requestedGeneration,
                fix: fix,
                deliveryFix: deliveryFix)
            pendingProducer = producer
        }
        do {
            try await deliverWhileHoldingTurn(
                deliveryFix,
                expectedGeneration: requestedGeneration)
        } catch let error as VPhoneSystemLocationError {
            if error.definitiveGuestRejection,
               pendingProducer?.generation == producer.generation,
               pendingProducer?.fix == producer.fix {
                clearPendingProducer()
            }
            throw error
        }
        try requireCurrentGeneration(requestedGeneration)
        lastProducerFix = fix
        lastProducerSequence = fix.producerSequence
        clearPendingProducer()
        watchdogHolding = false
        watchdogTask?.cancel()
        heartbeatTask?.cancel()
        if preservePausedState {
            state = .paused
            startHoldingHeartbeat(seconds: min(1.0, streamWatchdogSeconds))
        } else {
            state = .running
            scheduleWatchdog(seconds: streamWatchdogSeconds)
        }
        return snapshot()
    }

    public func setPaused(_ paused: Bool, generation requestedGeneration: String) async throws -> [String: Any] {
        try requireGeneration(requestedGeneration)
        guard lastProducerFix != nil else {
            throw failure("location_not_running", "no accepted location sample")
        }
        try await acquireDeliveryTurn()
        defer { releaseDeliveryTurn() }
        try Task.checkCancellation()
        try requireGeneration(requestedGeneration)
        guard lastProducerFix != nil else {
            throw failure("location_not_running", "no accepted location sample")
        }
        controlRevision &+= 1
        try await deliverWhileHoldingTurn(
            expectedGeneration: requestedGeneration
        ) { [self] in
            guard let fix = lastProducerFix else {
                throw failure("location_not_running", "no accepted location sample")
            }
            return fix.refreshed(at: now(), holding: paused)
        }
        try requireCurrentGeneration(requestedGeneration)
        desiredPaused = paused
        watchdogHolding = false
        state = paused ? .paused : .running
        if mode == .stream {
            watchdogTask?.cancel()
            heartbeatTask?.cancel()
            if paused {
                startHoldingHeartbeat(seconds: min(1.0, streamWatchdogSeconds))
            } else {
                scheduleWatchdog(seconds: streamWatchdogSeconds)
            }
        }
        return snapshot()
    }

    public func stop(generation requestedGeneration: String? = nil) async throws -> [String: Any] {
        guard let activeGeneration = generation else { return snapshot() }
        if let requestedGeneration, requestedGeneration != activeGeneration {
            throw failure(
                "location_generation_conflict", "generation does not own current source")
        }
        try await acquireDeliveryTurn()
        defer { releaseDeliveryTurn() }
        try Task.checkCancellation()
        try requireCurrentGeneration(activeGeneration)
        try await clearSourceWhileHoldingTurn(expectedGeneration: activeGeneration)
        return snapshot()
    }

    public func clearLegacyLocation(
        consistencyCheck: (@MainActor () throws -> Void)? = nil,
        guestOperation: (@MainActor () async throws -> Void)? = nil,
        guestRollback: (@MainActor (VPhoneSystemLocationFix?) async throws -> Void)? = nil
    ) async throws -> [String: Any] {
        let sourceGeneration = generation
        try await acquireDeliveryTurn()
        defer { releaseDeliveryTurn() }
        try Task.checkCancellation()
        try consistencyCheck?()
        try requireSourceUnchanged(sourceGeneration)
        try await clearSourceWhileHoldingTurn(
            expectedGeneration: sourceGeneration,
            consistencyCheck: consistencyCheck,
            guestOperation: guestOperation,
            guestRollback: guestRollback)
        return snapshot()
    }

    public func reapplyAfterReconnect() async {
        var sourceToken: ControlToken?
        var retryWasPaused = false
        var retryWasHolding = false
        var retryResumedPendingProducer = false
        do {
            try await acquireDeliveryTurn()
            defer { releaseDeliveryTurn() }
            try Task.checkCancellation()
            guard let token = currentControlToken() else { return }
            sourceToken = token
            let wasPaused = desiredPaused
            let wasHolding = watchdogHolding
            retryWasPaused = wasPaused
            retryWasHolding = wasHolding
            try requireCurrentControl(token)
            try await activateGuest(expectedGeneration: token.generation)
            try requireCurrentControl(token)

            let resumedPendingProducer = pendingProducer?.generation == token.generation
            retryResumedPendingProducer = resumedPendingProducer
            if let producer = pendingProducer,
               producer.generation == token.generation {
                let deliveryFix = producer.fix.withHoldingSpeed(wasPaused)
                pendingProducer = PendingProducer(
                    generation: producer.generation,
                    fix: producer.fix,
                    deliveryFix: deliveryFix)
                do {
                    try await deliverWhileHoldingTurn(
                        deliveryFix,
                        expectedGeneration: token.generation)
                } catch let error as VPhoneSystemLocationError {
                    if error.definitiveGuestRejection,
                       pendingProducer?.generation == producer.generation,
                       pendingProducer?.fix == producer.fix {
                        clearPendingProducer()
                    }
                    throw error
                }
            } else if let fix = lastAppliedFix ?? lastProducerFix {
                try await deliverWhileHoldingTurn(
                    expectedGeneration: token.generation
                ) { [self] in
                    (lastAppliedFix ?? lastProducerFix ?? fix).refreshed(
                        at: now(),
                        holding: wasPaused || wasHolding)
                }
            }
            try requireCurrentControl(token)
            if wasPaused { state = .paused }
            if watchdogHolding && !resumedPendingProducer { state = .holding }
            if mode == .fixed {
                startHeartbeat(seconds: fixedHeartbeatSeconds)
            } else if mode == .stream {
                watchdogTask?.cancel()
                heartbeatTask?.cancel()
                if wasPaused || (wasHolding && !resumedPendingProducer) {
                    startHoldingHeartbeat(seconds: min(1.0, streamWatchdogSeconds))
                } else {
                    scheduleWatchdog(seconds: streamWatchdogSeconds)
                }
            }
        } catch let error as VPhoneSystemLocationError {
            guard let sourceToken, isCurrentControl(sourceToken) else { return }
            lastError = error
            state = .applying
            guestActivationRequired = true
            restoreTimersAfterFailedReapply(
                wasPaused: retryWasPaused,
                wasHolding: retryWasHolding,
                resumedPendingProducer: retryResumedPendingProducer)
        } catch is CancellationError {
            return
        } catch {
            guard let sourceToken, isCurrentControl(sourceToken) else { return }
            lastError = failure("location_guest_unavailable", error.localizedDescription)
            state = .applying
            guestActivationRequired = true
            restoreTimersAfterFailedReapply(
                wasPaused: retryWasPaused,
                wasHolding: retryWasHolding,
                resumedPendingProducer: retryResumedPendingProducer)
        }
    }

    /// A GUI source becomes authoritative without clearing the fix it is about
    /// to replace. Pending external heartbeat/watchdog work is cancelled.
    @discardableResult
    public func relinquishForGUI() -> Bool {
        do {
            try clearPersistedState()
        } catch {
            print("[location] failed to clear persisted fixed source: \(error)")
            do {
                try stateStore?.quarantine()
            } catch {
                lastError = failure(
                    "location_persistence_failed",
                    "failed to remove persisted fixed source: \(error.localizedDescription)")
                print("[location] failed to quarantine persisted fixed source: \(error)")
                return false
            }
        }
        resetState()
        return true
    }

    public func snapshot() -> [String: Any] {
        var desired: [String: Any] = [:]
        if let mode { desired["mode"] = mode.rawValue }
        if let owner { desired["owner"] = owner }
        if let generation { desired["generation"] = generation }
        desired["paused"] = desiredPaused
        desired["persistent"] = persistent
        if mode == .fixed {
            desired["heartbeat_s"] = fixedHeartbeatSeconds
        } else if mode == .stream {
            desired["watchdog_s"] = streamWatchdogSeconds
            desired["on_timeout"] = streamTimeoutAction.rawValue
        }

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

    private func requireReplacementAllowed(owner: String, allowReplace: Bool) throws {
        if let activeOwner = self.owner, activeOwner != owner, !allowReplace {
            throw failure(
                "location_owner_conflict",
                "location source is owned by \(activeOwner)")
        }
    }

    private func commitPersistence(_ candidate: PersistedSystemLocationState?) throws {
        do {
            if let candidate {
                try stateStore?.save(candidate)
            } else {
                try clearPersistedState()
            }
        } catch {
            throw failure(
                "location_persistence_failed",
                "failed to update fixed location state: \(error.localizedDescription)")
        }
    }

    private func clearSourceWhileHoldingTurn(
        expectedGeneration: String?,
        consistencyCheck: (@MainActor () throws -> Void)? = nil,
        guestOperation: (@MainActor () async throws -> Void)? = nil,
        guestRollback: (@MainActor (VPhoneSystemLocationFix?) async throws -> Void)? = nil
    ) async throws {
        let originalState = state
        let rollbackFix = (lastProducerFix ?? lastAppliedFix)?.refreshed(
            at: now(),
            holding: desiredPaused || watchdogHolding)
        let stagedClear: VPhoneSystemLocationStateStore.StagedClear?
        do {
            stagedClear = try stateStore?.stageClear()
        } catch {
            throw failure(
                "location_persistence_failed",
                "failed to stage fixed location removal: \(error.localizedDescription)")
        }

        controlRevision &+= 1
        do {
            if let guestOperation {
                try await guestOperation()
            } else {
                try await adapter.clear(generation: expectedGeneration)
            }
            try consistencyCheck?()
        } catch {
            do {
                try requireSourceUnchanged(expectedGeneration)
            } catch {
                if let stagedClear {
                    try? stateStore?.commitClear(stagedClear)
                }
                throw error
            }
            do {
                if let stagedClear {
                    try stateStore?.rollbackClear(stagedClear)
                }
            } catch {
                let persistenceError = failure(
                    "location_persistence_failed",
                    "failed to restore fixed location state: \(error.localizedDescription)")
                guestActivationRequired = expectedGeneration != nil
                await repairGuestAfterFailedClear(
                    expectedGeneration: expectedGeneration,
                    originalState: originalState,
                    guestRollback: guestRollback,
                    rollbackFix: rollbackFix)
                lastError = persistenceError
                state = .applying
                throw persistenceError
            }
            if guestRollback != nil || shouldRepairGuestAfterClearFailure(error) {
                await repairGuestAfterFailedClear(
                    expectedGeneration: expectedGeneration,
                    originalState: originalState,
                    guestRollback: guestRollback,
                    rollbackFix: rollbackFix)
            }
            throw error
        }

        do {
            try requireSourceUnchanged(expectedGeneration)
        } catch {
            if let stagedClear {
                try? stateStore?.commitClear(stagedClear)
            }
            throw error
        }

        do {
            if let stagedClear {
                try stateStore?.commitClear(stagedClear)
            }
        } catch {
            let persistenceError = failure(
                "location_persistence_failed",
                "failed to commit fixed location removal: \(error.localizedDescription)")
            do {
                if let stagedClear {
                    try stateStore?.rollbackClear(stagedClear)
                }
            } catch {
                let rollbackError = failure(
                    "location_persistence_failed",
                    "failed to restore fixed location state: \(error.localizedDescription)")
                guestActivationRequired = expectedGeneration != nil
                await repairGuestAfterFailedClear(
                    expectedGeneration: expectedGeneration,
                    originalState: originalState,
                    guestRollback: guestRollback,
                    rollbackFix: rollbackFix)
                lastError = rollbackError
                state = .applying
                throw rollbackError
            }
            await repairGuestAfterFailedClear(
                expectedGeneration: expectedGeneration,
                originalState: originalState,
                guestRollback: guestRollback,
                rollbackFix: rollbackFix)
            lastError = persistenceError
            throw persistenceError
        }

        resetState()
    }

    private func shouldRepairGuestAfterClearFailure(_ error: Error) -> Bool {
        guard let controllerError = error as? VPhoneSystemLocationError else {
            return true
        }
        return !controllerError.definitiveGuestRejection
            || controllerError.code == "location_generation_conflict"
            || controllerError.code == "location_guest_unavailable"
    }

    private func repairGuestAfterFailedClear(
        expectedGeneration: String?,
        originalState: State,
        guestRollback: (@MainActor (VPhoneSystemLocationFix?) async throws -> Void)? = nil,
        rollbackFix: VPhoneSystemLocationFix? = nil
    ) async {
        if let guestRollback {
            heartbeatTask?.cancel()
            watchdogTask?.cancel()
            reapplyRetryTask?.cancel()
            heartbeatTask = nil
            watchdogTask = nil
            reapplyRetryTask = nil
            guestActivationRequired = expectedGeneration != nil
            do {
                try await guestRollback(rollbackFix)
                try requireSourceUnchanged(expectedGeneration)
                state = expectedGeneration == nil ? .off : .applying
            } catch let error as VPhoneSystemLocationError {
                guard generation == expectedGeneration else { return }
                lastError = error
                state = expectedGeneration == nil ? .off : .applying
            } catch {
                guard generation == expectedGeneration else { return }
                lastError = failure(
                    "location_guest_unavailable", error.localizedDescription)
                state = expectedGeneration == nil ? .off : .applying
            }
            return
        }
        guard let expectedGeneration, generation == expectedGeneration else { return }
        let resumedPendingProducer = pendingProducer?.generation == expectedGeneration
        let shouldHoldExistingFix = desiredPaused || watchdogHolding
        var restoredFix = false
        do {
            try await activateGuest(expectedGeneration: expectedGeneration)
            if let producer = pendingProducer,
               producer.generation == expectedGeneration {
                let deliveryFix = producer.fix.withHoldingSpeed(desiredPaused)
                pendingProducer = PendingProducer(
                    generation: producer.generation,
                    fix: producer.fix,
                    deliveryFix: deliveryFix)
                try await deliverWhileHoldingTurn(
                    deliveryFix,
                    expectedGeneration: expectedGeneration)
                restoredFix = true
            } else if lastAppliedFix != nil || lastProducerFix != nil {
                try await deliverWhileHoldingTurn(
                    expectedGeneration: expectedGeneration
                ) { [self] in
                    guard let fix = lastProducerFix ?? lastAppliedFix else {
                        throw failure(
                            "location_not_running", "no accepted location sample")
                    }
                    return fix.refreshed(
                        at: now(),
                        holding: shouldHoldExistingFix)
                }
                restoredFix = true
            }
            try requireCurrentGeneration(expectedGeneration)
            if desiredPaused {
                state = .paused
            } else if watchdogHolding && !resumedPendingProducer {
                state = .holding
            } else if restoredFix {
                state = .running
            } else {
                state = originalState
            }
            restoreTimersAfterGuestRepair(restoredFix: restoredFix)
        } catch let error as VPhoneSystemLocationError {
            guard generation == expectedGeneration else { return }
            lastError = error
            state = .applying
        } catch {
            guard generation == expectedGeneration else { return }
            lastError = failure("location_guest_unavailable", error.localizedDescription)
            state = .applying
        }
    }

    private func clearPendingProducer() {
        pendingProducer = nil
        reapplyRetryTask?.cancel()
        reapplyRetryTask = nil
    }

    private func restoreTimersAfterGuestRepair(restoredFix: Bool) {
        reapplyRetryTask?.cancel()
        reapplyRetryTask = nil
        heartbeatTask?.cancel()
        watchdogTask?.cancel()
        heartbeatTask = nil
        watchdogTask = nil
        switch mode {
        case .fixed:
            if restoredFix {
                startHeartbeat(seconds: fixedHeartbeatSeconds)
            }
        case .stream:
            if state == .paused && restoredFix {
                startHoldingHeartbeat(seconds: min(1.0, streamWatchdogSeconds))
            } else if state == .holding && restoredFix {
                startHoldingHeartbeat(seconds: min(1.0, streamWatchdogSeconds))
            } else {
                scheduleWatchdog(seconds: streamWatchdogSeconds)
            }
        case nil:
            break
        }
    }

    private func restoreTimersAfterFailedReapply(
        wasPaused: Bool,
        wasHolding: Bool,
        resumedPendingProducer: Bool
    ) {
        if pendingProducer?.generation == generation {
            scheduleReapplyRetry(
                seconds: min(1.0, streamWatchdogSeconds))
            return
        }
        reapplyRetryTask?.cancel()
        reapplyRetryTask = nil
        heartbeatTask?.cancel()
        watchdogTask?.cancel()
        heartbeatTask = nil
        watchdogTask = nil
        switch mode {
        case .fixed:
            if lastProducerFix != nil {
                startHeartbeat(seconds: fixedHeartbeatSeconds)
            }
        case .stream:
            if wasPaused && lastProducerFix != nil {
                startHoldingHeartbeat(seconds: min(1.0, streamWatchdogSeconds))
            } else if wasHolding && !resumedPendingProducer
                        && lastProducerFix != nil {
                startHoldingHeartbeat(seconds: min(1.0, streamWatchdogSeconds))
            } else {
                scheduleWatchdog(seconds: streamWatchdogSeconds)
            }
        case nil:
            break
        }
    }

    private func scheduleReapplyRetry(seconds: Double) {
        reapplyRetryTask?.cancel()
        reapplyRetryTask = nil
        guard let activeGeneration = generation else { return }
        reapplyRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self,
                  self.generation == activeGeneration else { return }
            await self.reapplyAfterReconnect()
        }
    }

    @discardableResult
    private func replaceSource(mode: Mode, owner: String) -> ControlToken {
        heartbeatTask?.cancel()
        watchdogTask?.cancel()
        reapplyRetryTask?.cancel()
        self.mode = mode
        self.owner = owner
        let sourceGeneration = "loc-" + UUID().uuidString.lowercased()
        generation = sourceGeneration
        controlRevision &+= 1
        state = .applying
        lastProducerFix = nil
        lastAppliedFix = nil
        lastProducerSequence = nil
        deliverySequence = -1
        lastAckAt = nil
        lastError = nil
        pendingDelivery = nil
        clearPendingProducer()
        guestActivationRequired = false
        fixedHeartbeatSeconds = 1.0
        persistent = false
        streamWatchdogSeconds = 3.0
        streamTimeoutAction = .hold
        desiredPaused = false
        watchdogHolding = false
        return ControlToken(
            generation: sourceGeneration,
            revision: controlRevision)
    }

    private func currentControlToken() -> ControlToken? {
        generation.map { ControlToken(generation: $0, revision: controlRevision) }
    }

    private func isCurrentControl(_ token: ControlToken) -> Bool {
        generation == token.generation && controlRevision == token.revision
    }

    private func requireCurrentControl(_ token: ControlToken) throws {
        guard isCurrentControl(token) else {
            throw failure(
                "location_generation_conflict",
                "location source changed while waiting for guest")
        }
    }

    private func activateGuest(expectedGeneration: String? = nil) async throws {
        guard let activationGeneration = expectedGeneration ?? generation else {
            throw failure("location_not_running", "no active location source")
        }
        do {
            try await adapter.activate(generation: activationGeneration)
        } catch let error as VPhoneSystemLocationError {
            try requireCurrentGeneration(activationGeneration)
            lastError = error
            throw error
        } catch {
            try requireCurrentGeneration(activationGeneration)
            let wrapped = failure("location_guest_unavailable", error.localizedDescription)
            lastError = wrapped
            throw wrapped
        }
        try requireCurrentGeneration(activationGeneration)
        pendingDelivery = nil
        guestActivationRequired = false
    }

    private func deliver(
        _ fix: VPhoneSystemLocationFix,
        expectedGeneration: String? = nil
    ) async throws {
        guard let deliveryGeneration = expectedGeneration ?? generation else {
            throw failure("location_not_running", "no active location source")
        }
        try await deliver(expectedGeneration: deliveryGeneration, fix: { fix })
    }

    private func deliver(
        expectedGeneration deliveryGeneration: String,
        fix: () throws -> VPhoneSystemLocationFix
    ) async throws {
        try await acquireDeliveryTurn()
        defer { releaseDeliveryTurn() }
        try Task.checkCancellation()
        try await deliverWhileHoldingTurn(
            expectedGeneration: deliveryGeneration,
            fix: fix)
    }

    private func deliverWhileHoldingTurn(
        _ fix: VPhoneSystemLocationFix,
        expectedGeneration deliveryGeneration: String
    ) async throws {
        try await deliverWhileHoldingTurn(
            expectedGeneration: deliveryGeneration,
            fix: { fix })
    }

    private func deliverWhileHoldingTurn(
        expectedGeneration deliveryGeneration: String,
        fix: () throws -> VPhoneSystemLocationFix
    ) async throws {
        try requireCurrentGeneration(deliveryGeneration)
        if guestActivationRequired {
            try await activateGuest(expectedGeneration: deliveryGeneration)
        }
        try requireCurrentGeneration(deliveryGeneration)

        if let pendingDelivery {
            guard pendingDelivery.generation == deliveryGeneration else {
                throw failure(
                    "location_generation_conflict",
                    "pending delivery belongs to another location source")
            }
            try await transmit(pendingDelivery)
            let requestedFix = try fix()
            if pendingDelivery.fix == requestedFix { return }
        }

        let requestedFix = try fix()
        let candidate = PendingDelivery(
            generation: deliveryGeneration,
            sequence: deliverySequence + 1,
            fix: requestedFix)
        pendingDelivery = candidate
        try await transmit(candidate)
    }

    private func transmit(_ delivery: PendingDelivery) async throws {
        do {
            try await adapter.deliver(
                delivery.fix,
                generation: delivery.generation,
                deliverySequence: delivery.sequence)
        } catch is CancellationError {
            try requireCurrentGeneration(delivery.generation)
            throw CancellationError()
        } catch let error as VPhoneSystemLocationError {
            try requireCurrentGeneration(delivery.generation)
            if error.definitiveGuestRejection {
                if pendingDelivery == delivery {
                    pendingDelivery = nil
                }
                if let producer = pendingProducer,
                   producer.generation == delivery.generation,
                   producer.deliveryFix == delivery.fix {
                    clearPendingProducer()
                }
                if error.code == "location_sequence_conflict"
                    || error.code == "location_generation_conflict"
                {
                    guestActivationRequired = true
                    state = .applying
                }
            }
            lastError = error
            throw error
        } catch {
            try requireCurrentGeneration(delivery.generation)
            let wrapped = failure("location_delivery_rejected", error.localizedDescription)
            lastError = wrapped
            throw wrapped
        }
        try requireCurrentGeneration(delivery.generation)
        guard pendingDelivery == delivery else {
            throw failure(
                "location_sequence_conflict",
                "pending location delivery changed while waiting for guest")
        }
        deliverySequence = delivery.sequence
        lastAppliedFix = delivery.fix
        lastAckAt = now()
        lastError = nil
        pendingDelivery = nil
        if let producer = pendingProducer,
           producer.generation == delivery.generation,
           producer.deliveryFix == delivery.fix {
            lastProducerFix = producer.fix
            lastProducerSequence = producer.fix.producerSequence
            watchdogHolding = false
            clearPendingProducer()
        }
        state = .running
    }

    private func acquireDeliveryTurn() async throws {
        try Task.checkCancellation()
        guard deliveryTurnOwned else {
            deliveryTurnOwned = true
            return
        }

        let waiterID = UUID()
        let grant = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                deliveryTurnWaiters.append(DeliveryTurnWaiter(
                    id: waiterID,
                    continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelDeliveryTurnWaiter(waiterID)
            }
        }
        guard case .acquired = grant else {
            throw CancellationError()
        }
    }

    private func cancelDeliveryTurnWaiter(_ id: UUID) {
        guard let index = deliveryTurnWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = deliveryTurnWaiters.remove(at: index)
        waiter.continuation.resume(returning: .cancelled)
    }

    private func releaseDeliveryTurn() {
        if deliveryTurnWaiters.isEmpty {
            deliveryTurnOwned = false
        } else {
            deliveryTurnWaiters.removeFirst().continuation.resume(returning: .acquired)
        }
    }

    private func startHeartbeat(seconds: Double) {
        heartbeatTask?.cancel()
        guard let activeGeneration = generation else { return }
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self else { return }
                do {
                    try await self.refreshFixedHeartbeat(
                        expectedGeneration: activeGeneration)
                } catch is CancellationError {
                    return
                } catch {
                    continue
                }
            }
        }
    }

    private func refreshFixedHeartbeat(expectedGeneration: String) async throws {
        try await acquireDeliveryTurn()
        defer { releaseDeliveryTurn() }
        try Task.checkCancellation()
        try requireCurrentGeneration(expectedGeneration)
        guard lastProducerFix != nil else {
            throw failure("location_not_running", "no accepted location sample")
        }
        let desiredState: State = desiredPaused ? .paused : state
        try await deliverWhileHoldingTurn(
            expectedGeneration: expectedGeneration
        ) { [self] in
            guard let fix = lastProducerFix else {
                throw failure("location_not_running", "no accepted location sample")
            }
            return fix.refreshed(
                at: now(),
                holding: desiredState == .paused || desiredState == .holding)
        }
        try Task.checkCancellation()
        try requireCurrentGeneration(expectedGeneration)
        if desiredState == .paused || desiredState == .holding {
            state = desiredState
        }
    }

    /// Send one paused/watchdog-holding refresh. When a producer delivery is
    /// awaiting an ACK, confirm that exact frame first and do not append a
    /// speed-zero frame derived from the newly accepted producer sample.
    /// Returns true when a moving producer resumed the stream.
    private func refreshHoldingHeartbeat(
        expectedGeneration: String,
        beginWatchdogHold: Bool = false
    ) async throws -> Bool {
        try await acquireDeliveryTurn()
        defer { releaseDeliveryTurn() }
        try Task.checkCancellation()
        try requireCurrentGeneration(expectedGeneration)
        if beginWatchdogHold {
            watchdogHolding = true
        }

        if let producer = pendingProducer,
           producer.generation == expectedGeneration {
            try await deliverWhileHoldingTurn(
                producer.deliveryFix,
                expectedGeneration: expectedGeneration)
            try Task.checkCancellation()
            try requireCurrentGeneration(expectedGeneration)
            guard pendingProducer == nil else {
                throw failure(
                    "location_sequence_conflict",
                    "pending producer was not committed after guest ACK")
            }
            if desiredPaused {
                state = .paused
                return false
            }
            watchdogHolding = false
            state = .running
            return true
        }

        guard desiredPaused || watchdogHolding else { return true }
        guard lastProducerFix != nil else {
            throw failure("location_not_running", "no accepted location sample")
        }
        try await deliverWhileHoldingTurn(
            expectedGeneration: expectedGeneration
        ) { [self] in
            guard let fix = lastProducerFix else {
                throw failure("location_not_running", "no accepted location sample")
            }
            return fix.refreshed(at: now(), holding: true)
        }
        try Task.checkCancellation()
        try requireCurrentGeneration(expectedGeneration)
        state = desiredPaused ? .paused : .holding
        return false
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
                guard self.lastProducerFix != nil else { return }
                do {
                    let resumedProducer = try await self.refreshHoldingHeartbeat(
                        expectedGeneration: activeGeneration,
                        beginWatchdogHold: true)
                    guard !Task.isCancelled,
                          self.generation == activeGeneration else { return }
                    if resumedProducer {
                        self.scheduleWatchdog(seconds: seconds)
                    } else {
                        self.startHoldingHeartbeat(seconds: min(1.0, seconds))
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled,
                          self.generation == activeGeneration else { return }
                    self.state = .applying
                    self.startHoldingHeartbeat(seconds: min(1.0, seconds))
                }
            case .stop:
                do {
                    _ = try await self.stop(generation: activeGeneration)
                } catch is CancellationError {
                    return
                } catch let error as VPhoneSystemLocationError {
                    guard !Task.isCancelled,
                          self.generation == activeGeneration else { return }
                    self.lastError = error
                    self.state = .applying
                    self.scheduleWatchdog(seconds: seconds)
                } catch {
                    guard !Task.isCancelled,
                          self.generation == activeGeneration else { return }
                    self.lastError = self.failure(
                        "location_delivery_rejected", error.localizedDescription)
                    self.state = .applying
                    self.scheduleWatchdog(seconds: seconds)
                }
            }
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
                      self.lastProducerFix != nil else { return }
                do {
                    let resumedProducer = try await self.refreshHoldingHeartbeat(
                        expectedGeneration: activeGeneration)
                    if !Task.isCancelled,
                       self.generation == activeGeneration {
                        if resumedProducer {
                            self.heartbeatTask = nil
                            self.scheduleWatchdog(seconds: self.streamWatchdogSeconds)
                            return
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled,
                          self.generation == activeGeneration else { return }
                    self.state = .applying
                }
            }
        }
    }

    private func resetState() {
        heartbeatTask?.cancel()
        watchdogTask?.cancel()
        reapplyRetryTask?.cancel()
        heartbeatTask = nil
        watchdogTask = nil
        reapplyRetryTask = nil
        mode = nil
        owner = nil
        generation = nil
        controlRevision &+= 1
        state = .off
        lastProducerFix = nil
        lastAppliedFix = nil
        lastProducerSequence = nil
        deliverySequence = -1
        lastAckAt = nil
        lastError = nil
        pendingDelivery = nil
        clearPendingProducer()
        guestActivationRequired = false
        fixedHeartbeatSeconds = 1.0
        persistent = false
        streamWatchdogSeconds = 3.0
        streamTimeoutAction = .hold
        desiredPaused = false
        watchdogHolding = false
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
            try validateTimerSeconds(
                saved.heartbeatSeconds,
                field: "persisted heartbeat_s",
                errorCode: "location_persistence_corrupt")
            mode = .fixed
            state = .applying
            owner = saved.owner
            generation = "loc-" + UUID().uuidString.lowercased()
            controlRevision &+= 1
            lastProducerFix = saved.fix
            lastProducerSequence = saved.fix.producerSequence
            fixedHeartbeatSeconds = saved.heartbeatSeconds
            persistent = true
            guestActivationRequired = true
        } catch let error as VPhoneSystemLocationError {
            lastError = error
            try? stateStore.quarantine()
        } catch {
            lastError = failure(
                "location_persistence_corrupt",
                "failed to restore fixed location: \(error.localizedDescription)")
            try? stateStore.quarantine()
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

    private func requireCurrentGeneration(_ expected: String) throws {
        guard generation == expected else {
            throw failure(
                "location_generation_conflict",
                "location source changed while waiting for guest")
        }
    }

    private func requireSourceUnchanged(_ expected: String?) throws {
        guard generation == expected else {
            throw failure(
                "location_generation_conflict",
                "location source changed while waiting for guest")
        }
    }

    private func validateOwner(_ owner: String) throws {
        guard !owner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw failure("invalid_location_source", "owner is required")
        }
    }

    private func validateTimerSeconds(
        _ seconds: Double,
        field: String,
        errorCode: String = "invalid_location_source"
    ) throws {
        guard seconds.isFinite,
              seconds >= Self.minimumTimerSeconds,
              seconds <= Self.maximumTimerSeconds
        else {
            throw failure(
                errorCode,
                "\(field) must be between \(Self.minimumTimerSeconds) and "
                    + "\(Self.maximumTimerSeconds) seconds")
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
