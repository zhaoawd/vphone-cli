import Darwin
import Foundation

/// Client side of the per-VM host-control socket (`<bundle>/vphone.sock`):
/// one request line out, one LF-terminated response line back, then close.
/// Protocol constraints: research/host_control_protocol_e1_2026-09-11.md.
public enum HostControlClient {
    /// Largest response line the server can produce. A classic `file_get`
    /// without `save` inlines up to 64 MiB of guest data (the `file_data`
    /// payload cap in `VPhoneControl`, equal to `HostControlIO.maximumFileBytes`)
    /// as base64, and JSONSerialization writes every "/" as "\/", so the worst
    /// case is twice the base64 length. 1 MiB covers the remaining fields.
    public static let maximumResponseBytes = 2 * ((HostControlIO.maximumFileBytes + 2) / 3 * 4) + 1024 * 1024

    public enum Failure: Error, Equatable, Sendable {
        /// The path does not fit `sockaddr_un.sun_path` (NUL included), or contains NUL.
        case pathTooLong(bytes: Int, maximum: Int)
        case missing
        case notSocket
        case notOwned(uid: uid_t)
        case inspectFailed(errno: Int32)
        case connectFailed(errno: Int32)
        case writeFailed(errno: Int32)
        case readFailed(errno: Int32)
        case timedOut
        /// EOF before the first LF; `receivedBytes` counts what arrived.
        case closedBeforeLine(receivedBytes: Int)
        case responseTooLarge(limit: Int)
    }

    // MARK: - Exchange

    /// Sends `request` plus LF and returns the response line without its LF.
    /// `timeout` bounds connect, write and read together on one monotonic
    /// deadline; bytes after the first LF are ignored.
    public static func exchange(socketPath: String, request: Data, timeout: TimeInterval,
                                limit: Int = maximumResponseBytes) throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let path = Array(socketPath.utf8)
        guard !path.contains(0), path.count < capacity else {
            throw Failure.pathTooLong(bytes: path.count, maximum: capacity - 1)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path)
            buffer[path.count] = 0
        }

        var info = stat()
        guard lstat(socketPath, &info) == 0 else {
            throw errno == ENOENT || errno == ENOTDIR ? Failure.missing : Failure.inspectFailed(errno: errno)
        }
        guard info.st_mode & S_IFMT == S_IFSOCK else { throw Failure.notSocket }
        guard info.st_uid == geteuid() else { throw Failure.notOwned(uid: info.st_uid) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.connectFailed(errno: errno) }
        defer { close(fd) }
        HostControlIO.configure(fd)

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EINTR else { throw Failure.connectFailed(errno: errno) }
            try wait(fd, for: Int16(POLLOUT), until: deadline, failure: Failure.connectFailed)
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else {
                throw Failure.connectFailed(errno: errno)
            }
            guard error == 0 else { throw Failure.connectFailed(errno: error) }
        }

        try send(request + Data([10]), to: fd, until: deadline)
        return try receiveLine(fd, until: deadline, limit: limit)
    }

    // MARK: - I/O

    private static func send(_ data: Data, to fd: Int32, until deadline: TimeInterval) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                try wait(fd, for: Int16(POLLOUT), until: deadline, failure: Failure.writeFailed)
                let count = write(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw Failure.writeFailed(errno: errno)
                }
                offset += count
            }
        }
    }

    private static func receiveLine(_ fd: Int32, until deadline: TimeInterval, limit: Int) throws -> Data {
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            try wait(fd, for: Int16(POLLIN), until: deadline, failure: Failure.readFailed)
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw Failure.readFailed(errno: errno)
            }
            if count == 0 { throw Failure.closedBeforeLine(receivedBytes: line.count) }
            let chunk = buffer[..<count]
            let newline = chunk.firstIndex(of: 10)
            let bytes = newline.map { chunk[..<$0] } ?? chunk
            guard bytes.count <= limit - line.count else { throw Failure.responseTooLarge(limit: limit) }
            line.append(contentsOf: bytes)
            if newline != nil { return line }
        }
    }

    /// Waits until `fd` reports `event` (or an error/hangup, which the next
    /// syscall surfaces) before the shared deadline.
    private static func wait(_ fd: Int32, for event: Int16, until deadline: TimeInterval,
                             failure: (Int32) -> Failure) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw Failure.timedOut }
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
            if result < 0 {
                if errno == EINTR { continue }
                throw failure(errno)
            }
            if result > 0 && descriptor.revents != 0 { return }
        }
    }
}
