import Darwin
import Foundation

/// Opt-in loopback TCP relay to the API daemon. The connector must return
/// promptly and invoke its completion once; a late socket is closed, not reused.
@MainActor
public final class VPhoneAPIProxy {
    public typealias Connector = @Sendable (@escaping @Sendable (Result<VPhoneAPISocket, any Error>) -> Void) -> Void
    public static let maximumConnections = 16
    private let token: String
    private let connector: Connector
    private let state = Clients()
    private let timing: Timing
    private var listener: DispatchSourceRead?

    struct Timing: Sendable {
        var admission: TimeInterval = 5
        var connect: TimeInterval = 5
        var write: TimeInterval = 5
        var idle: TimeInterval = 300
        var drain: TimeInterval = 5
    }

    public convenience init(token: String, connector: @escaping Connector) throws {
        try self.init(token: token, timing: Timing(), connector: connector)
    }

    init(token: String, timing: Timing, connector: @escaping Connector) throws {
        guard VPhoneAPIRequestGate.isValidToken(token) else {
            throw VPhoneAPIError(code: "configuration", message: "Invalid API token")
        }
        self.token = token
        self.connector = connector
        self.timing = timing
    }

    /// Only IPv4 loopback is exposed. Port zero asks the system to choose a port.
    public func start(port: UInt16) throws -> URL {
        guard listener == nil, !state.isStopped else {
            throw VPhoneAPIError(code: "state", message: "API proxy already started or stopped")
        }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw VPhoneAPISocket.failure() }
        let socket = try VPhoneAPISocket(takingOwnership: fd)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, Int32(Self.maximumConnections)) == 0 else { throw VPhoneAPISocket.failure() }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard result == 0 else { throw VPhoneAPISocket.failure() }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "vphone.api.accept"))
        let state = state, connector = connector, token = token, timing = timing
        source.setEventHandler { @Sendable in
            while !state.isStopped {
                let accepted = accept(fd, nil, nil)
                if accepted < 0 { if errno == EINTR { continue }; return }
                guard let host = try? VPhoneAPISocket(takingOwnership: accepted) else { continue }
                let client = Client(host: host)
                guard state.add(client) else { continue }
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { client.stop(); client.releaseSockets(); state.remove(client) }
                    Self.serve(client, state: state, token: token, timing: timing, connector: connector)
                }
            }
        }
        source.setCancelHandler { @Sendable in withExtendedLifetime(socket) {} }
        listener = source
        source.resume()
        return URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))")!
    }

    public func stop() {
        state.stop()
        listener?.cancel()
        listener = nil
    }

    deinit { state.stop(); listener?.cancel() }

    private final class Clients: @unchecked Sendable {
        private var attempts = 0
        private let lock = NSLock()
        private var clients: [ObjectIdentifier: Client] = [:]
        private var stopped = false
        var isStopped: Bool { lock.withLock { stopped } }
        func reserveAttempt() -> Bool {
            lock.withLock {
                guard !stopped, attempts < 16 else { return false }
                attempts += 1
                return true
            }
        }
        func finishAttempt() { lock.withLock { attempts -= 1 } }
        func add(_ client: Client) -> Bool {
            lock.withLock {
                guard !stopped, clients.count < 16 else { return false }
                clients[ObjectIdentifier(client)] = client
                return true
            }
        }
        func remove(_ client: Client) { _ = lock.withLock { clients.removeValue(forKey: ObjectIdentifier(client)) } }
        func stop() {
            let active = lock.withLock { stopped = true; return Array(clients.values) }
            for client in active { client.stop() }
        }
    }

    private final class Client: @unchecked Sendable {
        private var host: VPhoneAPISocket?
        let hostDescriptor: Int32
        let ready = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var stopped = false
        private var replied = false
        private var accepting = true
        private var guest: VPhoneAPISocket?
        init(host: VPhoneAPISocket) { self.host = host; hostDescriptor = host.descriptor }
        var isStopped: Bool { lock.withLock { stopped } }
        func complete(_ result: Result<VPhoneAPISocket, any Error>) -> Bool {
            lock.withLock {
                guard !replied else { return false }
                replied = true
                if !stopped && accepting { guest = try? result.get() }
                ready.signal()
                return true
            }
        }
        // Framework callbacks may retain Client after its worker exits. Drop
        // socket ownership here so a missing callback cannot retain host fds.
        func releaseSockets() { lock.withLock { host = nil; guest = nil } }
        func stopGuestWait() { lock.withLock { accepting = false; guest?.shutDown(); guest = nil } }
        func connected() -> VPhoneAPISocket? { lock.withLock { stopped ? nil : guest } }
        func stop() {
            lock.withLock {
                stopped = true
                host?.shutDown()
                guest?.shutDown()
                ready.signal()
            }
        }
    }

    private nonisolated static func serve(_ client: Client, state: Clients, token: String, timing: Timing, connector: Connector) {
        let host = client.hostDescriptor
        let deadline = ContinuousClock.now + .seconds(timing.admission)
        var received = Data()
        var admitted: Data?
        while !client.isStopped, ContinuousClock.now < deadline {
            guard wait(host, events: Int16(POLLIN), until: deadline) else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(host, &buffer, buffer.count)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { return }
            received.append(contentsOf: buffer.prefix(count))
            switch VPhoneAPIRequestGate.evaluate(received, token: token) {
            case .needMore: continue
            case .reject:
                _ = write(VPhoneAPIRequestGate.unauthorizedResponse, to: host, until: .now + .seconds(timing.write))
                return
            case let .accept(data): admitted = data
            }
            break
        }
        guard let admitted, !client.isStopped else { return }
        // Keep attempts reserved until the framework callback actually returns,
        // even if the host wait times out. Missing callbacks cannot grow without bound.
        guard state.reserveAttempt() else {
            sendFailure(503, to: host, timing: timing); return
        }
        connector { result in
            if client.complete(result) { state.finishAttempt() }
        }
        let connected = client.ready.wait(timeout: .now() + timing.connect)
        guard !client.isStopped else { return }
        guard connected == .success, let guest = client.connected() else {
            client.stopGuestWait()
            sendFailure(connected == .success ? 502 : 504, to: host, timing: timing)
            return
        }
        guard write(admitted, to: guest.descriptor, until: .now + .seconds(timing.write)) else { return }
        relay(client, guest: guest, timing: timing)
    }

    private nonisolated static func sendFailure(_ status: Int, to fd: Int32, timing: Timing) {
        let head = "HTTP/1.1 \(status) API unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        _ = write(Data(head.utf8), to: fd, until: .now + .seconds(timing.write))
    }

    private nonisolated static func wait(_ fd: Int32, events: Int16, until deadline: ContinuousClock.Instant) -> Bool {
        while ContinuousClock.now < deadline {
            var item = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&item, 1, 50)
            if result > 0 { return item.revents & Int16(POLLNVAL) == 0 }
            if result < 0, errno != EINTR { return false }
        }
        return false
    }

    private nonisolated static func write(_ bytes: Data, to fd: Int32, until deadline: ContinuousClock.Instant) -> Bool {
        var offset = 0
        return bytes.withUnsafeBytes { raw in
            while offset < bytes.count {
                guard wait(fd, events: Int16(POLLOUT), until: deadline) else { return false }
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    private struct Direction {
        var bytes = Data()
        var eof = false
        var shutDown = false
        var writeDeadline: ContinuousClock.Instant?
    }

    private nonisolated static func relay(_ client: Client, guest: VPhoneAPISocket, timing: Timing) {
        let fds = [client.hostDescriptor, guest.descriptor]
        var directions = [Direction(), Direction()]
        var lastProgress = ContinuousClock.now
        var drainDeadline: ContinuousClock.Instant?
        while !client.isStopped {
            let now = ContinuousClock.now
            if now >= lastProgress + .seconds(timing.idle) || drainDeadline.map({ now >= $0 }) == true { return }
            var polls = fds.map { pollfd(fd: $0, events: 0, revents: 0) }
            for index in 0..<2 {
                if let deadline = directions[index].writeDeadline, now >= deadline { return }
                if !directions[index].eof, directions[index].bytes.isEmpty { polls[index].events |= Int16(POLLIN) }
                if !directions[index].bytes.isEmpty { polls[1-index].events |= Int16(POLLOUT) }
                if directions[index].eof, directions[index].bytes.isEmpty, !directions[index].shutDown {
                    shutdown(fds[1-index], SHUT_WR)
                    directions[index].shutDown = true
                }
            }
            if directions.allSatisfy({ $0.shutDown }) { return }
            for index in 0..<2 where polls[index].events == 0 { polls[index].fd = -1 }
            let count = poll(&polls, 2, 50)
            if count < 0 { if errno == EINTR { continue }; return }
            for index in 0..<2 {
                if polls[index].revents & Int16(POLLERR | POLLNVAL) != 0 { return }
                if !directions[index].eof, directions[index].bytes.isEmpty,
                   polls[index].revents & Int16(POLLIN | POLLHUP) != 0 {
                    var buffer = [UInt8](repeating: 0, count: 32 * 1024)
                    let count = read(fds[index], &buffer, buffer.count)
                    if count > 0 {
                        directions[index].bytes = Data(buffer.prefix(count))
                        directions[index].writeDeadline = .now + .seconds(timing.write)
                        lastProgress = .now
                    } else if count == 0 {
                        directions[index].eof = true
                        if drainDeadline == nil { drainDeadline = .now + .seconds(timing.drain) }
                    } else if errno != EINTR, errno != EAGAIN { return }
                }
                if !directions[index].bytes.isEmpty, polls[1-index].revents & Int16(POLLOUT) != 0 {
                    let written = directions[index].bytes.withUnsafeBytes { Darwin.write(fds[1-index], $0.baseAddress!, $0.count) }
                    if written > 0 {
                        directions[index].bytes.removeFirst(written)
                        directions[index].writeDeadline = directions[index].bytes.isEmpty ? nil : .now + .seconds(timing.write)
                        lastProgress = .now
                    } else if written == 0 || (errno != EINTR && errno != EAGAIN) { return }
                }
            }
        }
    }
}
