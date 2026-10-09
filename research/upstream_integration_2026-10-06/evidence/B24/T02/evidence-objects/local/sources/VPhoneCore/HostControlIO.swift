import Darwin
import Foundation

/// One UTF-8 JSON object per connection, terminated by LF or EOF.
public enum HostControlIO {
    public static let maximumRequestBytes = 2 * 1024 * 1024
    public static let maximumInlineBytes = 1024 * 1024
    public static let maximumFileBytes = 64 * 1024 * 1024
    public static let maximumConnections = 16

    public enum Failure: String, Error {
        case requestTooLarge = "request_too_large"
        case readTimeout = "read_timeout"
        case invalidJSON = "invalid_json"
        case ioError = "io_error"
        case fileTooLarge = "file_too_large"
    }

    public static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
    }

    private static func ready(_ fd: Int32, event: Int16, deadline: TimeInterval) -> Bool {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, Double(Int32.max))))
            if result < 0 && errno == EINTR { continue }
            return result > 0 && descriptor.revents & (event | Int16(POLLHUP)) != 0
        }
    }

    public static func readRequest(_ fd: Int32, timeout: TimeInterval = 5,
                                   limit: Int = maximumRequestBytes) throws -> Data? {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var accumulated = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            guard ready(fd, event: Int16(POLLIN), deadline: deadline) else { throw Failure.readTimeout }
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw Failure.ioError
            }
            if count == 0 { return accumulated.isEmpty ? nil : accumulated }
            let chunk = buffer[..<count]
            let newline = chunk.firstIndex(of: 10)
            let bytes = newline.map { chunk[..<$0] } ?? chunk
            guard bytes.count <= limit - accumulated.count else { throw Failure.requestTooLarge }
            accumulated.append(contentsOf: bytes)
            if newline != nil { return accumulated }
        }
    }

    public static func decodeRequest(_ data: Data) throws -> [String: Any] {
        guard String(data: data, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["t"] is String else { throw Failure.invalidJSON }
        return object
    }

    public static func writeResponse(_ data: Data, to fd: Int32, timeout: TimeInterval = 5) {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                guard ready(fd, event: Int16(POLLOUT), deadline: deadline) else { return }
                let count = write(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { return }
                offset += count
            }
        }
    }

    public static func loadFile(_ path: String) throws -> Data {
        let fd = open(path, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.ioError }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.ioError }
        guard info.st_size <= maximumFileBytes else { throw Failure.fileTooLarge }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Failure.ioError }
            if count == 0 { return output }
            guard count <= maximumFileBytes - output.count else { throw Failure.fileTooLarge }
            output.append(contentsOf: buffer[..<count])
        }
    }
}
