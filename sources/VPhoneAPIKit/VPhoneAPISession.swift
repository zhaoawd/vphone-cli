import Foundation

/// Owns one VM runtime's API connection. Owners must call stop before releasing
/// the session. Submitted operations are never replayed after reconnecting.
@MainActor
public final class VPhoneAPISession {
    public struct Snapshot: Codable, Sendable, Equatable {
        public enum State: String, Codable, Sendable { case idle, connecting, ready, reconnecting, stopped }
        public let vmInstanceID: String
        public let state: State
        public let generation: UUID?
        public let health: VPhoneAPIHealth?
        public let errorCode: String?
    }

    public private(set) var snapshot: Snapshot
    private let probe: @Sendable () async throws -> VPhoneAPIHealth
    private let connect: @Sendable () -> VPhoneAPIWebSocket
    private let requiredCapabilities: Set<String>
    private let expectedBinaryHash: String?
    private let timing: Timing
    private var monitor: Task<Void, Never>?
    private var socket: VPhoneAPIWebSocket?
    private var runID: UUID?

    struct Timing: Sendable {
        var handshake: Duration = .seconds(5)
        var heartbeat: Duration = .seconds(3)
        var retry: Duration = .seconds(1)
    }

    public convenience init(client: VPhoneAPIClient, vmInstanceID: String,
                            requiredCapabilities: Set<String> = [], expectedBinaryHash: String? = nil) {
        self.init(vmInstanceID: vmInstanceID, requiredCapabilities: requiredCapabilities,
                  expectedBinaryHash: expectedBinaryHash, probe: { try await client.health() },
                  connect: { client.openWebSocket() })
    }

    init(vmInstanceID: String, requiredCapabilities: Set<String> = [], expectedBinaryHash: String? = nil,
         timing: Timing = Timing(), probe: @escaping @Sendable () async throws -> VPhoneAPIHealth,
         connect: @escaping @Sendable () -> VPhoneAPIWebSocket) {
        snapshot = Snapshot(vmInstanceID: vmInstanceID, state: .idle, generation: nil, health: nil, errorCode: nil)
        self.requiredCapabilities = requiredCapabilities.union(["session_identity"])
        self.expectedBinaryHash = expectedBinaryHash
        self.timing = timing
        self.probe = probe
        self.connect = connect
    }

    public func start() {
        guard monitor == nil else { return }
        let id = UUID()
        runID = id
        transition(.connecting)
        monitor = Task { await run(id) }
    }

    public func stop() {
        runID = nil
        monitor?.cancel()
        monitor = nil
        let previous = socket
        socket = nil
        transition(.stopped)
        Task { await previous?.close() }
    }

    public func call(_ method: String, params: [String: VPhoneJSONValue] = [:],
                     requiring capability: String? = nil) async throws -> VPhoneJSONValue {
        guard snapshot.state == .ready, let socket else { throw Self.error("not_ready") }
        if let capability, snapshot.health?.capabilities.contains(capability) != true {
            throw Self.error("unsupported_capability")
        }
        let generation = snapshot.generation
        let value = try await socket.call(method, params: params)
        guard snapshot.state == .ready, snapshot.generation == generation else { throw Self.error("stale_session") }
        return value
    }

    private func run(_ id: UUID) async {
        while runID == id, !Task.isCancelled {
            var attempt: VPhoneAPIWebSocket?
            do {
                let health = try await probe()
                try check(id)
                try validate(health)
                let connection = connect()
                attempt = connection
                socket = connection
                try await connection.startEvents()
                let hello = try await Self.hello(connection, deadline: timing.handshake)
                try check(id)
                try validate(hello)
                guard Self.sameIdentity(health, hello) else { throw Self.error("identity_mismatch") }
                transition(.ready, generation: connection.generation, health: hello)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await _ in connection.events { try Task.checkCancellation() }
                        throw Self.error("disconnected")
                    }
                    group.addTask { [timing] in
                        while true {
                            try await Task.sleep(for: timing.heartbeat)
                            let value = try await connection.call("agent.health")
                            let current = try VPhoneAPIHealth.decode(JSONEncoder().encode(value),
                                requiredCapabilities: [], expectedBinaryHash: nil)
                            guard Self.sameIdentity(hello, current) else { throw Self.error("identity_mismatch") }
                        }
                    }
                    defer { group.cancelAll() }
                    try await group.next()
                }
            } catch {
                // Do not publish remote messages, tokens, URLs, or old-run failures.
                if runID == id, !Task.isCancelled {
                    let known = ["incompatible_api", "unsupported_capability", "binary_mismatch", "identity_mismatch",
                                 "protocol", "timeout", "disconnected", "event_overflow", "response_too_large"]
                    let code = (error as? VPhoneAPIError)?.code ?? "transport"
                    transition(.reconnecting, errorCode: known.contains(code) ? code : "transport")
                }
            }
            await attempt?.close()
            guard runID == id, !Task.isCancelled else { return }
            socket = nil
            do { try await Task.sleep(for: timing.retry) } catch { return }
        }
    }

    private func check(_ id: UUID) throws {
        try Task.checkCancellation()
        guard runID == id else { throw Self.error("stale_session") }
    }

    private func validate(_ health: VPhoneAPIHealth) throws {
        guard health.instanceID != nil else { throw Self.error("incompatible_api") }
        guard requiredCapabilities.isSubset(of: health.capabilities) else { throw Self.error("unsupported_capability") }
        if let expectedBinaryHash, health.binaryHash != expectedBinaryHash { throw Self.error("binary_mismatch") }
    }

    private func transition(_ state: Snapshot.State, generation: UUID? = nil,
                            health: VPhoneAPIHealth? = nil, errorCode: String? = nil) {
        snapshot = Snapshot(vmInstanceID: snapshot.vmInstanceID, state: state,
                            generation: generation, health: health, errorCode: errorCode)
    }

    private nonisolated static func sameIdentity(_ a: VPhoneAPIHealth, _ b: VPhoneAPIHealth) -> Bool {
        a.instanceID == b.instanceID && a.binaryHash == b.binaryHash &&
            a.apiVersion == b.apiVersion && a.capabilities == b.capabilities
    }

    private nonisolated static func hello(_ socket: VPhoneAPIWebSocket, deadline: Duration) async throws -> VPhoneAPIHealth {
        try await withThrowingTaskGroup(of: VPhoneAPIHealth.self) { group in
            group.addTask {
                var events = socket.events.makeAsyncIterator()
                guard let event = try await events.next(), event.event == "connected" else { throw error("protocol") }
                return try VPhoneAPIHealth.decode(JSONEncoder().encode(event.data),
                    requiredCapabilities: [], expectedBinaryHash: nil)
            }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw error("timeout")
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw error("disconnected") }
            return value
        }
    }

    private nonisolated static func error(_ code: String) -> VPhoneAPIError {
        VPhoneAPIError(code: code, message: "API session unavailable (\(code)); submitted operations may continue")
    }
}
