import Foundation
import XCTest
@testable import VPhoneAPIKit

@MainActor
final class APISessionTests: XCTestCase {
    private func health(_ id: UUID = UUID(), caps: [String] = ["session_identity", "files"], hash: String = String(repeating: "a", count: 64)) throws -> (VPhoneAPIHealth, VPhoneJSONValue) {
        let value = VPhoneJSONValue.object([
            "status": .string("ok"), "api_version": .number(1), "binary_hash": .string(hash),
            "instance_id": .string(id.uuidString), "capabilities": .array(caps.map(VPhoneJSONValue.string)),
        ])
        return try (VPhoneAPIHealth.decode(JSONEncoder().encode(value), requiredCapabilities: [], expectedBinaryHash: nil), value)
    }

    private func hello(_ fixture: APISocketFixture, _ value: VPhoneJSONValue) throws {
        fixture.emit(try JSONEncoder().encode(VPhoneJSONValue.object([
            "type": .string("event"), "event": .string("connected"), "data": value,
        ])))
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testRealLoopbackSession() async throws {
        let fixture = try await APIHTTPFixture(managedSession: true)
        defer { fixture.stop() }
        let session = VPhoneAPISession(client: try fixture.client(timeout: 5), vmInstanceID: "loopback")
        defer { session.stop() }
        session.start()
        try await wait { session.snapshot.state == .ready }
        let result = try await session.call("files.list", requiring: "files")
        XCTAssertEqual(result, .string("files.list"))
        XCTAssertNotNil(session.snapshot.health?.instanceID)
    }

    func testReadyHeartbeatCapabilityGateAndStop() async throws {
        let (baseline, value) = try health()
        let fixture = APISocketFixture()
        try hello(fixture, value)
        let session = VPhoneAPISession(vmInstanceID: "vm-one", timing: .init(heartbeat: .milliseconds(100)),
            probe: { baseline }, connect: { VPhoneAPIWebSocket(transport: fixture, timeout: 5) })
        defer { session.stop() }
        session.start()
        try await wait { session.snapshot.state == .ready }
        XCTAssertEqual(session.snapshot.health, baseline)
        XCTAssertEqual(session.snapshot.vmInstanceID, "vm-one")
        do { _ = try await session.call("files.list", requiring: "missing"); XCTFail("Missing capability accepted") }
        catch let error as VPhoneAPIError { XCTAssertEqual(error.code, "unsupported_capability") }
        let heartbeat = try await fixture.messages(1)[0]
        XCTAssertEqual(heartbeat["method"], .string("agent.health"))
        try fixture.reply(id: XCTUnwrap(heartbeat["id"]), result: value)
        let operation = Task { try await session.call("files.list", requiring: "files") }
        let messages = try await fixture.messages(2)
        try fixture.reply(id: XCTUnwrap(messages[1]["id"]), result: .null)
        let result = try await operation.value
        XCTAssertEqual(result, .null)
        session.stop()
        XCTAssertEqual(session.snapshot.state, .stopped)
        XCTAssertNil(session.snapshot.health)
        XCTAssertNil(session.snapshot.generation)
    }

    func testMismatchedHelloAndMissingCapabilityNeverBecomeReady() async throws {
        let (baseline, _) = try health()
        let (_, different) = try health()
        let fixture = APISocketFixture()
        try hello(fixture, different)
        let session = VPhoneAPISession(vmInstanceID: "vm", probe: { baseline },
            connect: { VPhoneAPIWebSocket(transport: fixture, timeout: 5) })
        defer { session.stop() }
        session.start()
        try await wait { session.snapshot.state == .reconnecting }
        XCTAssertEqual(session.snapshot.errorCode, "identity_mismatch")
        XCTAssertNil(session.snapshot.health)
        let (missing, _) = try health(caps: ["files"])
        let legacy = VPhoneAPISession(vmInstanceID: "vm", probe: { missing }, connect: {
            XCTFail("Unsupported health must not open socket")
            return VPhoneAPIWebSocket(transport: APISocketFixture(), timeout: 5)
        })
        defer { legacy.stop() }
        legacy.start()
        try await wait { legacy.snapshot.state == .reconnecting }
        XCTAssertEqual(legacy.snapshot.errorCode, "unsupported_capability")
    }

    func testHeartbeatIdentityChangeClearsState() async throws {
        let (baseline, value) = try health()
        let (_, changed) = try health()
        let fixture = APISocketFixture()
        try hello(fixture, value)
        let session = VPhoneAPISession(vmInstanceID: "vm", timing: .init(heartbeat: .milliseconds(10)),
            probe: { baseline }, connect: { VPhoneAPIWebSocket(transport: fixture, timeout: 5) })
        defer { session.stop() }
        session.start()
        let request = try await fixture.messages(1)[0]
        try fixture.reply(id: XCTUnwrap(request["id"]), result: changed)
        try await wait { session.snapshot.state == .reconnecting }
        XCTAssertEqual(session.snapshot.errorCode, "identity_mismatch")
        XCTAssertNil(session.snapshot.health)
    }

    func testDisconnectReconnectUsesNewGenerationAndDoesNotReplayCalls() async throws {
        let (baseline, value) = try health()
        let first = APISocketFixture(), second = APISocketFixture()
        try hello(first, value)
        try hello(second, value)
        let pool = SocketPool([first, second])
        let session = VPhoneAPISession(vmInstanceID: "vm", timing: .init(retry: .milliseconds(10)),
            probe: { baseline }, connect: { VPhoneAPIWebSocket(transport: pool.next(), timeout: 5) })
        defer { session.stop() }
        session.start()
        try await wait { session.snapshot.state == .ready }
        let generation = session.snapshot.generation
        let pending = Task { try await session.call("mutating.operation") }
        _ = try await first.messages(1)
        first.cancel()
        do { _ = try await pending.value; XCTFail("Disconnected call succeeded") } catch {}
        try await wait { session.snapshot.state == .ready && session.snapshot.generation != generation }
        let next = Task { try await session.call("next") }
        let request = try await second.messages(1)[0]
        XCTAssertEqual(request["method"], .string("next"))
        try second.reply(id: XCTUnwrap(request["id"]), result: .null)
        _ = try await next.value
    }

    func testLateProbeCannotReviveStoppedSession() async throws {
        let (baseline, _) = try health()
        let probe = SuspendedProbe()
        let session = VPhoneAPISession(vmInstanceID: "vm", probe: { await probe.read() }, connect: {
            XCTFail("Stopped probe must not connect")
            return VPhoneAPIWebSocket(transport: APISocketFixture(), timeout: 5)
        })
        session.start()
        while !(await probe.waiting) { await Task.yield() }
        session.stop()
        await probe.finish(baseline)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(session.snapshot.state, .stopped)
        XCTAssertNil(session.snapshot.health)
    }

    func testHandshakeDeadlineAndHashPin() async throws {
        let (baseline, _) = try health()
        let session = VPhoneAPISession(vmInstanceID: "vm", timing: .init(handshake: .milliseconds(20)),
            probe: { baseline }, connect: { VPhoneAPIWebSocket(transport: APISocketFixture(), timeout: 5) })
        defer { session.stop() }
        session.start()
        try await wait { session.snapshot.state == .reconnecting }
        XCTAssertEqual(session.snapshot.errorCode, "timeout")
        let pinned = VPhoneAPISession(vmInstanceID: "vm", expectedBinaryHash: String(repeating: "b", count: 64),
            probe: { baseline }, connect: {
                XCTFail("Hash mismatch must not connect")
                return VPhoneAPIWebSocket(transport: APISocketFixture(), timeout: 5)
            })
        defer { pinned.stop() }
        pinned.start()
        try await wait { pinned.snapshot.state == .reconnecting }
        XCTAssertEqual(pinned.snapshot.errorCode, "binary_mismatch")
    }
}

private final class SocketPool: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [APISocketFixture]
    init(_ sockets: [APISocketFixture]) { self.sockets = sockets }
    func next() -> APISocketFixture { lock.withLock { sockets.isEmpty ? APISocketFixture() : sockets.removeFirst() } }
}

private actor SuspendedProbe {
    private var continuation: CheckedContinuation<VPhoneAPIHealth, Never>?
    var waiting: Bool { continuation != nil }
    func read() async -> VPhoneAPIHealth { await withCheckedContinuation { continuation = $0 } }
    func finish(_ health: VPhoneAPIHealth) { continuation?.resume(returning: health); continuation = nil }
}
