import Foundation
import Testing
@testable import VPhoneAPIKit

struct APIRPCTimeoutTests {
    @Test func httpRPCMayOutliveTheHealthProbeDeadline() async throws {
        let fixture = try await APIHTTPFixture()
        defer { fixture.stop() }
        let client = try VPhoneAPIClient(
            baseURL: URL(string: "http://127.0.0.1:\(fixture.port)/slow-rpc")!,
            token: "1234567890abcdef", timeout: 0.1, rpcTimeout: 2)
        #expect(try await client.call("screen.unlock") == .object([:]))
        let probe = try VPhoneAPIClient(
            baseURL: URL(string: "http://127.0.0.1:\(fixture.port)/slow")!,
            token: "1234567890abcdef", timeout: 0.1, rpcTimeout: 2)
        let start = ContinuousClock.now
        await #expect(throws: (any Error).self) { try await probe.health() }
        #expect(start.duration(to: .now) < .seconds(1))
    }

    @Test func websocketRPCMayOutliveTheHealthProbeDeadline() async throws {
        let fixture = try await APIHTTPFixture(managedSession: true)
        defer { fixture.stop() }
        let client = try VPhoneAPIClient(
            baseURL: URL(string: "http://127.0.0.1:\(fixture.port)/slow-rpc")!,
            token: "1234567890abcdef", timeout: 0.1, rpcTimeout: 2)
        let socket = client.openWebSocket()
        do {
            #expect(try await socket.call("screen.unlock") == .string("screen.unlock"))
        } catch {
            await socket.close()
            throw error
        }
        await socket.close()
    }

    @Test func omittedRPCOverridePreservesTheConfiguredDeadline() async throws {
        let fixture = try await APIHTTPFixture()
        defer { fixture.stop() }
        let client = try fixture.client("slow-rpc", timeout: 0.1)
        await #expect(throws: (any Error).self) { try await client.call("screen.unlock") }
    }

    @Test func separateRPCDeadlineMustBeFiniteAndBounded() throws {
        for deadline in [0.0, -1, .infinity, .nan, 131] {
            #expect(throws: VPhoneAPIError.self) {
                try VPhoneAPIClient(baseURL: URL(string: "http://127.0.0.1:1")!, rpcTimeout: deadline)
            }
        }
        _ = try VPhoneAPIClient(baseURL: URL(string: "http://127.0.0.1:1")!, rpcTimeout: 130)
    }

    @Test func cancellationStillEndsASeparateRPCWait() async throws {
        let fixture = try await APIHTTPFixture()
        defer { fixture.stop() }
        let client = try VPhoneAPIClient(
            baseURL: URL(string: "http://127.0.0.1:\(fixture.port)/slow-rpc")!,
            token: "1234567890abcdef", timeout: 0.1, rpcTimeout: 75)
        let task = Task { try await client.call("screen.unlock") }
        try await Task.sleep(for: .milliseconds(30))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(start.duration(to: .now) < .seconds(1))
    }
}
