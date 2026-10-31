import Darwin
import Foundation

/// Bounded line I/O independent of the VM and its MainActor operations.
enum VPhoneHostAutomationIO {
    static let maximumLength = 1 << 20

    private static func timeout(_ descriptor: Int32, _ option: Int32, until deadline: TimeInterval) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        let micros = max(1, Int(remaining * 1_000_000))
        var value = timeval(tv_sec: micros / 1_000_000, tv_usec: Int32(micros % 1_000_000))
        return setsockopt(descriptor, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<timeval>.size)) == 0
    }

    static func readCommand(from descriptor: Int32, timeout seconds: TimeInterval = 15) -> (line: String, rest: Data)? {
        guard seconds.isFinite, seconds > 0 else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var accumulated = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while accumulated.count < maximumLength {
            guard timeout(descriptor, SO_RCVTIMEO, until: deadline) else { return nil }
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0, accumulated.count + count <= maximumLength else { return nil }
            accumulated.append(contentsOf: buffer[..<count])
            if let newline = accumulated.firstIndex(of: 0x0A) {
                guard let line = String(data: accumulated[..<newline], encoding: .utf8) else { return nil }
                return (line, Data(accumulated[accumulated.index(after: newline)...]))
            }
        }
        return nil
    }

    @discardableResult
    static func write(_ response: Data, to descriptor: Int32, timeout seconds: TimeInterval = 15) -> Bool {
        guard seconds.isFinite, seconds > 0 else { return false }
        let data = response.count <= maximumLength ? response
            : Data("{\"ok\":false,\"error\":\"response exceeds 1 MiB\"}\n".utf8)
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                guard timeout(descriptor, SO_SNDTIMEO, until: deadline) else { return false }
                let count = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}
