import Darwin
import Foundation

public enum VPhoneLibraryLockError: Error, CustomStringConvertible {
    case unavailable(String, Int32)
    /// The lock was still held when the acquisition budget ran out.
    case busy(String)

    public var description: String {
        switch self {
        case let .unavailable(path, code):
            return "VM library lock unavailable at \(path): \(String(cString: strerror(code)))"
        case let .busy(path):
            return "VM library lock at \(path) is held by another operation"
        }
    }
}

// MARK: - VPhoneLibraryLockProbe

/// Non-destructive probe for the library-root lock, mirroring
/// `VPhoneVMLockProbe`.
public enum VPhoneLibraryLockProbe {
    public static func isLockHeld(root: URL) -> Bool {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
        _ = flock(fd, LOCK_UN)
        return false
    }
}

// MARK: - VPhoneLibraryLock

/// Exclusive lock on the library root inode: the name space, not one bundle.
///
/// A bundle lock cannot protect `create` or `import`, because at check time the
/// bundle directory does not exist yet. Two creators of the same name would
/// both pass `fileExists` and then race on `createDirectory` / `moveItem`. This
/// lock makes the existence check and the placement one lifetime.
///
/// Unlike `VPhoneVMLock` it writes no runtime record: the library root is not a
/// bundle, and a record there would be picked up by nothing that reads bundle
/// records.
///
/// Acquisition retries instead of failing immediately. Holders are short
/// (a sparse disk file plus two ROM copies for `create`; a same-filesystem
/// rename for `import`), and two concurrent creates of *different* names must
/// both succeed rather than one reporting a spurious conflict. When two
/// creators do want the same name, the loser gets in after the winner and
/// reports `alreadyExists` — the answer that describes the actual state.
public final class VPhoneLibraryLock {
    /// Total time spent waiting for the lock before giving up.
    public static let defaultTimeout: TimeInterval = 10
    static let pollInterval: TimeInterval = 0.02

    let descriptor: Int32
    public let root: URL

    public convenience init(root: URL) throws {
        try self.init(root: root, timeout: Self.defaultTimeout)
    }

    init(root: URL, timeout: TimeInterval, sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws {
        // The root must exist to be locked; creating it is part of every
        // operation that takes this lock anyway.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        let fd = open(resolved.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw VPhoneLibraryLockError.unavailable(resolved.path, errno) }
        var waited: TimeInterval = 0
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { break }
            let code = errno
            guard code == EWOULDBLOCK || code == EAGAIN || code == EINTR else {
                close(fd)
                throw VPhoneLibraryLockError.unavailable(resolved.path, code)
            }
            guard waited < timeout else {
                close(fd)
                throw VPhoneLibraryLockError.busy(resolved.path)
            }
            sleep(Self.pollInterval)
            waited += Self.pollInterval
        }
        descriptor = fd
        self.root = resolved
    }

    deinit {
        // Explicit unlock first: a descriptor duplicated into a concurrently
        // spawned child would otherwise keep the lease alive (see VPhoneVMLock).
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
