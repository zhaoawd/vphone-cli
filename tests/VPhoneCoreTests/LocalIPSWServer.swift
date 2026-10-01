import Darwin
import Foundation

/// A loopback HTTP/1.1 server for IPSW download tests: one payload, `Range`
/// and `If-Range` against a strong ETag, and scripted faults. Every response
/// closes its connection. Nothing leaves 127.0.0.1.
final class LocalIPSWServer: @unchecked Sendable {
    enum Fault: Sendable {
        /// Full Content-Length in the headers, then only this many body bytes.
        case drop(after: Int)
        /// This status with an empty body.
        case status(Int)
        /// As `drop`, then the entity is replaced (new bytes, new ETag).
        case dropThenReplace(after: Int, payload: Data)
        /// The body in 1 KiB pieces every 20 ms.
        case slow
    }

    struct Request: Sendable {
        let range: String?
        let ifRange: String?
        let status: Int
    }

    private let lock = NSLock()
    private var payloadValue: Data
    private var etagValue = "\"payload-1\""
    private var faults: [Fault]
    private var log: [Request] = []
    private var stopped = false
    private let ranges: Bool
    private let listener: Int32
    let port: UInt16

    init(payload: Data, faults: [Fault] = [], ranges: Bool = true) throws {
        payloadValue = payload
        self.faults = faults
        self.ranges = ranges
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0, named == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        listener = fd
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    deinit { stop() }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/iPhone17,3_26.1_23B85_Restore.ipsw")! }

    var requests: [Request] { lock.withLock { log } }

    /// Replaces the entity: new bytes and a new ETag.
    func replace(payload: Data) {
        lock.withLock {
            payloadValue = payload
            etagValue = "\"payload-\(UUID().uuidString.prefix(8))\""
        }
    }

    var etag: String { lock.withLock { etagValue } }

    func stop() {
        let first = lock.withLock { () -> Bool in
            defer { stopped = true }
            return !stopped
        }
        if first { close(listener) }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func acceptLoop() {
        while !isStopped {
            var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 100) > 0, !isStopped else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var head = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while head.range(of: Data("\r\n\r\n".utf8)) == nil {
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else { return }
            head.append(contentsOf: chunk[0 ..< count])
        }
        var headers: [String: String] = [:]
        for line in String(decoding: head, as: UTF8.self).components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let (fault, payload, etag) = lock.withLock { () -> (Fault?, Data, String) in
            (faults.isEmpty ? nil : faults.removeFirst(), payloadValue, etagValue)
        }
        if case let .status(code) = fault {
            lock.withLock { log.append(Request(range: headers["range"], ifRange: headers["if-range"], status: code)) }
            send(client, "HTTP/1.1 \(code) Fault\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            return
        }
        var start = 0
        if ranges, let range = headers["range"], range.hasPrefix("bytes="), range.hasSuffix("-"),
           let offset = Int(range.dropFirst(6).dropLast()), offset < payload.count,
           headers["if-range"] == nil || headers["if-range"] == etag
        {
            start = offset
        }
        let partial = headers["range"] != nil && start > 0
        lock.withLock { log.append(Request(range: headers["range"], ifRange: headers["if-range"], status: partial ? 206 : 200)) }
        var response = partial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        response += "Content-Length: \(payload.count - start)\r\nETag: \(etag)\r\nConnection: close\r\n"
        if ranges { response += "Accept-Ranges: bytes\r\n" }
        if partial { response += "Content-Range: bytes \(start)-\(payload.count - 1)/\(payload.count)\r\n" }
        guard send(client, response + "\r\n") else { return }
        let body = payload[(payload.startIndex + start)...]
        switch fault {
        case let .drop(after):
            send(client, Data(body.prefix(after)))
        case let .dropThenReplace(after, replacement):
            send(client, Data(body.prefix(after)))
            replace(payload: replacement)
        case .slow:
            var offset = body.startIndex
            while offset < body.endIndex, !isStopped {
                let end = min(offset + 1024, body.endIndex)
                guard send(client, Data(body[offset ..< end])) else { return }
                offset = end
                usleep(20000)
            }
        default:
            send(client, Data(body))
        }
    }

    @discardableResult
    private func send(_ client: Int32, _ text: String) -> Bool {
        send(client, Data(text.utf8))
    }

    @discardableResult
    private func send(_ client: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = write(client, bytes.baseAddress! + offset, bytes.count - offset)
                if written <= 0 { return false }
                offset += written
            }
            return true
        }
    }
}
