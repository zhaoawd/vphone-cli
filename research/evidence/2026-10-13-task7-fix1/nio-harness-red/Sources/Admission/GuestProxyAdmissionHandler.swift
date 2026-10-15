import Foundation
import NIOCore
import NIOHTTP1

/// Consumes the one-use external proxy preflight before NIO's first-request
/// upgrade handler, so the original request can still upgrade to WebSocket.
final class GuestProxyAdmissionHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias InboundOut = HTTPServerRequestPart
    let admission: GuestProxyAdmission
    let health: () -> [String: Any]
    init(admission: GuestProxyAdmission, health: @escaping () -> [String: Any]) {
        self.admission = admission; self.health = health
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { context.fireChannelRead(data) }
}
