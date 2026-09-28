import Darwin
import Foundation
import XCTest
@testable import VPhoneAPIKit

private func proxyTCP(_ port: Int) throws -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw VPhoneAPISocket.failure() }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(port).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard result == 0 else { close(fd); throw VPhoneAPISocket.failure() }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

private func proxyWrite(_ fd: Int32, _ bytes: Data) -> Bool {
    bytes.withUnsafeBytes { raw in
        var offset = 0
        while offset < raw.count {
            let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }
}

private func proxyRead(_ fd: Int32) -> Data {
    var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while true {
        let count = read(fd, &buffer, buffer.count)
        guard count > 0 else {
            if count < 0 { XCTAssertEqual(errno, ECONNRESET, "Read must end with EOF/reset, not a timeout") }
            return data
        }
        data.append(contentsOf: buffer.prefix(count))
    }
}

private func openProxySockets(port: Int) throws -> Int {
    try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").compactMap(Int32.init).filter { fd in
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return result == 0 && address.sin_family == sa_family_t(AF_INET)
            && Int(UInt16(bigEndian: address.sin_port)) == port
    }.count
}

private final class ProxyConnectorFixture: @unchecked Sendable {
    let lock = NSLock()
    var completions: [@Sendable (Result<VPhoneAPISocket, any Error>) -> Void] = []
    func append(_ completion: @escaping @Sendable (Result<VPhoneAPISocket, any Error>) -> Void) {
        lock.withLock { completions.append(completion) }
    }
    var count: Int { lock.withLock { completions.count } }
    func complete(_ result: Result<VPhoneAPISocket, any Error>, index: Int = 0) {
        let completion = lock.withLock { completions[index] }
        completion(result)
    }
}

private final class ProxyBlackHole: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [Int32] = []
    deinit { for fd in peers { close(fd) } }
    func connect(_ completion: @escaping @Sendable (Result<VPhoneAPISocket, any Error>) -> Void) {
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            completion(.failure(VPhoneAPISocket.failure())); return
        }
        var size: Int32 = 1024
        setsockopt(pair[1], SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        lock.withLock { peers.append(pair[1]) }
        completion(Result { try VPhoneAPISocket(takingOwnership: pair[0]) })
    }
}

@MainActor
final class APIProxyTests: XCTestCase {
    let token = "1234567890abcdef"
    func request(_ headers: String = "Authorization: Bearer 1234567890abcdef\r\n") -> Data {
        Data("GET /v1/health HTTP/1.1\r\nHost: localhost\r\n\(headers)\r\n".utf8)
    }

    func testRealHTTPAndWebSocketThroughRelay() async throws {
        let fixture = try await APIHTTPFixture(behindProxy: true)
        defer { fixture.stop() }
        let port = fixture.port
        let proxy = try VPhoneAPIProxy(token: token) { completion in
            DispatchQueue.global().async {
                completion(Result {
                    let fd = try proxyTCP(port)
                    defer { close(fd) }
                    return try VPhoneAPISocket(duplicating: fd)
                })
            }
        }
        defer { proxy.stop() }
        let url = try proxy.start(port: 0)
        let client = try VPhoneAPIClient(baseURL: url, token: token)
        let info = try await client.health(requiredCapabilities: ["files"])
        XCTAssertEqual(info.binaryHash, String(repeating: "a", count: 64))
        let text = String(repeating: "x", count: 512 * 1024)
        let response = try await client.call("echo", params: ["value": .string(text)])
        XCTAssertEqual(response, .object(["value": .string(text)]))
        let socket = client.openWebSocket()
        async let first = socket.call("one")
        async let second = socket.call("two")
        let replies = try await (first, second)
        XCTAssertEqual(replies.0, .string("one"))
        XCTAssertEqual(replies.1, .string("two"))
        await socket.close()
    }

    func testManagedSessionThroughAuthenticatedRelayAndProxyStop() async throws {
        let fixture = try await APIHTTPFixture(behindProxy: true, managedSession: true)
        defer { fixture.stop() }
        let port = fixture.port
        let proxy = try VPhoneAPIProxy(token: token) { completion in
            DispatchQueue.global().async {
                completion(Result { try VPhoneAPISocket(takingOwnership: proxyTCP(port)) })
            }
        }
        defer { proxy.stop() }
        let client = try VPhoneAPIClient(baseURL: proxy.start(port: 0), token: token, timeout: 5)
        let session = VPhoneAPISession(client: client, vmInstanceID: "proxy-runtime")
        defer { session.stop() }
        session.start()
        var deadline = ContinuousClock.now + .seconds(5)
        while session.snapshot.state != .ready, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(session.snapshot.state, .ready)
        let result = try await session.call("files.list", requiring: "files")
        XCTAssertEqual(result, .string("files.list"))
        proxy.stop()
        deadline = ContinuousClock.now + .seconds(5)
        while session.snapshot.state == .ready, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(session.snapshot.state, .reconnecting)
        XCTAssertNil(session.snapshot.health)
        XCTAssertNil(session.snapshot.generation)
    }

    func testRejectedHeadersNeverConnectToGuest() throws {
        let connector = ProxyConnectorFixture()
        let proxy = try VPhoneAPIProxy(token: token, connector: connector.append)
        defer { proxy.stop() }
        let url = try proxy.start(port: 0)
        for headers in ["", "Authorization: Bearer wrong\r\n", "Authorization: Bearer \(token)\r\nOrigin: http://localhost\r\n"] {
            let fd = try proxyTCP(url.port!)
            XCTAssertTrue(proxyWrite(fd, request(headers)))
            let reply = proxyRead(fd)
            close(fd)
            XCTAssertTrue(String(decoding: reply, as: UTF8.self).hasPrefix("HTTP/1.1 401"))
        }
        XCTAssertEqual(connector.count, 0)
    }

    func testConnectFailureAndLateCallbackAreContained() throws {
        let connector = ProxyConnectorFixture()
        let proxy = try VPhoneAPIProxy(token: token, timing: .init(connect: 0.05), connector: connector.append)
        defer { proxy.stop() }
        let fd = try proxyTCP(proxy.start(port: 0).port!)
        defer { close(fd) }
        XCTAssertTrue(proxyWrite(fd, request()))
        XCTAssertTrue(String(decoding: proxyRead(fd), as: UTF8.self).hasPrefix("HTTP/1.1 504"))
        XCTAssertEqual(connector.count, 1)
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let original = pair[0], peer = pair[1]
        defer { close(peer) }
        connector.complete(.success(try VPhoneAPISocket(duplicating: original)))
        close(original)
        var byte: UInt8 = 0
        XCTAssertEqual(read(peer, &byte, 1), 0, "Late connection must be released without forwarding")
    }

    func testConnectFailureReturnsBadGateway() throws {
        let proxy = try VPhoneAPIProxy(token: token) { $0(.failure(URLError(.cannotConnectToHost))) }
        defer { proxy.stop() }
        let fd = try proxyTCP(proxy.start(port: 0).port!)
        defer { close(fd) }
        XCTAssertTrue(proxyWrite(fd, request()))
        XCTAssertTrue(String(decoding: proxyRead(fd), as: UTF8.self).hasPrefix("HTTP/1.1 502"))
    }

    func testAdmissionDeadlineAndStopCloseClients() throws {
        let connector = ProxyConnectorFixture()
        let proxy = try VPhoneAPIProxy(token: token, timing: .init(admission: 0.05), connector: connector.append)
        let url = try proxy.start(port: 0)
        let fd = try proxyTCP(url.port!)
        XCTAssertTrue(proxyWrite(fd, Data("GET /".utf8)))
        XCTAssertTrue(proxyRead(fd).isEmpty)
        close(fd)
        let waiting = try proxyTCP(url.port!)
        proxy.stop()
        XCTAssertTrue(proxyRead(waiting).isEmpty)
        close(waiting)
        XCTAssertEqual(connector.count, 0)
        XCTAssertThrowsError(try proxy.start(port: 0))
    }

    func testConnectionAndUnfinishedAttemptLimits() throws {
        let connector = ProxyConnectorFixture()
        let proxy = try VPhoneAPIProxy(token: token, timing: .init(connect: 0.01), connector: connector.append)
        defer { proxy.stop() }
        let url = try proxy.start(port: 0)
        // Timed-out framework callbacks continue to reserve their attempt slot.
        for _ in 0..<16 {
            let fd = try proxyTCP(url.port!)
            XCTAssertTrue(proxyWrite(fd, request()))
            XCTAssertTrue(String(decoding: proxyRead(fd), as: UTF8.self).hasPrefix("HTTP/1.1 504"))
            close(fd)
        }
        XCTAssertEqual(connector.count, 16)
        let overflow = try proxyTCP(url.port!)
        XCTAssertTrue(proxyWrite(overflow, request()))
        XCTAssertTrue(String(decoding: proxyRead(overflow), as: UTF8.self).hasPrefix("HTTP/1.1 503"))
        close(overflow)
        connector.complete(.failure(URLError(.cancelled)))
        let resumed = try proxyTCP(url.port!)
        XCTAssertTrue(proxyWrite(resumed, request()))
        XCTAssertTrue(String(decoding: proxyRead(resumed), as: UTF8.self).hasPrefix("HTTP/1.1 504"))
        close(resumed)
        XCTAssertEqual(connector.count, 17)
        let deadline = ContinuousClock.now + .seconds(1)
        while try openProxySockets(port: url.port!) > 1, ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(try openProxySockets(port: url.port!), 1,
                       "Only the listener may remain; unreturned callbacks must not retain host fds")
    }

    func testActiveConnectionLimitAndStopDuringConnect() throws {
        let connector = ProxyConnectorFixture()
        let proxy = try VPhoneAPIProxy(token: token, connector: connector.append)
        let url = try proxy.start(port: 0)
        var clients: [Int32] = []
        defer { proxy.stop(); for fd in clients { close(fd) } }
        for _ in 0..<16 {
            let fd = try proxyTCP(url.port!)
            clients.append(fd)
            XCTAssertTrue(proxyWrite(fd, request()))
        }
        let excess = try proxyTCP(url.port!)
        XCTAssertTrue(proxyRead(excess).isEmpty)
        close(excess)
        proxy.stop()
        for fd in clients { XCTAssertTrue(proxyRead(fd).isEmpty) }
    }

    func testGuestBackpressureHasBoundedWriteWait() throws {
        let blackHole = ProxyBlackHole()
        let proxy = try VPhoneAPIProxy(token: token, timing: .init(write: 0.05), connector: blackHole.connect)
        defer { proxy.stop() }
        let fd = try proxyTCP(proxy.start(port: 0).port!)
        defer { close(fd) }
        var bufferSize: Int32 = 4096
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        let data = request("Authorization: Bearer \(token)\r\nContent-Length: 4194304\r\n") + Data(repeating: 65, count: 4 * 1024 * 1024)
        XCTAssertFalse(proxyWrite(fd, data), "The guest never drains its socket; forwarding must terminate")
        XCTAssertTrue(proxyRead(fd).isEmpty)
    }

    func testOwnedSocketDuplicatesAndDisablesSIGPIPE() throws {
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let socket = try VPhoneAPISocket(duplicating: pair[0])
        close(pair[0])
        var enabled: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(getsockopt(socket.descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, &size), 0)
        XCTAssertEqual(enabled, 1)
        XCTAssertNotEqual(fcntl(socket.descriptor, F_GETFD) & FD_CLOEXEC, 0)
        close(pair[1])
        XCTAssertFalse(proxyWrite(socket.descriptor, Data([1])), "Closed peer must report an error without SIGPIPE termination")
    }
}
