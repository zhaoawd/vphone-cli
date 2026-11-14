import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOWebSocket

@main
enum RPCErrorRelayTests {
    static func main() throws {
        var failures = 0
        func expect(_ name: String, _ passed: Bool) {
            if !passed { print("FAIL: \(name)"); failures += 1 }
        }

        func relayClose(guestSide: Bool, sent: String?) throws -> String {
            let loop = EmbeddedEventLoop()
            #if LEGACY_RELAY
            let relay = ByteRelay(connection: VZVirtioSocketConnection())
            #else
            let relay = ByteRelay(connection: VZVirtioSocketConnection(), repliesWhenEmpty: guestSide)
            #endif
            let sender = EmbeddedChannel(handler: relay, loop: loop)
            let receiver = EmbeddedChannel(loop: loop)
            let address = try SocketAddress(ipAddress: "127.0.0.1", port: 12345)
            try sender.connect(to: address).wait()
            try receiver.connect(to: address).wait()
            relay.peer = receiver
            if let sent { try sender.writeInbound(ByteBuffer(string: sent)) }
            try sender.close().wait()
            loop.run()
            var reply = ""
            while let bytes = try receiver.readOutbound(as: ByteBuffer.self) {
                reply += String(decoding: bytes.readableBytesView, as: UTF8.self)
            }
            _ = try sender.finish(acceptAlreadyClosed: true)
            _ = try receiver.finish(acceptAlreadyClosed: true)
            return reply
        }

        let emptyGuestReply = try relayClose(guestSide: true, sent: nil)
        expect("guest close before a reply produces an HTTP 502",
               emptyGuestReply == String(decoding: VPhoneAPIRequestGate.guestClosedResponse, as: UTF8.self))
        let partial = "HTTP/1.1 200 OK\r\n"
        let partialReply = try relayClose(guestSide: true, sent: partial)
        expect("guest close after a reply preserves the bytes already sent", partialReply == partial)
        let emptyHostReply = try relayClose(guestSide: false, sent: nil)
        expect("host close does not synthesize a guest reply", emptyHostReply.isEmpty)

        func handshake(version: String, keys: [String], allowed: Bool = true) throws -> String {
            let loop = EmbeddedEventLoop()
            let channel = EmbeddedChannel(loop: loop)
            let upgrader = NIOWebSocketServerUpgrader(
                shouldUpgrade: { channel, _ in channel.eventLoop.makeSucceededFuture(allowed ? HTTPHeaders() : nil) },
                upgradePipelineHandler: { channel, _ in channel.eventLoop.makeSucceededFuture(()) },
            )
            try channel.pipeline.configureHTTPServerPipeline(
                withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }),
            ).wait()
            try channel.pipeline.addHandler(UpgradeFallback()).wait()
            try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 12345)).wait()
            let keyHeaders = keys.map { "Sec-WebSocket-Key: \($0)\r\n" }.joined()
            let request = "GET /v1/events HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\n" +
                "Upgrade: websocket\r\nSec-WebSocket-Version: \(version)\r\n\(keyHeaders)\r\n"
            do { try channel.writeInbound(ByteBuffer(string: request)) } catch let error as ChannelError {
                guard error == .ioOnClosedChannel else { throw error }
            }
            loop.run()
            var reply = ""
            while let bytes = try channel.readOutbound(as: ByteBuffer.self) {
                reply += String(decoding: bytes.readableBytesView, as: UTF8.self)
            }
            _ = try channel.finish(acceptAlreadyClosed: true)
            return reply
        }

        let key = "dGhlIHNhbXBsZSBub25jZQ=="
        let wrongVersion = try handshake(version: "12", keys: [key])
        expect("wrong WebSocket version reaches the HTTP fallback", wrongVersion.hasPrefix("HTTP/1.1 426 "))
        let missingKey = try handshake(version: "13", keys: [])
        expect("missing WebSocket key reaches the HTTP fallback", missingKey.hasPrefix("HTTP/1.1 426 "))
        let duplicateKey = try handshake(version: "13", keys: [key, key])
        expect("duplicate WebSocket key reaches the HTTP fallback", duplicateKey.hasPrefix("HTTP/1.1 426 "))
        let refused = try handshake(version: "13", keys: [key], allowed: false)
        expect("refused WebSocket upgrade reaches the HTTP fallback", refused.hasPrefix("HTTP/1.1 426 "))
        let valid = try handshake(version: "13", keys: [key])
        expect("valid WebSocket upgrade returns 101", valid.hasPrefix("HTTP/1.1 101 "))
        print("RPC error relay: \(8 - failures)/8 passed")
        if failures != 0 { exit(1) }
    }
}
