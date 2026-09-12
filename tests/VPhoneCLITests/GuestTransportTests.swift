import Darwin
import Foundation
import XCTest
@testable import vphone_cli

private final class GuestPeer: @unchecked Sendable {
    let fd: Int32
    init(_ fd: Int32) {
        self.fd = fd
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
    }
    deinit { Darwin.close(fd) }
    func stop() { shutdown(fd, SHUT_RDWR) }
    func write(_ data: Data, fragment: Int = Int.max) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress! + offset, min(fragment, bytes.count - offset))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw POSIXError(.EIO) }
                offset += n
            }
        }
    }
    func read(_ count: Int) throws -> Data {
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let n = Darwin.read(fd, bytes.baseAddress! + offset, count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw POSIXError(.EIO) }
                offset += n
            }
        }
        return result
    }
    func readFrame() throws -> Data {
        let header = try read(4)
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0 && length <= 4 * 1024 * 1024 else { throw POSIXError(.EINVAL) }
        return try read(length)
    }
    static func frame(_ json: Data) -> Data {
        var size = UInt32(json.count).bigEndian
        return withUnsafeBytes(of: &size) { Data($0) } + json
    }
    func send(_ fields: [String: Any], payload: Data = Data(), fragment: Int = Int.max) throws {
        try write(Self.frame(JSONSerialization.data(withJSONObject: fields)) + payload, fragment: fragment)
    }
}

@MainActor
private final class GuestSession {
    let control: VPhoneControl
    var peer: GuestPeer
    init(timing: VPhoneControl.Timing = .init()) throws {
        control = VPhoneControl(variant: .regular, timing: timing)
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        peer = GuestPeer(fds[1])
        defer { Darwin.close(fds[0]) }
        try control.connect(fileDescriptor: fds[0])
    }
    func ready() async throws {
        let peer = peer
        try await Task.detached {
            _ = try peer.readFrame()
            try peer.send(["v": 1, "t": "hello", "name": "test", "caps": ["file", "shell"]], fragment: 1)
        }.value
        for _ in 0..<500 {
            if control.isConnected { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw POSIXError(.ETIMEDOUT)
    }
    func readRequest() async throws -> [String: Any] {
        let peer = peer
        let data = try await Task.detached { try peer.readFrame() }.value
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    func replaceConnection() async throws {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw POSIXError(.EIO) }
        defer { Darwin.close(fds[0]) }
        let nextPeer = GuestPeer(fds[1])
        try control.connect(fileDescriptor: fds[0])
        peer.stop()
        peer = nextPeer
        try await ready()
    }
    func stop() { control.close(); peer.stop() }
}

@MainActor
final class GuestTransportTests: XCTestCase {
    func testFourMiBResponseIsAcceptedLikeGuestProtocol() async throws {
        let session = try GuestSession()
        defer { session.stop() }
        try await session.ready()
        let request = Task { try await session.control.sendVersion() }
        let fields = try await session.readRequest()
        let id = try XCTUnwrap(fields["id"] as? String)
        let prefix = "{\"v\":1,\"t\":\"version\",\"id\":\"\(id)\",\"hash\":\""
        let count = 4 * 1024 * 1024 - prefix.utf8.count - 2
        let json = Data((prefix + String(repeating: "x", count: count) + "\"}").utf8)
        let peer = session.peer
        try await Task.detached { try peer.write(GuestPeer.frame(json), fragment: 997) }.value
        let hash = try await request.value
        XCTAssertEqual(hash.count, count)
    }
    func testUnknownPayloadAndDuplicateIDDoNotCorruptNextResponse() async throws {
        let session = try GuestSession(timing: .init(request: 0.3))
        defer { session.stop() }
        try await session.ready()
        let request = Task { try await session.control.sendVersion() }
        let fields = try await session.readRequest()
        let id = try XCTUnwrap(fields["id"] as? String)
        let peer = session.peer
        try await Task.detached {
            try peer.send(["v": 1, "t": "file_data", "id": "unknown", "size": 8], payload: Data(repeating: 255, count: 8))
            try peer.send(["v": 1, "t": "version", "id": id, "hash": "first"])
            try peer.send(["v": 1, "t": "clipboard_get", "id": id, "has_image": true, "image_size": 4], payload: Data([0, 0, 0, 0]))
        }.value
        let value = try await request.value
        XCTAssertEqual(value, "first")
        let next = Task { try await session.control.sendPing() }
        let nextFields = try await session.readRequest()
        try peer.send(["v": 1, "t": "pong", "id": try XCTUnwrap(nextFields["id"])])
        try await next.value
        XCTAssertTrue(session.control.isConnected)
    }

    func testTaskCancellationReturnsBeforeTimeoutAndLatePayloadIsDrained() async throws {
        let session = try GuestSession(timing: .init(request: 0.5))
        defer { session.stop() }
        try await session.ready()
        let request = Task { try await session.control.downloadFile(path: "/slow") }
        let fields = try await session.readRequest()
        let start = ContinuousClock.now
        request.cancel()
        do { _ = try await request.value; XCTFail("expected cancellation") }
        catch let error as VPhoneControl.ControlError {
            guard case .cancelled = error else { XCTFail("unexpected error: \(error)"); return }
        }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(200))
        let peer = session.peer
        try peer.send(["v": 1, "t": "file_data", "id": try XCTUnwrap(fields["id"]), "size": 5], payload: Data("hello".utf8))
        let ping = Task { try await session.control.sendPing() }
        let next = try await session.readRequest()
        try peer.send(["v": 1, "t": "pong", "id": try XCTUnwrap(next["id"])])
        try await ping.value
    }

    func testPartialPayloadKeepsRequestTimeoutAndBoundsReaderLifetime() async throws {
        let session = try GuestSession(timing: .init(request: 0.05, transfer: 0.2))
        defer { session.stop() }
        try await session.ready()
        let request = Task { try await session.control.downloadFile(path: "/partial") }
        let fields = try await session.readRequest()
        try session.peer.send(["v": 1, "t": "file_data", "id": try XCTUnwrap(fields["id"]), "size": 100], payload: Data([1]))
        do { _ = try await request.value; XCTFail("expected response timeout") }
        catch let error as VPhoneControl.ControlError {
            guard case .requestTimedOut = error else { XCTFail("unexpected error: \(error)"); return }
        }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(session.control.isConnected, "partial payload must not retain the reader indefinitely")
    }

    func testHandshakeTimeoutAndMalformedFramesDisconnect() async throws {
        let silent = try GuestSession(timing: .init(handshake: 0.05))
        defer { silent.stop() }
        let peer = silent.peer
        _ = try await Task.detached { try peer.readFrame() }.value
        try await Task.sleep(for: .milliseconds(150))
        let eof = await Task.detached { (try? peer.read(1)) == nil }.value
        XCTAssertTrue(eof)
        XCTAssertFalse(silent.control.isConnected)

        let badFrames = [Data([0, 0, 0, 0]), Data([0, 64, 0, 1]), Data([8, 0, 0, 0]),
                         GuestPeer.frame(Data("[]".utf8)), GuestPeer.frame(Data("{".utf8)),
                         GuestPeer.frame(Data("{\"v\":2,\"t\":\"pong\"}".utf8))]
        for frame in badFrames {
            let session = try GuestSession()
            defer { session.stop() }
            try await session.ready()
            try session.peer.write(frame)
            for _ in 0..<200 {
                if !session.control.isConnected { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            XCTAssertFalse(session.control.isConnected)
        }
    }

    func testOutgoingOversizeIsRejectedBeforeAnyBytes() async throws {
        let session = try GuestSession()
        defer { session.stop() }
        try await session.ready()
        do {
            try await session.control.clipboardSet(text: String(repeating: "x", count: 4 * 1024 * 1024))
            XCTFail("expected oversized request rejection")
        } catch let error as VPhoneControl.ControlError {
            guard case .protocolError = error else { XCTFail("unexpected error: \(error)"); return }
        }
        let ping = Task { try await session.control.sendPing() }
        let fields = try await session.readRequest()
        XCTAssertEqual(fields["t"] as? String, "ping")
        try session.peer.send(["v": 1, "t": "pong", "id": try XCTUnwrap(fields["id"])])
        try await ping.value
    }

    func testConcurrentRequestsCompleteByIDInReverseOrder() async throws {
        let session = try GuestSession()
        defer { session.stop() }
        try await session.ready()
        let tasks = (0..<12).map { index in
            Task { @MainActor in
                let (result, _) = try await session.control.sendRequest(["t": "version", "nonce": "n\(index)"])
                return result["hash"] as? String
            }
        }
        var requests: [[String: Any]] = []
        for _ in tasks { requests.append(try await session.readRequest()) }
        XCTAssertEqual(Set(requests.compactMap { $0["id"] as? String }).count, tasks.count)
        for fields in requests.reversed() {
            try session.peer.send(["v": 1, "t": "version", "id": try XCTUnwrap(fields["id"]), "hash": try XCTUnwrap(fields["nonce"])], fragment: 1)
        }
        for (index, task) in tasks.enumerated() {
            let value = try await task.value
            XCTAssertEqual(value, "n\(index)")
        }
    }

    func testRawFileAndClipboardPayloadsIncludeEmptyFiles() async throws {
        let session = try GuestSession()
        defer { session.stop() }
        try await session.ready()
        for payload in [Data(), Data([0, 255, 0, 1, 2, 3])] {
            let file = Task { try await session.control.downloadFile(path: "/x") }
            let request = try await session.readRequest()
            try session.peer.send(["v": 1, "t": "file_data", "id": try XCTUnwrap(request["id"]), "size": payload.count], payload: payload, fragment: 1)
            let value = try await file.value
            XCTAssertEqual(value, payload)
        }
        let image = Task { try await session.control.clipboardGet().imageData }
        let request = try await session.readRequest()
        try session.peer.send(["v": 1, "t": "clipboard_get", "id": try XCTUnwrap(request["id"]), "has_image": true, "image_size": 3], payload: Data([1, 255, 0]), fragment: 1)
        let value = try await image.value
        XCTAssertEqual(value, Data([1, 255, 0]))
    }

    func testInvalidPayloadSizesDisconnectWithoutAllocating() async throws {
        for size: Any in [-1, 64 * 1024 * 1024 + 1, 1.5, true, "10"] {
            let session = try GuestSession()
            defer { session.stop() }
            try await session.ready()
            let request = Task { try await session.control.downloadFile(path: "/x") }
            let fields = try await session.readRequest()
            try session.peer.send(["v": 1, "t": "file_data", "id": try XCTUnwrap(fields["id"]), "size": size])
            do { _ = try await request.value; XCTFail("expected invalid size failure") } catch {}
            XCTAssertFalse(session.control.isConnected)
        }
    }

    func testStalledUploadDisconnectsWithinWriteDeadline() async throws {
        let session = try GuestSession(timing: .init(request: 0.05, transfer: 0.2))
        defer { session.stop() }
        try await session.ready()
        let upload = Task { try await session.control.uploadFile(path: "/blocked", data: Data(repeating: 7, count: 8 * 1024 * 1024)) }
        let header = try await session.readRequest()
        XCTAssertEqual(header["t"] as? String, "file_put")
        let start = ContinuousClock.now
        do { try await upload.value; XCTFail("expected write failure") } catch {}
        for _ in 0..<200 {
            if !session.control.isConnected { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertFalse(session.control.isConnected)
    }

    func testOldWriterBacklogAndCallbacksCannotAffectReplacementConnection() async throws {
        let session = try GuestSession(timing: .init(request: 1, transfer: 1))
        defer { session.stop() }
        try await session.ready()
        let upload = Task { try await session.control.uploadFile(path: "/old", data: Data(repeating: 9, count: 8 * 1024 * 1024)) }
        _ = try await session.readRequest() // Writer has started the old transfer.
        let old = Task { try await session.control.sendVersion() }
        await Task.yield()
        try await session.replaceConnection()
        do { try await upload.value; XCTFail("old upload must fail") } catch {}
        do { _ = try await old.value; XCTFail("old request must fail") } catch {}
        let ping = Task { try await session.control.sendPing() }
        let fields = try await session.readRequest()
        XCTAssertEqual(fields["t"] as? String, "ping", "old queued JSON must not enter the new stream")
        try session.peer.send(["v": 1, "t": "pong", "id": try XCTUnwrap(fields["id"])])
        try await ping.value
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(session.control.isConnected)
    }

    func testCancelledQueuedRequestIsNotWrittenAfterUpload() async throws {
        let session = try GuestSession()
        defer { session.stop() }
        try await session.ready()
        let payload = Data(repeating: 21, count: 2 * 1024 * 1024)
        let upload = Task { try await session.control.uploadFile(path: "/queued", data: payload) }
        let header = try await session.readRequest()
        let cancelled = Task { try await session.control.sendVersion() }
        await Task.yield()
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("expected cancellation") } catch {}
        let peer = session.peer
        let received = try await Task.detached { try peer.read(payload.count) }.value
        XCTAssertEqual(received, payload)
        try peer.send(["v": 1, "t": "ok", "id": try XCTUnwrap(header["id"])])
        try await upload.value
        let ping = Task { try await session.control.sendPing() }
        let fields = try await session.readRequest()
        XCTAssertEqual(fields["t"] as? String, "ping")
        try peer.send(["v": 1, "t": "pong", "id": try XCTUnwrap(fields["id"])])
        try await ping.value
    }

    func testExplicitCancelAllAndTruncatedTransferFinishEachRequest() async throws {
        let session = try GuestSession()
        defer { session.stop() }
        try await session.ready()
        let first = Task { try await session.control.sendVersion() }
        let firstFields = try await session.readRequest()
        let second = Task { try await session.control.downloadFile(path: "/cancel") }
        let secondFields = try await session.readRequest()
        session.control.cancelPendingRequests(reason: "integration test")
        do { _ = try await first.value; XCTFail("expected cancellation") } catch {}
        do { _ = try await second.value; XCTFail("expected cancellation") } catch {}
        try session.peer.send(["v": 1, "t": "version", "id": try XCTUnwrap(firstFields["id"]), "hash": "late"])
        try session.peer.send(["v": 1, "t": "file_data", "id": try XCTUnwrap(secondFields["id"]), "size": 0])
        let third = Task { try await session.control.downloadFile(path: "/truncated") }
        let fields = try await session.readRequest()
        try session.peer.send(["v": 1, "t": "file_data", "id": try XCTUnwrap(fields["id"]), "size": 100], payload: Data([1, 2]))
        session.peer.stop()
        do { _ = try await third.value; XCTFail("expected truncated transfer failure") } catch {}
        XCTAssertFalse(session.control.isConnected)
    }

}
