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
    deinit { close(fileDescriptor) }
}
