import Darwin
import Foundation

public struct VPhoneTransferProgress: Codable, Equatable, Sendable {
    public enum Direction: String, Codable, Sendable { case importArchive, exportArchive }
    public let version: Int
    public let direction: Direction
    public let completed: Bool
    public let bytes: Int64
    public let total: Int64?

    public init(direction: Direction, bytes: Int64, total: Int64?, completed: Bool = false) {
        version = 1; self.direction = direction; self.bytes = bytes; self.total = total; self.completed = completed
    }

    public var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(bytes) / Double(total))
    }

    public static func decode(_ line: Data) -> Self? {
        guard let value = try? JSONDecoder().decode(Self.self, from: line), value.version == 1,
              value.bytes >= 0, value.total.map({ $0 >= value.bytes }) ?? true else { return nil }
        return value
    }
}

/// A private optional diagnostics channel. Neither a missing reader nor a
/// progress write failure can cancel or establish success of the data operation.
public final class VPhoneTransferProgressChannel {
    public static let environmentKey = "VPHONE_TRANSFER_PROGRESS_FILE"
    private let directory: URL
    public let file: URL
    private let direction: VPhoneTransferProgress.Direction
    private var previous: VPhoneTransferProgress?
    private var closed = false

    public init(parent: URL, direction: VPhoneTransferProgress.Direction) throws {
        directory = parent.appendingPathComponent(".transfer-progress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        file = directory.appendingPathComponent("progress.jsonl")
        self.direction = direction
    }

    public var environment: [String: String] {
        ProcessInfo.processInfo.environment.merging([Self.environmentKey: file.path]) { _, new in new }
    }

    public func read() -> VPhoneTransferProgress? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return previous }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { return previous }
        let start = max(0, info.st_size - 65536)
        guard lseek(fd, start, SEEK_SET) >= 0 else { return previous }
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(fd, &buffer, buffer.count)
        guard count > 0 else { return previous }
        let data = Data(buffer.prefix(count))
        // Ignore the unfinished last line and any truncated first line.
        let lines = data.split(separator: 10, omittingEmptySubsequences: false)
        for line in lines.dropLast().dropFirst(start > 0 ? 1 : 0) {
            guard let value = VPhoneTransferProgress.decode(Data(line)), value.direction == direction,
                  value.bytes >= (previous?.bytes ?? 0), previous?.completed != true else { continue }
            previous = value
        }
        return previous
    }

    public func close() {
        guard !closed else { return }; closed = true
        try? FileManager.default.removeItem(at: directory)
    }
    deinit { close() }
}

/// JSONL goes to an exclusively created regular file, never a pipe. Closing
/// the reader cannot produce SIGPIPE. Callbacks remain best effort.
public final class VPhoneTransferProgressReporter {
    private let fd: Int32
    private let direction: VPhoneTransferProgress.Direction
    private let lock = NSLock()
    private var lastWrite = ContinuousClock.now
    private var previous: Int64 = -1
    private var disabled = false

    public init?(direction: VPhoneTransferProgress.Direction, environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let path = environment[VPhoneTransferProgressChannel.environmentKey], path.hasPrefix("/") else { return nil }
        fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { Darwin.close(fd); return nil }
        self.direction = direction
    }

    public func update(bytes: Int64, total: Int64?, completed: Bool = false) {
        lock.withLock {
            guard !disabled, bytes >= previous, bytes >= 0, total.map({ $0 >= bytes }) ?? true else { return }
            let now = ContinuousClock.now
            guard previous < 0 || completed || lastWrite.duration(to: now) >= .milliseconds(100) else { return }
            guard var data = try? JSONEncoder().encode(VPhoneTransferProgress(direction: direction, bytes: bytes, total: total, completed: completed)) else { return }
            data.append(10)
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written != data.count { disabled = true }
            previous = bytes; lastWrite = now
        }
    }

    deinit { Darwin.close(fd) }
}
