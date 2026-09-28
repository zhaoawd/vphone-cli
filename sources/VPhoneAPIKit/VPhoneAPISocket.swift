import Darwin
import Foundation

/// Owns a duplicated descriptor. Retaining a framework connection keeps its
/// original descriptor alive until this relay has stopped using the duplicate.
public final class VPhoneAPISocket: @unchecked Sendable {
    let descriptor: Int32
    private let owner: AnyObject?

    public convenience init(duplicating descriptor: Int32, owner: AnyObject? = nil) throws {
        let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { throw Self.failure() }
        try self.init(takingOwnership: copy, owner: owner)
    }

    init(takingOwnership descriptor: Int32, owner: AnyObject? = nil) throws {
        var one: Int32 = 1
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            close(descriptor)
            throw Self.failure()
        }
        self.descriptor = descriptor
        self.owner = owner
    }

    deinit { close(descriptor) }
    func shutDown() { shutdown(descriptor, SHUT_RDWR) }
    static func failure() -> VPhoneAPIError {
        VPhoneAPIError(code: "socket", message: "API socket operation failed")
    }
}
