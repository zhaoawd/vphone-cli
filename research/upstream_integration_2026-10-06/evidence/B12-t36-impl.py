from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
(r/'sources/VPhoneAPIKit/VPhoneStartupUnlock.swift').write_text(r'''import Foundation

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
''')
p=r/'sources/VPhoneAPIKit/VPhoneAPIWire.swift';s=p.read_text().replace('''    public let instanceID: String?
''','''    public let instanceID: String?
    /// Absent in legacy candidates. Unknown must not authorize startup unlock.
    public let setupPending: Bool?
''');s=s.replace('''        return Self(apiVersion: 1, binaryHash: hash, capabilities: capabilities, ios: ios, instanceID: instanceID)''','''        let setupPending: Bool?
        if let field = value["setup_pending"] {
            guard case let .bool(pending) = field else { throw VPhoneAPIWire.invalidEnvelope() }
            setupPending = pending
        } else { setupPending = nil }
        return Self(apiVersion: 1, binaryHash: hash, capabilities: capabilities, ios: ios, instanceID: instanceID,
                    setupPending: setupPending)''');p.write_text(s)
p=r/'sources/VPhoneAPIKit/VPhoneAPISession.swift';s=p.read_text().replace('''    public private(set) var snapshot: Snapshot''','''    public private(set) var snapshot: Snapshot
    public var onSnapshotChange: (@MainActor (Snapshot) -> Void)?''');s=s.replace('''                            guard Self.sameIdentity(hello, current) else { throw Self.error("identity_mismatch") }
''','''                            guard Self.sameIdentity(hello, current) else { throw Self.error("identity_mismatch") }
                            await self.publishHeartbeat(current, run: id, generation: connection.generation)
''');s=s.replace('''    private func check(_ id: UUID) throws {''','''    private func publishHeartbeat(_ health: VPhoneAPIHealth, run id: UUID, generation: UUID) {
        guard runID == id, snapshot.state == .ready, snapshot.generation == generation else { return }
        transition(.ready, generation: generation, health: health)
    }

    private func check(_ id: UUID) throws {''');s=s.replace('''                            generation: generation, health: health, errorCode: errorCode)
    }
''','''                            generation: generation, health: health, errorCode: errorCode)
        onSnapshotChange?(snapshot)
    }
''');p.write_text(s)
p=r/'sources/vphone-cli/VPhoneCLI.swift';s=p.read_text().replace('''    var apiListen: String?
''','''    var apiListen: String?

    @Flag(help: "Unlock newly observed guest instances at startup. Requires --api-listen and trusted Setup Assistant status; default off. No passcode is supplied.")
    var unlockAtStartup = false
''',1);s=s.replace('''        try VPhoneAPIProxyOptions.validate(listen: apiListen, dfu: dfu, noVphoned: noVphoned)
''','''        try VPhoneAPIProxyOptions.validate(listen: apiListen, dfu: dfu, noVphoned: noVphoned)
        if unlockAtStartup, apiListen == nil {
            throw ValidationError("--unlock-at-startup requires --api-listen")
        }
''',1);p.write_text(s)
p=r/'sources/vphone-cli/VPhoneAppDelegate.swift';s=p.read_text().replace('''    private var apiSession: VPhoneAPISession?''','''    private var apiSession: VPhoneAPISession?
    private var startupUnlock: VPhoneStartupUnlock?''');s=s.replace('''                        apiSession = session
                        session.start()''','''                        apiSession = session
                        let unlock = VPhoneStartupUnlock(enabled: cli.unlockAtStartup) { [weak session] method, params, capability in
                            guard let session else { throw CancellationError() }
                            return try await session.call(method, params: params, requiring: capability)
                        }
                        startupUnlock = unlock
                        session.onSnapshotChange = { [weak unlock] snapshot in unlock?.observe(snapshot) }
                        session.start()''');s=s.replace('''    private func handleInterrupt() {
        guard let vm''','''    private func handleInterrupt() {
        startupUnlock?.stop()
        guard let vm''');s=s.replace('''        apiSession?.stop()''','''        startupUnlock?.stop()
        apiSession?.stop()''');p.write_text(s)
