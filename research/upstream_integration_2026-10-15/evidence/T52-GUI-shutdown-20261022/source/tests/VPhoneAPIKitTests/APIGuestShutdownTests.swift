import Darwin
import Foundation
import XCTest
@testable import VPhoneAPIKit

private final class ShutdownGuest: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [Data] = []
    private var attempts = 0
    private var finished = false
    let health: [String: VPhoneJSONValue]
    let response: String?
    let rawHealth: String?
    let stall: Bool
    let stallAt: Int
    let healthDelay: useconds_t

    init(capabilities: [String] = ["session_identity", "system_shutdown"], instance: Bool = true,
         response: String? = nil, rawHealth: String? = nil, stall: Bool = false,
         stallAt: Int = 1, healthDelay: useconds_t = 0) {
        var fields: [String: VPhoneJSONValue] = ["api_version": .number(1), "status": .string("ok"),
            "binary_hash": .string(String(repeating: "a", count: 64)),
            "capabilities": .array(capabilities.map(VPhoneJSONValue.string))]
        if instance { fields["instance_id"] = .string(UUID().uuidString) }
        health = fields
        self.response = response
        self.rawHealth = rawHealth
        self.stall = stall
        self.stallAt = stallAt
        self.healthDelay = healthDelay
    }
    var requests: [Data] { lock.withLock { captured } }
    var count: Int { lock.withLock { attempts } }
    var done: Bool { lock.withLock { finished } }

    func connect(_ completion: @escaping @Sendable (Result<VPhoneAPISocket, any Error>) -> Void) {
        let index = lock.withLock { attempts += 1; return attempts }
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            completion(.failure(VPhoneAPISocket.failure())); return
        }
        let peer = pair[1]
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        var one: Int32 = 1
        setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        completion(Result { try VPhoneAPISocket(takingOwnership: pair[0]) })
        DispatchQueue.global().async { [self] in
            defer { close(peer); lock.withLock { finished = true } }
            guard let first = receive(peer) else { return }
            lock.withLock { captured.append(first) }
            if stall, index == stallAt {
                var byte: UInt8 = 0
                XCTAssertEqual(read(peer, &byte, 1), 0, "Cancelled/timed out request must close its socket")
                return
            }
            if let rawHealth {
                send(peer, Data(rawHealth.utf8))
                return
            }
            if index == 1 {
                if healthDelay > 0 { usleep(healthDelay) }
                send(peer, reply(try! JSONEncoder().encode(VPhoneJSONValue.object(health))))
                return  // Production GuestHyperTextHandler closes after every HTTP response.
            }
            let boundary = first.range(of: Data("\r\n\r\n".utf8))!
            let object = try! VPhoneAPIWire.object(Data(first[boundary.upperBound...]))
            XCTAssertEqual(object["method"], .string("system.shutdown"))
            XCTAssertEqual(object["params"], .object(["force": .bool(true)]))
            let body: Data
            if let response {
                guard case let .string(id) = object["id"] else { return }
                body = Data(response.replacingOccurrences(of: "$ID", with: id).utf8)
            }
            else { body = try! JSONEncoder().encode(VPhoneJSONValue.object([
                "type": .string("response"), "id": object["id"]!, "result": .object(["accepted": .bool(true)])])) }
            send(peer, reply(body))
        }
    }
    private func reply(_ body: Data) -> Data {
        Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n".utf8) + body
    }
    private func send(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard n > 0 else { return }
                offset += n
            }
        }
    }
    private func receive(_ fd: Int32) -> Data? {
        var data = Data(), byte: UInt8 = 0
        while data.suffix(4) != Data("\r\n\r\n".utf8), data.count < 16384 {
            guard read(fd, &byte, 1) == 1 else { return nil }
            data.append(byte)
        }
        let text = String(decoding: data, as: UTF8.self)
        let length = Int(text.components(separatedBy: "\r\n").first(where: { $0.hasPrefix("Content-Length:") })!
            .dropFirst("Content-Length:".count).trimmingCharacters(in: .whitespaces))!
        for _ in 0..<length {
            guard read(fd, &byte, 1) == 1 else { return nil }
            data.append(byte)
        }
        return data
    }
}

final class APIGuestShutdownTests: XCTestCase {
    func testShutdownRespectsGuestConnectionCloseWithoutListenerOrToken() async throws {
        let guest = ShutdownGuest()
        let accepted = try await VPhoneAPIGuestShutdown(connector: guest.connect).request()
        XCTAssertTrue(accepted)
        XCTAssertEqual(guest.count, 2)
        XCTAssertEqual(guest.requests.count, 2)
        for request in guest.requests {
            let text = String(decoding: request, as: UTF8.self)
            XCTAssertTrue(text.contains("Host: vphoned\r\n"))
            XCTAssertFalse(text.contains("Authorization:"))
            XCTAssertFalse(text.contains("Origin:"))
        }
    }

    func testUnsupportedHealthNeverSendsShutdown() async throws {
        for guest in [ShutdownGuest(capabilities: ["session_identity"]), ShutdownGuest(instance: false)] {
            do { _ = try await VPhoneAPIGuestShutdown(connector: guest.connect).request(); XCTFail("Expected refusal") }
            catch { XCTAssertTrue(error is VPhoneAPIError) }
            XCTAssertEqual(guest.requests.count, 1)
            XCTAssertEqual(guest.count, 1)
        }
    }

    func testUncorrelatedOrErrorReplyIsNotAcceptance() async throws {
        for body in [#"{"type":"response","id":"wrong","result":{"accepted":true}}"#,
                     #"{"type":"response","id":"$ID","error":{"code":"busy","message":"busy"}}"#] {
            let guest = ShutdownGuest(response: body)
            do { _ = try await VPhoneAPIGuestShutdown(connector: guest.connect).request(); XCTFail("Expected refusal") }
            catch { XCTAssertTrue(error is VPhoneAPIError) }
            XCTAssertEqual(guest.count, 2)
        }
    }

    func testExplicitRefusalIsNotAcceptance() async throws {
        let guest = ShutdownGuest(response: #"{"type":"response","id":"$ID","result":{"accepted":false}}"#)
        let accepted = try await VPhoneAPIGuestShutdown(connector: guest.connect).request()
        XCTAssertFalse(accepted)
        XCTAssertEqual(guest.count, 2)
    }

    func testMalformedHTTPDoesNotAuthorizeShutdown() async throws {
        for header in ["Content-Length: 2\r\nContent-Length: 2", "Transfer-Encoding: chunked",
                       "Content-Length: 65537", "Content-Length: -1"] {
            let guest = ShutdownGuest(rawHealth: "HTTP/1.1 200 OK\r\n\(header)\r\n\r\n{}")
            do { _ = try await VPhoneAPIGuestShutdown(connector: guest.connect).request(); XCTFail("Expected refusal") }
            catch { XCTAssertTrue(error is VPhoneAPIError) }
            XCTAssertEqual(guest.requests.count, 1)
        }
    }

    func testTimeoutClosesGuestSocketWithoutRetry() async throws {
        let guest = ShutdownGuest(stall: true)
        let start = ContinuousClock.now
        do { _ = try await VPhoneAPIGuestShutdown(connector: guest.connect, timeout: 0.1).request(); XCTFail("Expected timeout") }
        catch { XCTAssertEqual((error as? VPhoneAPIError)?.code, "timeout") }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        for _ in 0..<100 where !guest.done { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(guest.done)
        XCTAssertEqual(guest.count, 1)
    }

    func testCancellationClosesGuestSocketAndDoesNotSendRPC() async throws {
        let guest = ShutdownGuest(stall: true)
        let task = Task { try await VPhoneAPIGuestShutdown(connector: guest.connect).request() }
        for _ in 0..<100 where guest.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(guest.requests.count, 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch {}
        for _ in 0..<100 where !guest.done { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(guest.done)
        XCTAssertEqual(guest.requests.count, 1)
    }

    func testMissingConnectorCallbackIsBounded() async throws {
        let start = ContinuousClock.now
        do { _ = try await VPhoneAPIGuestShutdown(connector: { _ in }, timeout: 0.05).request(); XCTFail("Expected timeout") }
        catch { XCTAssertEqual((error as? VPhoneAPIError)?.code, "timeout") }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
    }

    func testHealthAndShutdownShareOneDeadline() async throws {
        let guest = ShutdownGuest(stall: true, stallAt: 2, healthDelay: 350000)
        let start = ContinuousClock.now
        do { _ = try await VPhoneAPIGuestShutdown(connector: guest.connect, timeout: 0.5).request(); XCTFail("Expected timeout") }
        catch { XCTAssertEqual((error as? VPhoneAPIError)?.code, "timeout") }
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(700))
        XCTAssertEqual(guest.requests.count, 2)
        XCTAssertEqual(guest.count, 2)
    }

    func testLateConnectorResultIsClosedAfterTimeout() async throws {
        final class Pending: @unchecked Sendable {
            let lock = NSLock()
            var callback: (@Sendable (Result<VPhoneAPISocket, any Error>) -> Void)?
            func store(_ value: @escaping @Sendable (Result<VPhoneAPISocket, any Error>) -> Void) {
                lock.withLock { callback = value }
            }
            func complete(_ value: VPhoneAPISocket) {
                let reply = lock.withLock { callback }
                reply?(.success(value))
            }
        }
        let pending = Pending()
        do { _ = try await VPhoneAPIGuestShutdown(connector: pending.store, timeout: 0.05).request(); XCTFail("Expected timeout") }
        catch { XCTAssertEqual((error as? VPhoneAPIError)?.code, "timeout") }
        var pair: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { close(pair[1]) }
        pending.complete(try VPhoneAPISocket(takingOwnership: pair[0]))
        var byte: UInt8 = 0
        var event = pollfd(fd: pair[1], events: Int16(POLLIN), revents: 0)
        XCTAssertGreaterThan(poll(&event, 1, 200), 0)
        XCTAssertEqual(read(pair[1], &byte, 1), 0)
    }
}
