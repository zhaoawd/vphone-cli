import Darwin
import Foundation

/// Publish a completed file without overwriting an existing path or following a symlink.
enum VPhoneArchiveOutput {
    static func publish<Result>(to output: URL, write: (URL) throws -> Result) throws -> Result {
        var info = stat()
        if lstat(output.path, &info) == 0 {
            throw VPhoneArchiveError.writeFailed(path: output.path, reason: "destination already exists")
        }
        guard errno == ENOENT else {
            throw VPhoneArchiveError.cannotOpen(path: output.path, reason: String(cString: strerror(errno)))
        }
        let staging = output.deletingLastPathComponent().appendingPathComponent(".vphone-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        let temporary = staging.appendingPathComponent("output")
        let result = try write(temporary)
        // Same-filesystem link publishes exclusively; EEXIST never removes another caller's path.
        guard link(temporary.path, output.path) == 0 else {
            throw VPhoneArchiveError.writeFailed(path: output.path, reason: String(cString: strerror(errno)))
        }
        return result
    }
}
