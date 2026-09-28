import Foundation
import Testing
@testable import VPhoneAPIKit

final class APISocketFixture: VPhoneAPIWebSocketTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [Data] = []
    private var waiter: CheckedContinuation<Data, any Error>?
    private var sent: [Data] = []
    private var closed = false
    let stallSend: Bool

    init(stallSend: Bool = false) { self.stallSend = stallSend }
    func send(_ data: Data) async throws {
        try lock.withLock {
            guard !closed else { throw URLError(.networkConnectionLost) }
            sent.append(data)
        }
        if stallSend { try await Task.sleep(for: .seconds(120)) }
    }
    func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                if closed { continuation.resume(throwing: URLError(.networkConnectionLost)) }
                else if !inbox.isEmpty { continuation.resume(returning: inbox.removeFirst()) }
                else { waiter = continuation }
            }
        }
    }
    func cancel() {
        lock.withLock {
            closed = true
            waiter?.resume(throwing: URLError(.networkConnectionLost))
            waiter = nil
        }
    }
    func emit(_ data: Data) {
        lock.withLock {
            guard !closed else { return }
            if let continuation = waiter { waiter = nil; continuation.resume(returning: data) }
            else { inbox.append(data) }
        }
    }
    func messages(_ count: Int) async throws -> [[String: VPhoneJSONValue]] {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            let snapshot = lock.withLock { sent }
            if snapshot.count >= count { return try snapshot.map { try VPhoneAPIWire.object($0) } }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw URLError(.timedOut)
    }
    func reply(id: VPhoneJSONValue, result: VPhoneJSONValue) throws {
        emit(try JSONEncoder().encode(VPhoneJSONValue.object(["type": .string("response"), "id": id, "result": result])))
    }
}

struct APIWebSocketTests {
    @Test func correlatesOutOfOrderRepliesAndInterleavedEvents() async throws {
        let transport = APISocketFixture()
        let socket = VPhoneAPIWebSocket(transport: transport, timeout: 30)
        let first = Task { try await socket.call("first") }
        let second = Task { try await socket.call("second") }
        let sent = try await transport.messages(2)
        let a = try #require(sent.first { $0["method"] == .string("first") }?["id"])
        let b = try #require(sent.first { $0["method"] == .string("second") }?["id"])
        transport.emit(Data(#"{"type":"event","event":"changed","data":{"value":3}}"#.utf8))
        try transport.reply(id: b, result: .number(2))
        try transport.reply(id: a, result: .number(1))
        #expect(try await first.value == .number(1))
        #expect(try await second.value == .number(2))
        var events = socket.events.makeAsyncIterator()
        #expect(try await events.next()?.event == "changed")
        await socket.close()
    }

    @Test func cancellationAndLateReplyCannotCompleteNextRequest() async throws {
        let transport = APISocketFixture()
        let socket = VPhoneAPIWebSocket(transport: transport, timeout: 30)
        let cancelled = Task { try await socket.call("cancelled") }
        let oldID = try #require(try await transport.messages(1).first?["id"])
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        let next = Task { try await socket.call("next") }
        let newID = try #require(try await transport.messages(2).last?["id"])
        try transport.reply(id: oldID, result: .string("late"))
        try transport.reply(id: oldID, result: .string("duplicate"))
        try transport.reply(id: .string("unknown"), result: .null)
        try transport.reply(id: newID, result: .string("current"))
        #expect(try await next.value == .string("current"))
        await socket.close()
    }

    @Test func timeoutIncludesBlockedSendAndReleasesPendingSlot() async throws {
        let transport = APISocketFixture(stallSend: true)
        let socket = VPhoneAPIWebSocket(transport: transport, timeout: 0.05)
        do { _ = try await socket.call("blocked"); Issue.record("Expected timeout") }
        catch let error as VPhoneAPIError { #expect(error.code == "timeout") }
        let next = Task { try await socket.call("next") }
        let sent = try await transport.messages(2)
        try transport.reply(id: try #require(sent[0]["id"]), result: .string("late"))
        try transport.reply(id: try #require(sent[1]["id"]), result: .string("next"))
        #expect(try await next.value == .string("next"))
        await socket.close()
    }

    @Test func disconnectFailsAllAndOldGenerationCannotAffectNewSocket() async throws {
        let transport = APISocketFixture()
        let socket = VPhoneAPIWebSocket(transport: transport, timeout: 30)
        let a = Task { try await socket.call("a") }
        let b = Task { try await socket.call("b") }
        let oldID = try #require(try await transport.messages(2).first?["id"])
        transport.cancel()
        await #expect(throws: (any Error).self) { try await a.value }
        await #expect(throws: (any Error).self) { try await b.value }
        await #expect(throws: VPhoneAPIError.self) { try await socket.call("closed") }
        let newTransport = APISocketFixture()
        let newSocket = VPhoneAPIWebSocket(transport: newTransport, timeout: 30)
        #expect(socket.generation != newSocket.generation)
        let next = Task { try await newSocket.call("next") }
        let id = try #require(try await newTransport.messages(1).first?["id"])
        try newTransport.reply(id: oldID, result: .string("stale"))
        try newTransport.reply(id: id, result: .string("new"))
        #expect(try await next.value == .string("new"))
        await newSocket.close()
    }

    @Test func boundsPendingRequestsAndCloseCompletesWaiters() async throws {
        let transport = APISocketFixture()
        let socket = VPhoneAPIWebSocket(transport: transport, timeout: 30)
        let requests = (0..<16).map { n in Task { try await socket.call("m\(n)") } }
        _ = try await transport.messages(16)
        do { _ = try await socket.call("overflow"); Issue.record("Expected busy") }
        catch let error as VPhoneAPIError { #expect(error.code == "busy") }
        await socket.close()
        for request in requests { await #expect(throws: VPhoneAPIError.self) { try await request.value } }
    }

    @Test func malformedMessageFailsPendingRequests() async throws {
        let transport = APISocketFixture()
        let socket = VPhoneAPIWebSocket(transport: transport, timeout: 30)
        let request = Task { try await socket.call("one") }
        _ = try await transport.messages(1)
        transport.emit(Data(#"{"type":"response","id":null,"error":{}}"#.utf8))
        await #expect(throws: VPhoneAPIError.self) { try await request.value }
        await #expect(throws: VPhoneAPIError.self) { try await socket.call("closed") }
    }

    @Test func eventOverflowClosesConnectionInsteadOfSilentlyDropping() async throws {
        let transport = APISocketFixture()
        let socket = VPhoneAPIWebSocket(transport: transport, timeout: 30)
        let request = Task { try await socket.call("one") }
        _ = try await transport.messages(1)
        for _ in 0..<65 { transport.emit(Data(#"{"type":"event","event":"x","data":{}}"#.utf8)) }
        do { _ = try await request.value; Issue.record("Expected overflow") }
        catch let error as VPhoneAPIError { #expect(error.code == "event_overflow") }
    }

    @Test func remoteErrorOnlyFailsItsMatchingRequest() async throws {
        let transport = APISocketFixture()
        let socket = VPhoneAPIWebSocket(transport: transport, timeout: 30)
        let request = Task { try await socket.call("denied") }
        let id = try #require(try await transport.messages(1).first?["id"])
        transport.emit(try JSONEncoder().encode(VPhoneJSONValue.object([
            "type": .string("response"), "id": id,
            "error": .object(["code": .string("denied"), "message": .string("fixture")]),
        ])))
        do { _ = try await request.value; Issue.record("Expected remote error") }
        catch let error as VPhoneAPIError { #expect(error.code == "denied") }
        let next = Task { try await socket.call("next") }
        let nextID = try #require(try await transport.messages(2).last?["id"])
        try transport.reply(id: nextID, result: .null)
        #expect(try await next.value == .null)
        await socket.close()
    }

    @Test func receivesEventsWithoutAnRPC() async throws {
        let transport = APISocketFixture()
        let socket = VPhoneAPIWebSocket(transport: transport, timeout: 30)
        try await socket.startEvents()
        transport.emit(Data(#"{"type":"event","event":"connected","data":{"api_version":1}}"#.utf8))
        var events = socket.events.makeAsyncIterator()
        #expect(try await events.next()?.event == "connected")
        await socket.close()
    }

    @Test func preCancelledTaskDoesNotSend() async throws {
        let transport = APISocketFixture()
        let socket = VPhoneAPIWebSocket(transport: transport, timeout: 30)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await socket.call("cancelled")
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        await socket.close()
    }
}
