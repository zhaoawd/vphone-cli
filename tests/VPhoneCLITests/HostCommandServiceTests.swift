import Foundation
import XCTest
@testable import vphone_cli

@MainActor
private final class SuspendedHostOperation {
    private var release: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var finishedWaiter: CheckedContinuation<Void, Never>?
    private var finished = false
    var started = false
    var cancelled = false

    func execute(_ data: Data) async -> Data {
        if started { return data }
        await withCheckedContinuation { continuation in
            release = continuation
            started = true
            entered?.resume()
            entered = nil
        }
        cancelled = Task.isCancelled
        finished = true
        finishedWaiter?.resume()
        finishedWaiter = nil
        return data
    }

    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { entered = $0 } }
    }

    func waitUntilFinished() async {
        if !finished { await withCheckedContinuation { finishedWaiter = $0 } }
    }

    func resume() { release?.resume(); release = nil }
}

@MainActor
final class HostCommandServiceTests: XCTestCase {
    private func decode(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTimeoutRetainsSlotUntilLateOperationActuallyFinishes() async throws {
        let operation = SuspendedHostOperation()
        let service = VPhoneHostCommandService(timeout: .milliseconds(50), limit: 1, execute: operation.execute)
        let first = Task { await service.submit(Data("first".utf8)) }
        await operation.waitUntilStarted()
        let timedOut = try decode(await first.value)
        XCTAssertEqual(timedOut["code"] as? String, "command_timeout")
        XCTAssertEqual(timedOut["operation_may_continue"] as? Bool, true)
        let busy = try decode(await service.submit(Data()))
        XCTAssertEqual(busy["code"] as? String, "command_busy")
        operation.resume()
        await operation.waitUntilFinished()
        XCTAssertTrue(operation.cancelled)
        let next = await service.submit(Data("next".utf8))
        XCTAssertEqual(next, Data("next".utf8))
        // A late result cannot replace the already delivered timeout.
        let unchanged = try decode(await first.value)
        XCTAssertEqual(unchanged["code"] as? String, "command_timeout")
        service.stop()
    }

    func testStopCancelsPendingReplyAndRejectsNewCommands() async throws {
        let operation = SuspendedHostOperation()
        let service = VPhoneHostCommandService(execute: operation.execute)
        let pending = Task { await service.submit(Data()) }
        await operation.waitUntilStarted()
        service.stop()
        let cancelled = try decode(await pending.value)
        XCTAssertEqual(cancelled["code"] as? String, "command_cancelled")
        let rejected = try decode(await service.submit(Data()))
        XCTAssertEqual(rejected["operation_may_continue"] as? Bool, false)
        operation.resume()
    }

    func testCallerCancellationCompletesOnceAndCancelsOperation() async throws {
        let operation = SuspendedHostOperation()
        let service = VPhoneHostCommandService(execute: operation.execute)
        let pending = Task { await service.submit(Data()) }
        await operation.waitUntilStarted()
        pending.cancel()
        let result = try decode(await pending.value)
        XCTAssertEqual(result["code"] as? String, "command_cancelled")
        operation.resume()
        service.stop()
    }

    func testSuccessfulCommandsReleaseExecutionSlots() async throws {
        let service = VPhoneHostCommandService(limit: 1) { $0 }
        for text in ["first", "second"] {
            let data = Data(text.utf8)
            let response = await service.submit(data)
            XCTAssertEqual(response, data)
        }
        service.stop()
    }
}
