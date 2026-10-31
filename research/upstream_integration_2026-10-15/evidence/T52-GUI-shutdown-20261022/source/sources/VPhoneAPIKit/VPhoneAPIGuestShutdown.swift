import Darwin
import Foundation

/// One capability probe and one shutdown request on the VM's own VSOCK
/// device. Each HTTP response closes its connection. Both connections share
/// one deadline; there is no host listener, credential, installation, or retry.
public struct VPhoneAPIGuestShutdown: Sendable {
    private let connector: VPhoneAPIProxy.Connector
    private let timeout: TimeInterval

    public init(connector: @escaping VPhoneAPIProxy.Connector, timeout: TimeInterval = 3) {
        self.connector = connector
        self.timeout = timeout
    }

    public func request() async throws -> Bool {
        guard timeout.isFinite, timeout > 0, timeout <= 5 else {
            throw Self.failure("configuration")
        }
        let attempt = Attempt()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result { try exchange(attempt) }
                    attempt.finish()
                    continuation.resume(with: result)
                }
            }
        } onCancel: { attempt.cancel() }
    }

    private func exchange(_ attempt: Attempt) throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(timeout)
        let connectDeadline = DispatchTime.now() + timeout
        let healthSocket = try connect(attempt, deadline: connectDeadline)
        let healthBody = try Self.http(healthSocket, method: "GET", path: "/v1/health", body: Data(),
                                       deadline: deadline, attempt: attempt)
        let health = try VPhoneAPIHealth.decode(healthBody,
            requiredCapabilities: ["session_identity", "system_shutdown"], expectedBinaryHash: nil)
        guard health.instanceID != nil else { throw Self.failure("incompatible_api") }
        try attempt.check()
        // The guest discards follow-up bytes after a response. Never reuse its
        // health connection for a mutating command.
        let socket = try connect(attempt, deadline: connectDeadline)
        let id = UUID().uuidString
        let body = try VPhoneAPIWire.request("system.shutdown", params: ["force": .bool(true)], id: id)
        let reply = try Self.http(socket, method: "POST", path: "/v1/rpc", body: body,
                                 deadline: deadline, attempt: attempt)
        guard case let .response(response) = try VPhoneAPIWire.message(reply), response.id == .string(id),
              case let .object(fields) = try VPhoneAPIWire.result(response) else {
            throw VPhoneAPIWire.invalidEnvelope()
        }
        return fields["accepted"] == .bool(true)
    }

    private func connect(_ attempt: Attempt, deadline: DispatchTime) throws -> VPhoneAPISocket {
        let generation = try attempt.begin()
        guard DispatchTime.now() < deadline else { throw Self.failure("timeout") }
        connector { attempt.complete($0, generation: generation) }
        guard attempt.ready.wait(timeout: deadline) == .success else { throw Self.failure("timeout") }
        return try attempt.connected()
    }

    private static func http(_ socket: VPhoneAPISocket, method: String, path: String, body: Data,
                             deadline: ContinuousClock.Instant, attempt: Attempt) throws -> Data {
        let head = "\(method) \(path) HTTP/1.1\r\nHost: vphoned\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n"
        let request = Data(head.utf8) + body
        try request.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try wait(socket.descriptor, events: Int16(POLLOUT), deadline: deadline, attempt: attempt)
                let count = Darwin.write(socket.descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                guard count > 0 else { throw failure("transport") }
                offset += count
            }
        }
        var header = Data()
        while header.suffix(4) != Data("\r\n\r\n".utf8) {
            guard header.count < 16384 else { throw failure("response_too_large") }
            header.append(try read(socket.descriptor, count: 1, deadline: deadline, attempt: attempt))
        }
        guard let text = String(data: header, encoding: .ascii) else { throw failure("protocol") }
        let lines = text.components(separatedBy: "\r\n")
        let status = lines.first?.split(separator: " ") ?? []
        guard status.count >= 2, ["HTTP/1.1", "HTTP/1.0"].contains(status[0]), status[1] == "200" else {
            throw failure("http")
        }
        var lengths: [String] = []
        for line in lines.dropFirst() where !line.isEmpty {
            let field = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard field.count == 2 else { throw failure("protocol") }
            let name = field[0].lowercased()
            guard name != "transfer-encoding" else { throw failure("protocol") }
            if name == "content-length" { lengths.append(field[1].trimmingCharacters(in: .whitespaces)) }
        }
        guard lengths.count == 1, let length = lengths.first, !length.isEmpty,
              length.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(length), count <= 65536 else {
            throw failure("protocol")
        }
        var result = Data()
        while result.count < count {
            result.append(try read(socket.descriptor, count: min(4096, count - result.count), deadline: deadline, attempt: attempt))
        }
        return result
    }

    private static func read(_ fd: Int32, count: Int, deadline: ContinuousClock.Instant, attempt: Attempt) throws -> Data {
        while true {
            try wait(fd, events: Int16(POLLIN), deadline: deadline, attempt: attempt)
            var buffer = [UInt8](repeating: 0, count: count)
            let received = Darwin.read(fd, &buffer, count)
            if received < 0, errno == EINTR || errno == EAGAIN { continue }
            guard received > 0 else { throw failure("transport") }
            return Data(buffer.prefix(received))
        }
    }

    private static func wait(_ fd: Int32, events: Int16, deadline: ContinuousClock.Instant, attempt: Attempt) throws {
        while ContinuousClock.now < deadline {
            try attempt.check()
            var item = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&item, 1, 25)
            if result > 0 {
                guard item.revents & Int16(POLLNVAL) == 0 else { throw failure("transport") }
                return
            }
            if result < 0, errno != EINTR { throw failure("transport") }
        }
        throw failure("timeout")
    }

    private static func failure(_ code: String) -> VPhoneAPIError {
        VPhoneAPIError(code: code, message: "Guest shutdown request unavailable (\(code))")
    }

    private final class Attempt: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var accepting = true
        private var cancelled = false
        private var reply: Result<VPhoneAPISocket, any Error>?
        private var generation = UUID()

        func begin() throws -> UUID {
            try lock.withLock {
                guard !cancelled else { throw CancellationError() }
                (try? reply?.get())?.shutDown()
                reply = nil
                generation = UUID()
                return generation
            }
        }
        func complete(_ result: Result<VPhoneAPISocket, any Error>, generation: UUID) {
            lock.withLock {
                guard accepting, reply == nil, self.generation == generation else { return }
                reply = result
                ready.signal()
            }
        }
        func check() throws {
            try lock.withLock { if cancelled { throw CancellationError() } }
        }
        func connected() throws -> VPhoneAPISocket {
            try lock.withLock {
                guard !cancelled else { throw CancellationError() }
                guard let reply else { throw VPhoneAPIGuestShutdown.failure("transport") }
                return try reply.get()
            }
        }
        func cancel() {
            lock.withLock {
                cancelled = true
                accepting = false
                (try? reply?.get())?.shutDown()
                ready.signal()
            }
        }
        func finish() {
            lock.withLock {
                accepting = false
                (try? reply?.get())?.shutDown()
                reply = nil
            }
        }
    }
}
