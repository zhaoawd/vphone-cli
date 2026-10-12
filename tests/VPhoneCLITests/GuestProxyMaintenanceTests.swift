import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import VPhoneAPIKit
@testable import VPhoneDaemonWire
import VPhoneCore
@testable import vphone_cli

private final class ProxyMaintenancePeer: @unchecked Sendable {
    enum Probe { case valid, old, malformed, missingInstance, wrongNonce, disconnected }
    let probe: Probe
    let holdInternal: Bool
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let lock = NSLock()
    private var requests: [String] = [], mutations: [String] = []
    func waitEntered() -> Bool { entered.wait(timeout: .now() + 3) == .success }
    var received: [String] { lock.withLock { requests } }
    var changed: [String] { lock.withLock { mutations } }
    let instance = UUID().uuidString
    init(probe: Probe = .old, holdInternal: Bool = false) { self.probe = probe; self.holdInternal = holdInternal }
    var health: [String: Any] { ["status": "ok", "api_version": 1, "ios": "26.0", "binary_hash": String(repeating: "a", count: 64), "instance_id": instance,
        "capabilities": ["session_identity", "bootstrap_install", "system_shutdown", "clipboard", "files", GuestProxyAdmission.capability]] }

    func connect(_ completion: @escaping @Sendable (Result<VPhoneAPISocket, any Error>) -> Void) {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { completion(.failure(URLError(.cannotConnectToHost))); return }
        completion(Result { try VPhoneAPISocket(takingOwnership: pair[0]) })
        let fd = pair[1]
        DispatchQueue.global().async {
            defer { close(fd) }
            var timeout = timeval(tv_sec: 5, tv_usec: 0), one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            self.serve(fd)
        }
    }
    func serve(_ fd: Int32) {
        let admission = GuestProxyAdmission()
        while let head = Self.readHead(fd) {
            lock.withLock { requests.append(head) }
            let lines = head.components(separatedBy: "\r\n")
            func values(_ name: String) -> [String] { lines.filter { $0.lowercased().hasPrefix(name.lowercased() + ":") }.map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) } }
            if head.hasPrefix("GET /v1/proxy-admission ") {
                guard let nonce = admission.admit(classes: values("X-Vphone-Proxy-Class"), nonces: values("X-Vphone-Proxy-Nonce")), probe != .disconnected else { return }
                var value = health
                value["proxy_class"] = "external"; value["proxy_nonce"] = nonce
                if probe == .old { value["capabilities"] = [] }
                if probe == .missingInstance { value.removeValue(forKey: "instance_id") }
                if probe == .wrongNonce { value["proxy_nonce"] = UUID().uuidString }
                if probe == .malformed { _ = Self.write(fd, Data("HTTP/1.1 200 OK\r\nContent-Length: 7\r\n\r\n{bad".utf8)); return }
                Self.reply(fd, value, keepAlive: true)
                continue
            }
            guard admission.consumeRequest() else { Self.reply(fd, ["error": "One request per connection"]); return }
            if values("Upgrade").first?.lowercased() == "websocket" {
                guard let key = values("Sec-WebSocket-Key").first else { return }
                let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
                _ = Self.write(fd, Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(Data(digest).base64EncodedString())\r\n\r\n".utf8))
                Self.frame(fd, ["type": "event", "event": "connected", "data": health])
                while let frame = Self.readFrame(fd) {
                    if frame.opcode == 8 { _ = Self.write(fd, Data([0x88, 0])); return }
                    guard frame.opcode == 1, let request = try? JSONSerialization.jsonObject(with: frame.data) as? [String: Any] else { continue }
                    Self.frame(fd, execute(request, external: admission.external))
                }
                return
            }
            let count = values("Content-Length").first.flatMap(Int.init) ?? 0
            guard let data = Self.readBytes(fd, count) else { return }
            if head.hasPrefix("GET /v1/health ") { Self.reply(fd, health) }
            else if let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { Self.reply(fd, execute(request, external: admission.external)) }
            else { Self.reply(fd, ["media": "fixture-frame"]) }
            // Consume later bytes only to prove the same production admission
            // object refuses another HTTP request; normal daemon replies close.
        }
    }
    func execute(_ request: [String: Any], external: Bool) -> [String: Any] {
        let method = request["method"] as? String ?? "", id = request["id"] ?? NSNull()
        do {
            let value: [String: Any] = try GuestMaintenanceGate().run(method: method, externalProxy: external) { () -> [String: Any] in
                if GuestMaintenanceGate.writers.contains(method) {
                    lock.withLock { mutations.append(method) }
                    if holdInternal { entered.signal(); _ = release.wait(timeout: .now() + 5) }
                }
                return method == "agent.health" ? health : ["method": method]
            }
            return ["type": "response", "id": id, "result": value]
        } catch { return ["type": "response", "id": id, "error": ["code": "operation_failed", "message": String(describing: error)]] }
    }
    static func reply(_ fd: Int32, _ value: [String: Any], keepAlive: Bool = false) {
        let body = try! JSONSerialization.data(withJSONObject: value)
        let head = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        _ = write(fd, Data(head.utf8) + body)
    }
    static func write(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { return false }; offset += count
            }
            return true
        }
    }
    static func readBytes(_ fd: Int32, _ count: Int) -> Data? {
        guard count >= 0, count <= 1 << 20 else { return nil }
        var result = Data()
        while result.count < count {
            var bytes = [UInt8](repeating: 0, count: count - result.count)
            let n = read(fd, &bytes, bytes.count)
            guard n > 0 else { return nil }; result.append(contentsOf: bytes.prefix(n))
        }
        return result
    }
    static func readHead(_ fd: Int32) -> String? {
        var data = Data()
        while data.count < 32768 {
            guard let byte = readBytes(fd, 1) else { return nil }; data.append(byte)
            if data.suffix(4) == Data("\r\n\r\n".utf8) { return String(data: data, encoding: .utf8) }
        }
        return nil
    }
    static func frame(_ fd: Int32, _ value: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: value)
        var head = Data([0x81])
        if data.count < 126 { head.append(UInt8(data.count)) }
        else { head.append(contentsOf: [126, UInt8(data.count >> 8), UInt8(data.count & 255)]) }
        _ = write(fd, head + data)
    }
    static func readFrame(_ fd: Int32) -> (opcode: UInt8, data: Data)? {
        guard let header = readBytes(fd, 2) else { return nil }
        var count = Int(header[1] & 127)
        if count == 126 { guard let extended = readBytes(fd, 2) else { return nil }; count = Int(extended[0]) * 256 + Int(extended[1]) }
        guard count < 65536 else { return nil }
        let masked = header[1] & 128 != 0
        guard let mask = readBytes(fd, masked ? 4 : 0), let data = readBytes(fd, count) else { return nil }
        return (header[0] & 15, masked ? Data(data.enumerated().map { $0.element ^ mask[$0.offset % 4] }) : data)
    }
}

@MainActor
final class GuestProxyMaintenanceTests: XCTestCase {
    func testExternalMaintenanceMustProbeSameSocketBeforeForwarding() async throws {
        let peer = ProxyMaintenancePeer()
        let proxy = try VPhoneAPIProxy(token: "1234567890abcdef", connector: peer.connect)
        defer { proxy.stop() }
        let url = try proxy.start(port: 0)
        let client = try VPhoneAPIClient(baseURL: url, token: "1234567890abcdef", timeout: 3)
        do { _ = try await client.call("bootstrap.install"); XCTFail("external maintenance accepted") } catch {}
        let request = try XCTUnwrap(peer.received.first)
        XCTAssertTrue(request.hasPrefix("GET /v1/proxy-admission HTTP/1.1"), request)
        XCTAssertTrue(request.lowercased().contains("x-vphone-proxy-class: external"))
        XCTAssertEqual(peer.received.count, 1)
    }
    func testExternalHTTPAndWebSocketMaintenanceRefuseWhileReadsAndMediaProceed() async throws {
        let peer = ProxyMaintenancePeer(probe: .valid)
        let proxy = try VPhoneAPIProxy(token: "1234567890abcdef", connector: peer.connect)
        defer { proxy.stop() }
        let url = try proxy.start(port: 0)
        let client = try VPhoneAPIClient(baseURL: url, token: "1234567890abcdef", timeout: 3)
        let socket = client.openWebSocket()
        defer { Task { await socket.close() } }
        for method in GuestMaintenanceGate.writers.sorted() {
            for ws in [false, true] {
                do {
                    if ws { _ = try await socket.call(method) } else { _ = try await client.call(method) }
                    XCTFail("external maintenance accepted: \(method)")
                } catch let error as VPhoneAPIError {
                    XCTAssertTrue(error.message.contains("host RPC or CLI"), error.message)
                }
            }
        }
        _ = try await client.health()
        _ = try await client.call("device.info")
        _ = try await socket.call("device.info")
        var request = URLRequest(url: url.appendingPathComponent("v1/media"))
        request.setValue("Bearer 1234567890abcdef", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("fixture-frame"))
        XCTAssertTrue(peer.changed.isEmpty)
    }

    func testEachExternalConnectionRequalifiesAndOldUnknownOrIncompleteProbeNeverForwards() async throws {
        for probe in [ProxyMaintenancePeer.Probe.old, .malformed, .missingInstance, .wrongNonce, .disconnected] {
            let peer = ProxyMaintenancePeer(probe: probe)
            let proxy = try VPhoneAPIProxy(token: "1234567890abcdef", connector: peer.connect)
            let url = try proxy.start(port: 0)
            let client = try VPhoneAPIClient(baseURL: url, token: "1234567890abcdef", timeout: 3)
            for _ in 0..<2 { do { _ = try await client.call("bootstrap.install"); XCTFail("unqualified peer forwarded") } catch {} }
            XCTAssertEqual(peer.received.count, 2)
            XCTAssertTrue(peer.received.allSatisfy { $0.hasPrefix("GET /v1/proxy-admission ") })
            XCTAssertTrue(peer.changed.isEmpty)
            proxy.stop()
        }
    }

    func testInternalActualSessionAndRPCWriterHoldStopLeaseWhileExternalIsRefused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-stop-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = ProxyMaintenancePeer(probe: .valid, holdInternal: true)
        let proxy = try VPhoneAPIProxy(token: "1234567890abcdef", connector: peer.connect)
        defer { peer.release.signal(); proxy.stop() }
        let url = try proxy.start(port: 0)
        let session = VPhoneAPISession(client: try VPhoneAPIClient(baseURL: url, token: proxy.internalToken, timeout: 3), vmInstanceID: UUID().uuidString)
        session.start()
        defer { session.stop() }
        let deadline = ContinuousClock.now + .seconds(3)
        while session.snapshot.state != .ready, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(session.snapshot.state, .ready)
        let writes = VPhoneGuestWriteCoordinator(directory: root)
        let executor = VPhoneHostCommandExecutor(apiSession: session, guestWrites: writes)
        let request = try JSONSerialization.data(withJSONObject: ["t": "rpc", "method": "bootstrap.install"])
        let writer = Task { await executor.execute(request) }
        let entered = await Task.detached { peer.waitEntered() }.value
        XCTAssertTrue(entered)
        var signals = 0
        let stopper = VPhoneVMStopper(listTargets: { [123] }, identity: { _ in VPhoneProcessIdentity(pid: 123, startedAt: 1, uid: getuid()) },
            send: { _, _ in signals += 1; return 0 }, lockHeld: { true }, sleep: { _ in }, acquireOnlineOperation: { try VPhoneOnlineOperationLock(directory: root) })
        for force in [false, true] { XCTAssertEqual(stopper.stop(timeout: 0, force: force).exitCode, 1) }
        XCTAssertEqual(signals, 0)
        let external = try VPhoneAPIClient(baseURL: url, token: "1234567890abcdef", timeout: 3)
        do { _ = try await external.call("system.shutdown"); XCTFail("external shutdown accepted") } catch {}
        _ = try await external.call("device.info")
        XCTAssertEqual(peer.changed, ["bootstrap.install"])
        peer.release.signal()
        let data = await writer.value
        let reply = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let released = try VPhoneOnlineOperationLock(directory: root)
        withExtendedLifetime(released) {}
    }

    func testForgedClassificationAndLaterHTTPHeadCannotElevateExternalConnection() async throws {
        let peer = ProxyMaintenancePeer(probe: .valid)
        let proxy = try VPhoneAPIProxy(token: "1234567890abcdef", connector: peer.connect)
        defer { proxy.stop() }
        let url = try proxy.start(port: 0), port = try XCTUnwrap(url.port)
        let reply = try await Task.detached { () throws -> String in
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(port).bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard connected == 0 else { throw URLError(.cannotConnectToHost) }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let body = #"{"id":"one","method":"device.info","params":{}}"#
            let next = #"{"id":"two","method":"bootstrap.install","params":{}}"#
            let request = "POST /v1/rpc HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer 1234567890abcdef\r\nX-Vphone-Proxy-Class: internal\r\nx-vphone-proxy-class: internal\r\nX-Vphone-Proxy-Nonce: forged\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body + "POST /v1/rpc HTTP/1.1\r\nHost: vphoned\r\nX-Vphone-Proxy-Class: internal\r\nContent-Length: \(next.utf8.count)\r\n\r\n" + next
            guard ProxyMaintenancePeer.write(fd, Data(request.utf8)) else { throw URLError(.networkConnectionLost) }
            var output = Data(), bytes = [UInt8](repeating: 0, count: 4096)
            while true { let n = read(fd, &bytes, bytes.count); if n <= 0 { break }; output.append(contentsOf: bytes.prefix(n)) }
            return String(decoding: output, as: UTF8.self)
        }.value
        XCTAssertTrue(reply.contains("One request per connection"))
        XCTAssertTrue(peer.changed.isEmpty)
        let first = try XCTUnwrap(peer.received.dropFirst().first)
        XCTAssertFalse(first.lowercased().contains("x-vphone-proxy-class:"))
        XCTAssertFalse(first.lowercased().contains("x-vphone-proxy-nonce:"))
    }

}
