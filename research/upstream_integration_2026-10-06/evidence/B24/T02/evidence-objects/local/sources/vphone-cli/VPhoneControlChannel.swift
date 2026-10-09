import Darwin
import Foundation

/// Owns a duplicate for one session. In-flight I/O retains this object, so the
/// descriptor cannot be recycled until all readers and writers have returned.
final class VPhoneControlChannel: @unchecked Sendable {
    let fileDescriptor: Int32
    let readTimeout: TimeInterval

    init(duplicating fd: Int32, readTimeout: TimeInterval) throws {
        self.readTimeout = readTimeout
        fileDescriptor = dup(fd)
        guard fileDescriptor >= 0 else { throw POSIXError(.EBADF) }
        var enabled: Int32 = 1
        setsockopt(fileDescriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        fcntl(fileDescriptor, F_SETFD, FD_CLOEXEC)
    }

    func shutdown() { Darwin.shutdown(fileDescriptor, SHUT_RDWR) }
    deinit { Darwin.close(fileDescriptor) }
}
