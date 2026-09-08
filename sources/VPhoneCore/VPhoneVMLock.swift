import Darwin
import Foundation

public enum VPhoneVMLockError: Error, CustomStringConvertible {
    case unavailable(String, Int32)

    public var description: String {
        switch self {
        case let .unavailable(path, code):
            return "VM lock unavailable at \(path): \(String(cString: strerror(code)))"
        }
    }
}

// MARK: - VPhoneVMLockProbe

/// Non-destructive liveness probe for a VM bundle.
///
/// `VPhoneVMLock` cannot serve as a probe: acquiring it rewrites
/// `.vphone-runtime.json` with the probing process. This takes the same
/// directory flock directly and releases it immediately, leaving the record of
/// the real holder intact.
public enum VPhoneVMLockProbe {
    /// True when some process holds the bundle directory's exclusive flock.
    public static func isLockHeld(directory: URL) -> Bool {
        let directory = directory.resolvingSymlinksInPath().standardizedFileURL
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
        _ = flock(fd, LOCK_UN)
        return false
    }
}

// MARK: - VPhoneVMLock

/// Locks the directory inode; deleting a diagnostic/lock file cannot bypass it.
/// Hold this object for the entire operation. Child boot processes acquire their
/// own lock; ordinary subprocesses must not inherit this descriptor.
public final class VPhoneVMLock {
    let descriptor: Int32
    public let state: VPhoneVMRuntimeState

    public init(directory: URL, operation: String) throws {
        let directory = directory.resolvingSymlinksInPath().standardizedFileURL
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw VPhoneVMLockError.unavailable(directory.path, errno) }
        do {
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                throw VPhoneVMLockError.unavailable(directory.path, errno)
            }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw VPhoneVMLockError.unavailable(directory.path, errno) }
            let record = VPhoneVMRuntimeState(
                bundleIdentifier: "\(info.st_dev):\(info.st_ino)", bundlePath: directory.path,
                pid: getpid(), instanceID: UUID().uuidString, startedAt: Date(), operation: operation)
            do {
                try record.write(in: directory)
            } catch {
                let message = "[vphone] Warning: runtime record could not be written: \(error)\n"
                FileHandle.standardError.write(Data(message.utf8))
            }
            descriptor = fd
            state = record
        } catch {
            _ = flock(fd, LOCK_UN)
            close(fd)
            throw error
        }
    }

    deinit {
        // End the lease explicitly, including transient descriptor duplicates
        // in concurrently spawned children before their close-on-exec runs.
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
