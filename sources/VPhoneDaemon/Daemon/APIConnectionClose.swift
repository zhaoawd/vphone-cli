import NIOCore

// MARK: - Closing

// Source: upstream 1df6c43c (APIWire.swift `closeAfterPeer`). Kept in a
// NIOCore-only file so the close behavior can be compiled without IcliKit.

extension Channel {
    /// Ends a VSOCK connection whose last write has been flushed. XNU's vsock
    /// answers close() and shutdown() with an immediate RESET or SHUTDOWN and
    /// drops bytes still queued for host credit; upstream observed replies of
    /// about 8 to 16 KiB truncated that way. The host closes after reading the
    /// reply, and NIO then closes this channel on EOF. The timer only covers a
    /// host that never closes.
    ///
    /// Local difference from upstream: bytes read after the final reply are
    /// discarded before decoding. The host proxy checks only the first request
    /// head of a connection. A request that NIO decoded before this point is
    /// refused by GuestHyperTextHandler, which answers it so that
    /// HTTPServerPipelineHandler resumes reads and the host EOF is still seen.
    func closeAfterPeer(fallback: TimeAmount = .seconds(30)) {
        let channel = self
        let close: @Sendable () -> Void = {
            guard channel.isActive else { return }
            let sync = channel.pipeline.syncOperations
            // A refused follow-up request calls this again; keep one timer.
            guard (try? sync.handler(type: APIDiscardAfterReply.self)) == nil else { return }
            do {
                try sync.addHandler(APIDiscardAfterReply(), position: .first)
            } catch {
                channel.close(promise: nil)
                return
            }
            let timer = channel.eventLoop.scheduleTask(in: fallback) {
                channel.close(promise: nil)
            }
            channel.closeFuture.whenComplete { _ in timer.cancel() }
            // EOF is only seen while reading, and a relay may have paused reads.
            _ = channel.setOption(ChannelOptions.autoRead, value: true)
        }
        if eventLoop.inEventLoop {
            close()
        } else {
            eventLoop.execute(close)
        }
    }
}

/// Drops inbound bytes once the final reply is written. EOF and errors still
/// reach the channel, so the peer's close ends the connection.
final class APIDiscardAfterReply: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer

    func channelRead(context _: ChannelHandlerContext, data _: NIOAny) {}
}
