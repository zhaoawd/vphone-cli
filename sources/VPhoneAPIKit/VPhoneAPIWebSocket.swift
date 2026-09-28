import Foundation

protocol VPhoneAPIWebSocketTransport: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func cancel()
}

struct VPhoneURLSessionWebSocket: VPhoneAPIWebSocketTransport {
    let task: URLSessionWebSocketTask
    func send(_ data: Data) async throws {
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }
    func receive() async throws -> Data {
        switch try await task.receive() {
        case let .data(data): return data
        case let .string(text): return Data(text.utf8)
        @unknown default: throw VPhoneAPIWire.invalidEnvelope()
        }
    }
    func cancel() { task.cancel(with: .goingAway, reason: nil) }
}

/// API v1 response correlation. Cancellation ends the local wait; it cannot
/// establish that an operation already submitted to the guest has stopped.
public actor VPhoneAPIWebSocket {
    public nonisolated let generation = UUID()
    public nonisolated let events: AsyncThrowingStream<VPhoneAPIEvent, any Error>
    private let eventContinuation: AsyncThrowingStream<VPhoneAPIEvent, any Error>.Continuation
    private let transport: any VPhoneAPIWebSocketTransport
    private let timeout: TimeInterval
    private var receiver: Task<Void, Never>?
    private var closed = false
    private var pending: [String: Pending] = [:]
    private static let maximumPending = 16

    private struct Pending {
        let continuation: CheckedContinuation<VPhoneJSONValue, any Error>
        let sender: Task<Void, Never>
        let timer: Task<Void, Never>
    }

    init(transport: any VPhoneAPIWebSocketTransport, timeout: TimeInterval) {
        self.transport = transport
        self.timeout = timeout
        (events, eventContinuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(64))
    }

    deinit {
        receiver?.cancel()
        transport.cancel()
        eventContinuation.finish()
        for item in pending.values {
            item.sender.cancel()
            item.timer.cancel()
            item.continuation.resume(throwing: Self.disconnected())
        }
    }

    public func call(_ method: String, params: [String: VPhoneJSONValue] = [:]) async throws -> VPhoneJSONValue {
        try Task.checkCancellation()
        guard !closed else { throw Self.disconnected() }
        guard pending.count < Self.maximumPending else {
            throw VPhoneAPIError(code: "busy", message: "16 API requests are pending")
        }
        let id = "\(generation.uuidString):\(UUID().uuidString)"
        let data = try VPhoneAPIWire.request(method, params: params, id: id)
        startReceiver()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let sender = Task { [weak self, transport] in
                    do {
                        try Task.checkCancellation()
                        try await transport.send(data)
                    } catch {
                        // A send failure invalidates the connection, but cancelling
                        // a local caller must not cancel unrelated requests.
                        if !Task.isCancelled { await self?.fail(error) }
                    }
                }
                let timer = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    await self?.finish(id, result: .failure(VPhoneAPIError(
                        code: "timeout", message: "API deadline exceeded; guest operation may continue")))
                }
                pending[id] = Pending(continuation: continuation, sender: sender, timer: timer)
            }
        } onCancel: {
            Task { await self.finish(id, result: .failure(CancellationError())) }
        }
    }

    /// Starts event reception even when no RPC is needed.
    public func startEvents() throws {
        guard !closed else { throw Self.disconnected() }
        startReceiver()
    }

    public func close() { fail(Self.disconnected()) }

    private func startReceiver() {
        guard receiver == nil else { return }
        receiver = Task { [weak self, transport] in
            do {
                while !Task.isCancelled {
                    let data = try await transport.receive()
                    guard let self, await self.accept(data) else { return }
                }
            } catch {
                await self?.fail(error)
            }
        }
    }

    private func accept(_ data: Data) -> Bool {
        guard !closed else { return false }
        do {
            switch try VPhoneAPIWire.message(data) {
            case let .response(response):
                guard case let .string(id) = response.id else { throw VPhoneAPIWire.invalidEnvelope() }
                // Unknown, duplicate, cancelled and old-generation IDs never
                // resolve another request. No state is allocated for them.
                guard pending[id] != nil else { return true }
                finish(id, result: Result { try VPhoneAPIWire.result(response) })
            case let .event(event):
                switch eventContinuation.yield(event) {
                case .enqueued: break
                case .dropped:
                    throw VPhoneAPIError(code: "event_overflow", message: "API event buffer is full")
                case .terminated: throw Self.disconnected()
                @unknown default: throw VPhoneAPIWire.invalidEnvelope()
                }
            }
            return true
        } catch {
            fail(error)
            return false
        }
    }

    private func finish(_ id: String, result: Result<VPhoneJSONValue, any Error>) {
        guard let item = pending.removeValue(forKey: id) else { return }
        item.sender.cancel()
        item.timer.cancel()
        item.continuation.resume(with: result)
    }

    private func fail(_ error: any Error) {
        guard !closed else { return }
        closed = true
        receiver?.cancel()
        receiver = nil
        transport.cancel()
        eventContinuation.finish(throwing: error)
        for id in Array(pending.keys) { finish(id, result: .failure(error)) }
    }

    private static func disconnected() -> VPhoneAPIError {
        VPhoneAPIError(code: "disconnected", message: "API socket is closed; submitted guest operations may continue")
    }
}
