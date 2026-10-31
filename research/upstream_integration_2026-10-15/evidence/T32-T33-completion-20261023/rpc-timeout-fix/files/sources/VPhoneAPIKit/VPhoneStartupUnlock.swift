import Foundation

/// Optional startup work for a validated API session. Enabling the option is
/// prospective: the currently observed instance is never unlocked by a toggle.
/// Cancellation stops further requests; it cannot undo an already sent RPC.
@MainActor
public final class VPhoneStartupUnlock {
    struct Timing {
        var window: Duration = .seconds(90)
        var poll: Duration = .seconds(1)
    }
    private var enabled: Bool
    private let timing: Timing
    private let call: @MainActor (String, [String: VPhoneJSONValue], String) async throws -> VPhoneJSONValue
    private var current: VPhoneAPISession.Snapshot?
    private var seen: Set<String> = []
    private var task: Task<Void, Never>?
    private var lease = UUID()
    private var stopped = false
    var operation: Task<Void, Never>? { task }
    public private(set) var result: String?

    public convenience init(enabled: Bool = false,
        call: @escaping @MainActor (String, [String: VPhoneJSONValue], String) async throws -> VPhoneJSONValue) {
        self.init(enabled: enabled, timing: Timing(), call: call)
    }

    init(enabled: Bool, timing: Timing,
         call: @escaping @MainActor (String, [String: VPhoneJSONValue], String) async throws -> VPhoneJSONValue) {
        self.enabled = enabled
        self.timing = timing
        self.call = call
    }

    public func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        invalidate()
        // observe already records the current instance, including when disabled.
    }

    public func stop() {
        stopped = true
        invalidate()
    }

    public func observe(_ snapshot: VPhoneAPISession.Snapshot) {
        let previous = current
        current = snapshot
        if previous?.generation != snapshot.generation || previous?.health?.instanceID != snapshot.health?.instanceID ||
            previous?.health?.binaryHash != snapshot.health?.binaryHash || snapshot.state != .ready ||
            snapshot.health?.setupPending != false {
            invalidate()
        }
        guard !stopped, snapshot.state == .ready, snapshot.generation != nil,
              let health = snapshot.health, let instance = health.instanceID, UUID(uuidString: instance) != nil else {
            result = "identity_unavailable"
            return
        }
        guard seen.insert(instance).inserted else { return }
        guard enabled else { result = "disabled"; return }
        guard health.capabilities.isSuperset(of: ["screen_unlock", "display"]) else {
            result = "unsupported_capability"; return
        }
        guard health.setupPending == false else {
            result = health.setupPending == true ? "setup_pending" : "setup_unknown"
            return
        }
        let token = lease
        task = Task { [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now + timing.window
            do {
                while true {
                    try check(snapshot, token: token)
                    let value = try await call("screen.unlock", ["timeout": .number(60)], "screen_unlock")
                    try check(snapshot, token: token)
                    guard case let .object(fields) = value, case let .bool(wasLocked) = fields["was_locked"] else {
                        throw VPhoneAPIError(code: "protocol", message: "Invalid startup unlock response")
                    }
                    if wasLocked { result = "unlock_replied"; return }
                    var raisedLock = false
                    while ContinuousClock.now < deadline {
                        try await Task.sleep(for: timing.poll)
                        try check(snapshot, token: token)
                        let screen = try await call("device.screen", [:], "display")
                        try check(snapshot, token: token)
                        guard case let .object(fields) = screen, case let .bool(locked) = fields["locked"] else {
                            throw VPhoneAPIError(code: "protocol", message: "Invalid startup screen response")
                        }
                        if locked { raisedLock = true; break }
                    }
                    guard raisedLock else { result = "startup_observation_ended"; return }
                }
            } catch {
                if lease == token { result = Task.isCancelled ? "cancelled" : "failed" }
            }
        }
    }

    private func invalidate() {
        lease = UUID()
        task?.cancel()
        task = nil
    }

    private func check(_ owner: VPhoneAPISession.Snapshot, token: UUID) throws {
        try Task.checkCancellation()
        guard enabled, !stopped, lease == token, current?.state == .ready,
              current?.vmInstanceID == owner.vmInstanceID, current?.generation == owner.generation,
              current?.health?.instanceID == owner.health?.instanceID, current?.health?.binaryHash == owner.health?.binaryHash,
              current?.health?.setupPending == false else { throw CancellationError() }
    }
}
