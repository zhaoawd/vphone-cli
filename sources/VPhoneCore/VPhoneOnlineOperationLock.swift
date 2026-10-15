import Darwin
import Foundation

/// A separate, nonblocking lease shared by a running VM's guest writers and
/// the external Stop command. It never takes or releases the VM lifetime lock.
public final class VPhoneOnlineOperationLock {
    public static let filename = ".vphone-online-operation.lock"
    private let descriptor: Int32

    public init(directory: URL) throws {
        let directory = directory.resolvingSymlinksInPath().standardizedFileURL
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw VPhoneMachineBindingError("Cannot open online operation directory") }
        defer { close(parent) }
        let fd = openat(parent, Self.filename, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw VPhoneMachineBindingError("Cannot open online operation lock") }
        do {
            var info = stat(), linked = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
                  fstatat(parent, Self.filename, &linked, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_dev == linked.st_dev, info.st_ino == linked.st_ino else {
                throw VPhoneMachineBindingError("Unsafe online operation lock")
            }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                throw VPhoneMachineBindingError("VM guest write operation is busy; no Stop signal was sent")
            }
            guard fstatat(parent, Self.filename, &linked, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_dev == linked.st_dev, info.st_ino == linked.st_ino else {
                throw VPhoneMachineBindingError("Online operation lock path changed during acquisition")
            }
            descriptor = fd
        } catch { close(fd); throw error }
    }

    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
