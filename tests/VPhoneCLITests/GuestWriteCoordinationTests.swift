import Foundation
import XCTest
import VPhoneCore
@testable import vphone_cli

@MainActor
final class GuestWriteCoordinationTests: XCTestCase {
    func testStopSealsQueuedWritersAndWaitsForActiveWriter() async throws {
        let coordinator = VPhoneGuestWriteCoordinator()
        var resume: CheckedContinuation<Void, Never>?
        var wrote = false
        var stopped = false
        let first = Task { try await coordinator.run { await withCheckedContinuation { resume = $0 } } }
        while resume == nil { await Task.yield() }
        let queued = Task { try await coordinator.run { wrote = true } }
        let stop = Task { await coordinator.sealAndWait(); stopped = true }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(stopped)
        resume?.resume()
        try await first.value
        do { try await queued.value; XCTFail("sealed writer ran") } catch {}
        await stop.value
        XCTAssertTrue(stopped)
        XCTAssertFalse(wrote)
    }

    func testOnlineLockRejectsLinksAndConflictsWithOtherProcess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("online-lock-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = directory.appendingPathComponent(VPhoneOnlineOperationLock.filename)
        let target = directory.appendingPathComponent("target")
        try Data("preserve".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)
        XCTAssertThrowsError(try VPhoneOnlineOperationLock(directory: directory))
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.linkItem(at: target, to: lock)
        XCTAssertThrowsError(try VPhoneOnlineOperationLock(directory: directory))
        try FileManager.default.removeItem(at: lock)
        let python = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".venv/bin/python3")
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = python
        process.arguments = ["-c", "import os,fcntl,sys; fd=os.open(sys.argv[1],os.O_CREAT|os.O_RDWR,0o600); fcntl.flock(fd,fcntl.LOCK_EX); print('ready',flush=True); sys.stdin.read(1)", lock.path]
        process.standardInput = input; process.standardOutput = output
        try process.run()
        defer { try? input.fileHandleForWriting.write(contentsOf: Data("x".utf8)); process.waitUntilExit() }
        XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 6), Data("ready\n".utf8))
        XCTAssertThrowsError(try VPhoneOnlineOperationLock(directory: directory))
        XCTAssertEqual(try Data(contentsOf: target), Data("preserve".utf8))
    }

    func testOnlineLockExcludesStopWithoutSignalling() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vphone-online-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try VPhoneOnlineOperationLock(directory: directory)
        var signalled = false
        let stopper = VPhoneVMStopper(listTargets: { [123] },
            identity: { _ in VPhoneProcessIdentity(pid: 123, startedAt: 1, uid: getuid()) },
            send: { _, _ in signalled = true; return 0 }, lockHeld: { true }, sleep: { _ in },
            acquireOnlineOperation: { try VPhoneOnlineOperationLock(directory: directory) })
        for force in [false, true] {
            let result = stopper.stop(timeout: 0, force: force)
            XCTAssertEqual(result.exitCode, 1)
            XCTAssertFalse(signalled)
        }
        withExtendedLifetime(writer) {}
    }

    func testActualRPCBootstrapAndShutdownQueueBehindWriterWhileReadsProceed() async throws {
        let coordinator = VPhoneGuestWriteCoordinator()
        let api = RPCSessionFake()
        api.caps += ["bootstrap_install", "bootstrap_uninstall", "system_shutdown", "system_control"]
        let executor = VPhoneHostCommandExecutor(apiSession: api, guestWrites: coordinator)
        var resume: CheckedContinuation<Void, Never>?
        let active = Task { try await coordinator.run { await withCheckedContinuation { resume = $0 } } }
        while resume == nil { await Task.yield() }
        func request(_ method: String) throws -> Data { try JSONSerialization.data(withJSONObject: ["t": "rpc", "method": method]) }
        let bootstrapRequest = try request("bootstrap.firmware")
        let shutdownRequest = try request("system.shutdown")
        let bootstrap = Task { await executor.execute(bootstrapRequest) }
        for _ in 0..<20 { await Task.yield() }
        let shutdown = Task { await executor.execute(shutdownRequest) }
        for _ in 0..<20 { await Task.yield() }
        _ = await executor.execute(try request("clipboard.get"))
        XCTAssertEqual(api.calls.map(\.method), ["clipboard.get"])
        resume?.resume()
        try await active.value
        _ = await bootstrap.value
        _ = await shutdown.value
        XCTAssertEqual(api.calls.map(\.method), ["clipboard.get", "bootstrap.firmware", "system.shutdown"])
        let next = await executor.execute(try request("bootstrap.install"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: next) as? [String: Any])?["ok"] as? Bool, false)
    }

    func testSubmittedRPCFailureRetainsLeaseAndSealsNewWriters() async throws {
        let writes = VPhoneGuestWriteCoordinator()
        let api = RPCSessionFake(); api.caps.append("bootstrap_install")
        api.handler = { _ in throw URLError(.networkConnectionLost) }
        let executor = VPhoneHostCommandExecutor(apiSession: api, guestWrites: writes)
        _ = await executor.execute(try JSONSerialization.data(withJSONObject: ["t": "rpc", "method": "bootstrap.install"]))
        XCTAssertTrue(writes.pendingRecovery)
        do { try await writes.run {}; XCTFail("uncertain guest writer allowed another writer") } catch {}
    }

    func testIndependentVMWriterDoesNotWaitForOtherVM() async throws {
        let first = VPhoneGuestWriteCoordinator(), second = VPhoneGuestWriteCoordinator()
        var resume: CheckedContinuation<Void, Never>?
        let writing = Task { try await first.run { await withCheckedContinuation { resume = $0 } } }
        while resume == nil { await Task.yield() }
        let value = try await second.run { 42 }
        XCTAssertEqual(value, 42)
        resume?.resume()
        try await writing.value
    }
}
