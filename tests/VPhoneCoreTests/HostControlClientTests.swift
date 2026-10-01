import Darwin
import Foundation
import XCTest
@testable import VPhoneCore

/// One-connection Unix-socket server on its own thread. Every wait is bounded,
/// so a client bug fails the test instead of hanging the suite (T25 note:
/// blocking socket I/O must stay off the cooperative pool).
final class ClientStubServer: @unchecked Sendable {
    let directory: URL
    let path: String
    private let listener: Int32
    private let finished = DispatchGroup()
    private let lock = NSLock()
    private var request = Data()
    private var stopped = false

    /// Bytes read up to and including the first LF (or until EOF).
    var received: Data { lock.withLock { request } }

    init(socketPath: String? = nil, respond: @escaping @Sendable (Int32) -> Void) throws {
        if let socketPath {
            path = socketPath
            directory = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        } else {
            directory = URL(fileURLWithPath: "/tmp/vcc-" + UUID().uuidString.prefix(8))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            path = directory.appendingPathComponent("s.sock").path
        }
        listener = try Self.listen(at: path)
        let listener = listener
        finished.enter()
        Thread { [self] in
            defer { finished.leave() }
            var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, 10_000) > 0 else { return }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            var enabled: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            var limit = timeval(tv_sec: 5, tv_usec: 0)
            _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while !data.contains(10) {
                let count = read(client, &buffer, buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer[..<count])
            }
            lock.withLock { request = data }
            respond(client)
        }.start()
    }

    static func listen(at path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else { close(fd); throw CocoaError(.fileWriteUnknown) }
        return fd
    }

    @discardableResult
    func wait(seconds: Double = 10) -> Bool { finished.wait(timeout: .now() + seconds) == .success }

    /// Waits for the server thread, then removes the socket directory. Idempotent.
    func stop() {
        wait()
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            close(listener)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    static func send(_ text: String, to fd: Int32) {
        _ = text.withCString { write(fd, $0, strlen($0)) }
    }

    /// Keeps the connection open without answering until the peer closes it.
    static func holdUntilPeerCloses(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 256)
        while read(fd, &buffer, buffer.count) > 0 {}
    }
}

final class HostControlClientTests: XCTestCase {
    private let request = Data(#"{"t":"capabilities"}"#.utf8)

    private func exchange(_ server: ClientStubServer, timeout: TimeInterval = 5,
                          limit: Int = HostControlClient.maximumResponseBytes) throws -> Data {
        try HostControlClient.exchange(socketPath: server.path, request: request, timeout: timeout, limit: limit)
    }

    private func assertFailure(_ expected: HostControlClient.Failure, _ body: () throws -> Data,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? HostControlClient.Failure, expected, file: file, line: line)
        }
    }

    func testRoundTripSendsPayloadPlusLF() throws {
        let server = try ClientStubServer { ClientStubServer.send("{\"ok\":true}\n", to: $0) }
        defer { server.stop() }
        XCTAssertEqual(try exchange(server), Data(#"{"ok":true}"#.utf8))
        server.wait()
        XCTAssertEqual(server.received, request + Data([10]))
    }

    func testResponseSplitAcrossWritesAndTrailingBytesIgnored() throws {
        let server = try ClientStubServer { fd in
            for part in ["{\"ok\"", ":tr", "ue,\"x\":\"中", "\"}\n{\"ignored\":1}\n"] {
                ClientStubServer.send(part, to: fd)
                Thread.sleep(forTimeInterval: 0.02)
            }
        }
        defer { server.stop() }
        XCTAssertEqual(try exchange(server), Data(#"{"ok":true,"x":"中"}"#.utf8))
    }

    func testCloseWithoutBytes() throws {
        let server = try ClientStubServer { _ in }
        defer { server.stop() }
        assertFailure(.closedBeforeLine(receivedBytes: 0)) { try exchange(server) }
    }

    func testCloseAfterBytesWithoutLF() throws {
        let server = try ClientStubServer { ClientStubServer.send("{\"ok\":true}", to: $0) }
        defer { server.stop() }
        assertFailure(.closedBeforeLine(receivedBytes: 11)) { try exchange(server) }
    }

    func testSilentServerHitsDeadline() throws {
        let server = try ClientStubServer { fd in
            ClientStubServer.send("{\"ok\"", to: fd)
            ClientStubServer.holdUntilPeerCloses(fd)
        }
        defer { server.stop() }
        let started = ProcessInfo.processInfo.systemUptime
        assertFailure(.timedOut) { try exchange(server, timeout: 0.3) }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertGreaterThanOrEqual(elapsed, 0.29)
        XCTAssertLessThan(elapsed, 3)
    }

    func testTricklingBytesDoNotExtendDeadline() throws {
        let server = try ClientStubServer { fd in
            // Stops once the client has closed (write fails with EPIPE).
            for _ in 0..<60 where write(fd, "a", 1) == 1 { Thread.sleep(forTimeInterval: 0.05) }
        }
        defer { server.stop() }
        let started = ProcessInfo.processInfo.systemUptime
        assertFailure(.timedOut) { try exchange(server, timeout: 0.3) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1.5)
    }

    func testResponseLimitExcludesLF() throws {
        let exact = try ClientStubServer { ClientStubServer.send(String(repeating: "a", count: 8) + "\n", to: $0) }
        XCTAssertEqual(try exchange(exact, limit: 8).count, 8)
        exact.stop()

        let over = try ClientStubServer { ClientStubServer.send(String(repeating: "a", count: 4096) + "\n", to: $0) }
        defer { over.stop() }
        assertFailure(.responseTooLarge(limit: 1024)) { try exchange(over, limit: 1024) }
    }

    func testPathChecksBeforeConnecting() throws {
        let directory = URL(fileURLWithPath: "/tmp/vcc-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        assertFailure(.missing) {
            try HostControlClient.exchange(socketPath: directory.appendingPathComponent("none.sock").path,
                                           request: self.request, timeout: 1)
        }
        let regular = directory.appendingPathComponent("file.sock")
        try Data().write(to: regular)
        assertFailure(.notSocket) {
            try HostControlClient.exchange(socketPath: regular.path, request: self.request, timeout: 1)
        }
        let long = "/tmp/" + String(repeating: "x", count: 200) + "/vphone.sock"
        assertFailure(.pathTooLong(bytes: long.utf8.count, maximum: 103)) {
            try HostControlClient.exchange(socketPath: long, request: self.request, timeout: 1)
        }
    }

    func testStaleSocketIsRefused() throws {
        let directory = URL(fileURLWithPath: "/tmp/vcc-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("s.sock").path
        close(try ClientStubServer.listen(at: path))
        assertFailure(.connectFailed(errno: ECONNREFUSED)) {
            try HostControlClient.exchange(socketPath: path, request: self.request, timeout: 1)
        }
    }

    func testSocketOwnedByAnotherUserIsRefused() throws {
        // mDNSResponder's socket is root-owned on stock macOS; nothing is sent.
        let path = "/var/run/mDNSResponder"
        var info = stat()
        guard geteuid() != 0, lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid != geteuid() else {
            throw XCTSkip("no socket owned by another user at \(path)")
        }
        assertFailure(.notOwned(uid: info.st_uid)) {
            try HostControlClient.exchange(socketPath: path, request: self.request, timeout: 1)
        }
    }

    func testDefaultLimitCoversWorstCaseInlineFile() {
        // Escaped base64 of the largest guest file the classic file_get inlines.
        let base64 = (HostControlIO.maximumFileBytes + 2) / 3 * 4
        XCTAssertGreaterThan(HostControlClient.maximumResponseBytes, 2 * base64)
        let escaped = try! JSONSerialization.data(withJSONObject: ["data": Data([255, 255, 255]).base64EncodedString()])
        XCTAssertEqual(String(decoding: escaped, as: UTF8.self), #"{"data":"\/\/\/\/"}"#)
    }
}
