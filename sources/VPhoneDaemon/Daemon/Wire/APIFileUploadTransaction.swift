import Darwin
import Foundation

/// Shared by the NIO upload handler and firmware-free filesystem tests.
final class APIFileUploadTransaction {
    static let maximumBytes: Int64 = 64 * 1024 * 1024
    let descriptor: Int32
    let destination: String
    private let directory: String
    private let temporary: String
    private let expectedBytes: Int64?
    private let mode: mode_t
    private(set) var size: Int64 = 0
    private var cancelled = false
    private var committed = false

    static func validateIdentity(instance: String?, hash: String?, length: String?,
                                 expectedInstance: String, expectedHash: String) throws -> Int64 {
        guard let instance, let identity = UUID(uuidString: instance),
              identity == UUID(uuidString: expectedInstance), hash == expectedHash,
              let length, !length.isEmpty, length.utf8.allSatisfy({ (48...57).contains($0) }),
              let bytes = Int64(length), (0...maximumBytes).contains(bytes) else { throw Failure.invalidRequest }
        return bytes
    }

    init(destination: String, expectedBytes: Int64?, mode: mode_t) throws {
        guard destination.hasPrefix("/"), !destination.contains("\0"), !destination.hasSuffix("/"),
              mode <= 0o777, expectedBytes.map({ (0...Self.maximumBytes).contains($0) }) ?? true else {
            throw Failure.invalidRequest
        }
        let parent = (destination as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        var template = Array((parent + "/.vphoned-upload-XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw Failure.io }
        directory = String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self)
        temporary = directory + "/content"
        descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { rmdir(directory); throw Failure.io }
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.mode = mode
    }

    /// Call on the channel event loop before scheduling each write.
    func reserve(_ count: Int) throws -> Int64 {
        guard !cancelled, !committed, count >= 0,
              Int64(count) <= (expectedBytes ?? Self.maximumBytes) - size else { throw Failure.invalidRequest }
        let start = size
        size += Int64(count)
        return start
    }

    func cancel() { cancelled = true }

    /// All asynchronous writes must have completed successfully before commit.
    func commit() throws {
        guard !cancelled, !committed, expectedBytes == nil || expectedBytes == size else { throw Failure.invalidRequest }
        guard fsync(descriptor) == 0, fchmod(descriptor, mode) == 0,
              rename(temporary, destination) == 0 else { throw Failure.io }
        committed = true
    }

    deinit { close(descriptor); unlink(temporary); rmdir(directory) }

    enum Failure: Error { case invalidRequest, io }
}
