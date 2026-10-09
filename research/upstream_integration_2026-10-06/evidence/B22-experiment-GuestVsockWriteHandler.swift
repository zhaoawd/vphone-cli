import NIOCore

/// XNU/VZ VSOCK acceptance: a burst of 64 KiB nonblocking writes can report
/// success while the peer receives fewer or different bytes. The B22 native
/// socket probe receives complete matching data with 8 KiB writes. Serialize
/// those writes at the wire boundary so HTTP/WebSocket encoders cannot combine
/// them into a larger writev. A caller's promise covers every chunk.
final class GuestVsockWriteHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private struct Pending {
        var bytes: ByteBuffer
        let promise: EventLoopPromise<Void>?
    }
    private var pending: [Pending] = []
    private var flushed = 0
    private var writing = false
    private var closed = false

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard !closed else { promise?.fail(ChannelError.ioOnClosedChannel); return }
        pending.append(Pending(bytes: unwrapOutboundIn(data), promise: promise))
    }

    func flush(context: ChannelHandlerContext) {
        flushed = pending.count
        drain(context)
    }

    private func drain(_ context: ChannelHandlerContext) {
        guard !closed, !writing, flushed > 0, !pending.isEmpty else { return }
        guard let part = pending[0].bytes.readSlice(length: min(8192, pending[0].bytes.readableBytes)) else { return }
        writing = true
        let complete = context.eventLoop.makePromise(of: Void.self)
        let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
        complete.futureResult.whenComplete { [self] result in
            let context = bound.value
            writing = false
            guard !closed else { return }
            switch result {
            case .success:
                if pending[0].bytes.readableBytes == 0 {
                    let first = pending.removeFirst()
                    flushed -= 1
                    first.promise?.succeed(())
                }
                // Leave NIO's current flush before issuing the next chunk;
                // otherwise its pending-write manager can gather the chunks.
                context.eventLoop.execute { [self] in drain(bound.value) }
            case let .failure(error):
                failPending(error)
                context.close(promise: nil)
            }
        }
        context.writeAndFlush(wrapOutboundOut(part), promise: complete)
    }

    private func failPending(_ error: any Error) {
        closed = true
        let queued = pending
        pending.removeAll()
        flushed = 0
        for entry in queued { entry.promise?.fail(error) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        failPending(ChannelError.ioOnClosedChannel)
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        failPending(ChannelError.ioOnClosedChannel)
    }
}
