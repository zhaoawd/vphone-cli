import Darwin

/// A queued frame owns a duplicate, so disconnect/reconnect cannot reuse its
/// descriptor number for another connection. The framework owns the original.
final class VPhoneCameraWriteLease: Sendable {
    let fileDescriptor: Int32
    private init(_ descriptor: Int32) { fileDescriptor = descriptor }
    static func acquire(_ descriptor: Int32) -> VPhoneCameraWriteLease? {
        let owned = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        return owned >= 0 ? VPhoneCameraWriteLease(owned) : nil
    }
    static func isCurrent(failedDescriptor: Int32, failedConnection: UInt64, failedSource: UInt64,
                          currentDescriptor: Int32, currentConnection: UInt64, currentSource: UInt64) -> Bool {
        failedDescriptor >= 0 && failedDescriptor == currentDescriptor &&
            failedConnection == currentConnection && failedSource == currentSource
    }
    deinit { close(fileDescriptor) }
}
