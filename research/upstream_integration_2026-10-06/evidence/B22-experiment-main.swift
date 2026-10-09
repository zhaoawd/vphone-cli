import NIOCore
import NIOEmbedded
import NIOConcurrencyHelpers
import Foundation

final class TransportBoundary: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = ByteBuffer
    var buffers: [ByteBuffer] = []
    var completions: [EventLoopPromise<Void>?] = []
    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        buffers.append(unwrapOutboundIn(data)); completions.append(promise)
    }
}
func require(_ yes: Bool, _ message: String) { if !yes { fatalError(message) } }
let mode = CommandLine.arguments.last!
let gate = TransportBoundary()
let channel = EmbeddedChannel(handler: gate)
#if GUARDED_VSOCK
try channel.pipeline.addHandler(GuestVsockWriteHandler()).wait()
#endif
let payload = Array((0..<1048576).map { UInt8($0 % 251) })
var source = channel.allocator.buffer(capacity: payload.count); source.writeBytes(payload)
let done = channel.eventLoop.makePromise(of: Void.self)
let completion = NIOLockedValueBox(false)
done.futureResult.whenComplete { _ in completion.withLockedValue { $0 = true } }
channel.writeAndFlush(source, promise: done)
require(!completion.withLockedValue { $0 }, "reply completed before transport completion")
if mode == "close" {
    try channel.close().wait()
    channel.embeddedEventLoop.run()
    require(completion.withLockedValue { $0 }, "closed transport retained the reply promise")
    for p in gate.completions { p?.fail(ChannelError.ioOnClosedChannel) }
    channel.embeddedEventLoop.run()
} else {
    var output: [UInt8] = []; var index = 0
    while index < gate.buffers.count {
        var part = gate.buffers[index]
        require(part.readableBytes <= 8192, "VSOCK nonblocking write exceeded the verified 8 KiB boundary")
        output += part.readBytes(length: part.readableBytes)!
        gate.completions[index]?.succeed(())
        channel.embeddedEventLoop.run(); index += 1
    }
    require(output == payload, "byte ordering or response tail changed")
    require(completion.withLockedValue { $0 }, "complete reply was not acknowledged")
    try channel.close().wait()
}
print("VSOCK boundary, output and completion: passed \(mode)")
