import Foundation
import NIOCore
import NIOPosix

private final class GuestPipeOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var transferred = false

    func transfer() { lock.lock(); transferred = true; lock.unlock() }
    func closeIfRetained(input: Int32, output: Int32) {
        lock.lock()
        let retained = !transferred
        lock.unlock()
        if retained { close(input); close(output) }
    }
}

/// Consumes both descriptors on every outcome. Pinned NIO 2.83.0 returns them
/// on construction failure, but closes them on initializer/registration failure.
func makeGuestPipeChannel(
    input: Int32, output: Int32, group: EventLoopGroup,
    initialize: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
) -> EventLoopFuture<Channel> {
    let ownership = GuestPipeOwnership()
    let loop = group.next()
    // Construct on this loop so scheduling failure precedes channel creation.
    // No channel options are applied: after construction the first operation
    // is this initializer, before any fallible initializer or registration.
    return loop.flatSubmit {
        NIOPipeBootstrap(group: loop).channelInitializer { channel in
            ownership.transfer()
            return initialize(channel)
        }.takingOwnershipOfDescriptors(input: input, output: output)
    }.flatMapError { error in
        ownership.closeIfRetained(input: input, output: output)
        return loop.makeFailedFuture(error)
    }
}
