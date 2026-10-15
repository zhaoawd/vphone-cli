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
    private var nonce: String?
    private var refused = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !refused else { return }
        switch unwrapInboundIn(data) {
        case let .head(head):
            guard head.uri == "/v1/proxy-admission" else {
                context.fireChannelRead(data)
                context.pipeline.removeHandler(self, promise: nil)
                return
            }
            guard head.method == .GET, head.headers["Host"] == ["vphoned"], head.headers["Origin"].isEmpty,
                  head.headers["Content-Length"] == ["0"], head.headers["Transfer-Encoding"].isEmpty,
                  let value = admission.admit(classes: head.headers["X-Vphone-Proxy-Class"], nonces: head.headers["X-Vphone-Proxy-Nonce"]) else {
                refuse(context); return
            }
            nonce = value
        case let .body(bytes):
            if bytes.readableBytes > 0 { refuse(context) }
        case .end:
            guard let nonce else { refuse(context); return }
            var value = health()
            value["proxy_class"] = "external"; value["proxy_nonce"] = nonce
            guard let body = try? JSONSerialization.data(withJSONObject: value) else { refuse(context); return }
            send(context, status: .ok, body: body, close: false)
            context.pipeline.removeHandler(self, promise: nil)
        }
    }

    private func refuse(_ context: ChannelHandlerContext) {
        refused = true
        send(context, status: .badRequest, body: Data("Invalid external proxy admission".utf8), close: true)
    }

    private func send(_ context: ChannelHandlerContext, status: HTTPResponseStatus, body: Data, close: Bool) {
        let headers = HTTPHeaders([("Content-Length", String(body.count)), ("Connection", close ? "close" : "keep-alive")])
        context.write(NIOAny(HTTPServerResponsePart.head(.init(version: .http1_1, status: status, headers: headers))), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
        let channel = context.channel
        context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
            if close { channel.close(promise: nil) }
        }
    }
}
