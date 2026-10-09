import Foundation
import NIOCore
import NIOWebSocket

final class GuestWebSocketHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let hub: APIEventHub
    private var closing = false
    init(hub: APIEventHub) {
        self.hub = hub
    }

    func handlerAdded(context: ChannelHandlerContext) {
        hub.add(context.channel)
        let hello = APIReply.json(["type": "event", "event": "connected", "data": GuestAPI.health()])
        Self.send(hello.data, on: context.channel)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        // Frames decoded after a close frame are not executed.
        guard !closing else { return }
        switch frame.opcode {
        case .text:
            var buffer = frame.unmaskedData
            guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
            do {
                let request = try APIWire.decode(Data(bytes))
                let job = WebSocketJob(channel: context.channel, request: request, hub: hub)
                GuestAPI.queue.async { job.run() }
            } catch {
                let reply = APIReply.json(["type": "response", "id": NSNull(),
                                           "error": ["code": "bad_request", "message": String(describing: error)]])
                Self.send(reply.data, on: context.channel)
            }
        case .ping:
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .connectionClose:
            // Echo the close and let the host drop the connection, so replies
            // still queued ahead of this frame reach it. Events are not sent
            // after the close frame.
            closing = true
            let channel = context.channel
            hub.remove(channel)
            let echo = WebSocketFrame(fin: true, opcode: .connectionClose, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(echo)).whenComplete { _ in
                channel.closeAfterPeer()
            }
        default:
            break
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        hub.remove(context.channel)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error _: Error) {
        context.close(promise: nil)
    }

    fileprivate static func send(_ data: Data, on channel: Channel) {
        let write: @Sendable () -> Void = {
            guard channel.isActive else { return }
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            channel.writeAndFlush(WebSocketFrame(fin: true, opcode: .text, data: buffer), promise: nil)
        }
        if channel.eventLoop.inEventLoop {
            write()
        } else {
            channel.eventLoop.execute(write)
        }
    }
}

private final class WebSocketJob: @unchecked Sendable {
    let channel: Channel
    let request: APIRequest
    let hub: APIEventHub

    init(channel: Channel, request: APIRequest, hub: APIEventHub) {
        self.channel = channel
        self.request = request
        self.hub = hub
    }

    func run() {
        let reply = APIWire.execute(request)
        GuestWebSocketHandler.send(reply.data, on: channel)
        if reply.status == 200 {
            hub.broadcast(name: "operation.completed", data: ["method": request.method])
        }
    }
}
