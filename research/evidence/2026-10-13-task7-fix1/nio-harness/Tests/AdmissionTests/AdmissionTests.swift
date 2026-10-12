import XCTest
import Foundation
import NIOCore
import NIOHTTP1
import NIOWebSocket
import NIOEmbedded
@testable import Admission

final class HTTPFallback: ChannelInboundHandler {
 typealias InboundIn = HTTPServerRequestPart
 func channelRead(context: ChannelHandlerContext, data: NIOAny) {
  if case .end = unwrapInboundIn(data) {
   context.write(NIOAny(HTTPServerResponsePart.head(.init(version: .http1_1, status: .ok, headers: ["Content-Length": "0"]))), promise: nil)
   context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
  }
 }
}
final class AdmissionTests: XCTestCase {
 func testActualNIOPreflightDoesNotConsumeWebSocketUpgradeOpportunity() throws {
  let channel = EmbeddedChannel(), admission = GuestProxyAdmission()
  let upgrader = NIOWebSocketServerUpgrader(shouldUpgrade: { c, _ in c.eventLoop.makeSucceededFuture(HTTPHeaders()) }, upgradePipelineHandler: { c, _ in c.eventLoop.makeSucceededFuture(()) })
  try channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in })).wait()
  let upgrade = try channel.pipeline.syncOperations.handler(type: HTTPServerUpgradeHandler.self)
  try channel.pipeline.syncOperations.addHandler(GuestProxyAdmissionHandler(admission: admission, health: { ["fixture": true] }), position: .before(upgrade))
  try channel.pipeline.syncOperations.addHandler(HTTPFallback())
  var first = channel.allocator.buffer(capacity: 200)
  first.writeString("GET /v1/proxy-admission HTTP/1.1\r\nHost: vphoned\r\nX-Vphone-Proxy-Class: external\r\nX-Vphone-Proxy-Nonce: 01234567-1234-1234-1234-0123456789ab\r\nContent-Length: 0\r\n\r\n")
  try channel.writeInbound(first)
  while let _: ByteBuffer = try channel.readOutbound() {}
  var next = channel.allocator.buffer(capacity: 200)
  next.writeString("GET /v1/events HTTP/1.1\r\nHost: vphoned\r\nConnection: upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n")
  try channel.writeInbound(next)
  channel.embeddedEventLoop.run()
  var output = ""
  while var bytes: ByteBuffer = try channel.readOutbound() { output += bytes.readString(length: bytes.readableBytes) ?? "" }
  XCTAssertTrue(output.contains("101 Switching Protocols"), output)
  XCTAssertTrue(admission.external)
  _ = try channel.finish(acceptAlreadyClosed: true)
 }
}
