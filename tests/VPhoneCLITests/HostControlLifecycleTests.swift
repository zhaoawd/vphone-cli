import Darwin
import Foundation
import XCTest
import VPhoneCore
@testable import vphone_cli

@MainActor
final class ControlEndpoint {
    let directory: URL
    let path: String
    let server: VPhoneHostControl

    init(executor: VPhoneHostCommandExecutor) throws {
        directory = URL(fileURLWithPath: "/tmp/vp-e3-" + UUID().uuidString.prefix(8))
        path = directory.appendingPathComponent("vphone.sock").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        server = VPhoneHostControl(socketPath: path, executor: executor)
    }

    func clean() { server.stop(); try? FileManager.default.removeItem(at: directory) }

    func address() -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: bytes.count) { target in
                for (index, byte) in bytes.enumerated() { target[index] = byte }
            }
        }
        return address
    }

    func connectClient() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw CocoaError(.fileReadUnknown) }
        HostControlIO.configure(fd)
        var address = address()
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); throw CocoaError(.fileReadUnknown) }
        return fd
    }

    func request(_ fields: [String: Any]) async throws -> [String: Any] {
        try decodeResponse(await rawRequest(fields))
    }

    /// The response line, for tests that keep a request open in a Task.
    /// Blocking socket I/O runs on a GCD thread: many simultaneous clients
    /// would otherwise occupy the cooperative pool and delay their own writes
    /// past the server's request read deadline.
    func rawRequest(_ fields: [String: Any]) async throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: fields)
        let fd = try connectClient()
        defer { close(fd) }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                HostControlIO.writeResponse(data + Data([10]), to: fd)
                // A closed connection is an error, not a recorded XCTest failure,
                // so a test can accept EOF where the server may close.
                continuation.resume(with: Result {
                    guard let line = try HostControlIO.readRequest(fd) else { throw CocoaError(.fileReadCorruptFile) }
                    return line
                })
            }
        }
    }
}

func decodeResponse(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Polls a main-actor condition; fails instead of hanging the suite.
@MainActor
func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(10),
               file: StaticString = #filePath, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            XCTFail("condition not reached within \(timeout)", file: file, line: line)
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
final class HostControlLifecycleTests: XCTestCase {
    func testHeadlessSocketRoutesGuestCommandsAndReportsConnectionChanges() async throws {
        let guest = HostGuestFake()
        let location = HostLocationFake()
        let endpoint = try ControlEndpoint(executor: .init(control: guest, location: location))
        defer { endpoint.clean() }
        try endpoint.server.start()
        let capabilities = try await endpoint.request(["t": "capabilities"])
        XCTAssertEqual(capabilities["boot_mode"] as? String, "normal")
        XCTAssertEqual(capabilities["screen_available"] as? Bool, false)
        for fields: [String: Any] in [["t": "shell", "cmd": "true"],
                                     ["t": "file_get", "path": "/x"],
                                     ["t": "file_put", "path": "/x", "data_b64": "eA=="],
                                     ["t": "app_launch", "bundle_id": "app", "delay": 0],
                                     ["t": "app_list"], ["t": "location_source_status"]] {
            let result = try await endpoint.request(fields)
            XCTAssertEqual(result["ok"] as? Bool, true)
            XCTAssertNil(result["image"])
        }
        let fixed = try await endpoint.request(["t": "location_source_set", "mode": "fixed",
                                               "owner": "e3", "coordinate_system": "wgs84", "producer_sequence": 0,
                                               "lat": 31.2, "lon": 121.5, "timestamp": 1_700_000_000,
                                               "heartbeat_s": 3600])
        XCTAssertEqual(fixed["ok"] as? Bool, true)
        let generation = try XCTUnwrap(fixed["generation"] as? String)
        _ = try await endpoint.request(["t": "location_source_stop", "generation": generation])
        let screenshot = try await endpoint.request(["t": "screenshot"])
        XCTAssertEqual(screenshot["error"] as? String, "no active VM view")
        guest.isConnected = false
        let disconnected = try await endpoint.request(["t": "capabilities"])
        XCTAssertEqual(disconnected["guest_connected"] as? Bool, false)
        let rejected = try await endpoint.request(["t": "shell", "cmd": "true"])
        XCTAssertEqual(rejected["error"] as? String, "guest not connected")
        guest.isConnected = true
        let reconnected = try await endpoint.request(["t": "shell", "cmd": "true"])
        XCTAssertEqual(reconnected["ok"] as? Bool, true)
    }

    func testGUISocketKeepsScreenAndDFUOnlyExposesDiscovery() async throws {
        let guest = HostGuestFake()
        let screen = HostScreenFake()
        let gui = try ControlEndpoint(executor: .init(control: guest, screen: screen))
        defer { gui.clean() }
        try gui.server.start()
        let image = try await gui.request(["t": "screenshot", "color": true])
        XCTAssertEqual(image["image"] as? String, "jpeg")
        let dfu = try ControlEndpoint(executor: .init(control: guest, screen: screen, bootMode: .dfu))
        defer { dfu.clean() }
        try dfu.server.start()
        let capabilities = try await dfu.request(["t": "capabilities"])
        XCTAssertEqual(capabilities["boot_mode"] as? String, "dfu")
        let commands = try XCTUnwrap(capabilities["commands"] as? [String: Bool])
        XCTAssertEqual(commands.filter { $0.value }.map(\.key), ["capabilities"])
        for request: [String: Any] in [["t": "shell", "cmd": "true"], ["t": "screenshot"], ["t": "location_source_status"]] {
            let result = try await dfu.request(request)
            XCTAssertEqual(result["code"] as? String, "capability_unavailable")
        }
    }

    func testActiveSocketCannotBeReplacedAndOtherInstanceStopDoesNotRemoveIt() async throws {
        let endpoint = try ControlEndpoint(executor: .init())
        defer { endpoint.clean() }
        try endpoint.server.start()
        let duplicate = VPhoneHostControl(socketPath: endpoint.path, executor: .init())
        XCTAssertThrowsError(try duplicate.start())
        duplicate.stop()
        let result = try await endpoint.request(["t": "capabilities"])
        XCTAssertEqual(result["ok"] as? Bool, true)
    }

    func testStaleSocketIsReplacedAndNormalFilesArePreserved() async throws {
        let endpoint = try ControlEndpoint(executor: .init())
        defer { endpoint.clean() }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = endpoint.address()
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(fd)
        XCTAssertEqual(result, 0)
        try endpoint.server.start()
        let response = try await endpoint.request(["t": "capabilities"])
        XCTAssertEqual(response["ok"] as? Bool, true)
        endpoint.server.stop()
        try Data("keep".utf8).write(to: URL(fileURLWithPath: endpoint.path))
        let other = VPhoneHostControl(socketPath: endpoint.path, executor: .init())
        XCTAssertThrowsError(try other.start())
        other.stop()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: endpoint.path)), Data("keep".utf8))
    }

    func testStopPreservesReplacementPathAndRejectsRestartOfStoppedService() throws {
        let endpoint = try ControlEndpoint(executor: .init())
        defer { endpoint.clean() }
        try endpoint.server.start()
        XCTAssertEqual(unlink(endpoint.path), 0)
        try Data("replacement".utf8).write(to: URL(fileURLWithPath: endpoint.path))
        endpoint.server.stop()
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: endpoint.path)), Data("replacement".utf8))
        XCTAssertThrowsError(try endpoint.server.start())
    }

    func testInvalidDirectoryAndOversizedPathFailWithoutLeavingSocket() throws {
        let endpoint = try ControlEndpoint(executor: .init())
        defer { endpoint.clean() }
        XCTAssertEqual(chmod(endpoint.directory.path, 0o777), 0)
        XCTAssertThrowsError(try endpoint.server.start())
        XCTAssertFalse(FileManager.default.fileExists(atPath: endpoint.path))
        XCTAssertEqual(chmod(endpoint.directory.path, 0o700), 0)
        let long = VPhoneHostControl(socketPath: endpoint.directory.appendingPathComponent(String(repeating: "x", count: 110)).path,
                                    executor: .init())
        XCTAssertThrowsError(try long.start())
        long.stop()
    }

    // MARK: - Concurrent clients

    /// A command that has not returned and a peer that has not finished its
    /// request line do not delay other clients of the same socket.
    func testSlowCommandAndSlowPeerDoNotBlockOtherClients() async throws {
        let guest = HostGuestFake()
        let gate = HostTestGate()
        guest.shellGate = gate
        let endpoint = try ControlEndpoint(executor: .init(control: guest))
        defer { endpoint.clean() }
        try endpoint.server.start()
        let slowCommand = Task { try await endpoint.rawRequest(["t": "shell", "cmd": "sleep"]) }
        try await waitUntil { gate.waiting > 0 }
        let slowPeer = try endpoint.connectClient()
        defer { close(slowPeer) }
        HostControlIO.writeResponse(Data("{\"t\":\"capab".utf8), to: slowPeer)

        let started = ContinuousClock.now
        let tasks = (0..<8).map { index in
            let command = index.isMultiple(of: 2) ? "capabilities" : "app_list"
            return Task { try await endpoint.rawRequest(["t": command]) }
        }
        var others: [Data] = []
        for task in tasks { others.append(try await task.value) }
        XCTAssertEqual(others.count, 8)
        XCTAssertTrue(try others.allSatisfy { try decodeResponse($0)["ok"] as? Bool == true })
        // Well below the 5 s request read deadline that the slow peer holds.
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
        XCTAssertEqual(guest.shellCalls, 1)

        gate.open()
        let finished = try decodeResponse(await slowCommand.value)
        XCTAssertEqual(finished["ok"] as? Bool, true)
        XCTAssertEqual(finished["stdout"] as? String, "out")
    }

    func testConnectionsBeyondTheLimitAreClosedWithoutAffectingAcceptedOnes() async throws {
        let guest = HostGuestFake()
        let gate = HostTestGate()
        guest.shellGate = gate
        let endpoint = try ControlEndpoint(executor: .init(control: guest))
        defer { endpoint.clean() }
        try endpoint.server.start()
        let held = (0..<HostControlIO.maximumConnections).map { _ in
            Task { try await endpoint.rawRequest(["t": "shell", "cmd": "hold"]) }
        }
        try await waitUntil { gate.waiting == HostControlIO.maximumConnections }
        let extra = try endpoint.connectClient()
        defer { close(extra) }
        let refused = try await Task.detached { try HostControlIO.readRequest(extra, timeout: 2) }.value
        XCTAssertNil(refused)
        gate.open()
        for request in held {
            let result = try decodeResponse(await request.value)
            XCTAssertEqual(result["ok"] as? Bool, true)
        }
        let after = try await endpoint.request(["t": "capabilities"])
        XCTAssertEqual(after["ok"] as? Bool, true)
    }

    // MARK: - Multiple VMs

    /// Two VM sockets with their own guests: a request names its VM and boot,
    /// and a request meant for the other VM changes nothing on this one.
    func testRequestsReachOnlyTheSocketOwnerAndWrongTargetIsRefused() async throws {
        let guestA = HostGuestFake()
        let guestB = HostGuestFake()
        let targetA = VPhoneHostTarget(vm: "vm-a", instanceID: "boot-a1", pid: 101, processStartedAt: 1.0)
        let targetB = VPhoneHostTarget(vm: "vm-b", instanceID: "boot-b1", pid: 202, processStartedAt: 2.0)
        let a = try ControlEndpoint(executor: .init(control: guestA, target: targetA))
        let b = try ControlEndpoint(executor: .init(control: guestB, target: targetB))
        defer { a.clean(); b.clean() }
        try a.server.start()
        try b.server.start()

        let discoveryA = try await a.request(["t": "capabilities"])
        XCTAssertEqual((discoveryA["target"] as? [String: Any])?["vm"] as? String, "vm-a")
        let wrongName = try await a.request(["t": "file_put", "path": "/x", "data_b64": "eA==",
                                             "target": ["vm": "vm-b"]])
        XCTAssertEqual(wrongName["code"] as? String, "target_mismatch")
        XCTAssertNil(guestA.uploaded)
        XCTAssertNil(guestB.uploaded)
        let wrongBoot = try await b.request(["t": "shell", "cmd": "id",
                                             "target": ["vm": "vm-b", "instance_id": "boot-a1"]])
        XCTAssertEqual(wrongBoot["code"] as? String, "target_mismatch")
        XCTAssertEqual(guestA.shellCalls + guestB.shellCalls, 0)

        let rightB = try await b.request(["t": "file_put", "path": "/x", "data_b64": "eA==",
                                          "target": ["vm": "vm-b", "instance_id": "boot-b1"]])
        XCTAssertEqual(rightB["ok"] as? Bool, true)
        XCTAssertEqual(guestB.uploaded?.0, "/x")
        XCTAssertNil(guestA.uploaded)
    }

    /// After the owner exits the path refuses connections; it never reaches
    /// another VM. A crashed owner's leftover socket file refuses as well.
    func testExitedTargetRefusesConnectionsAndStopCancelsInFlightCommands() async throws {
        let guest = HostGuestFake()
        let gate = HostTestGate()
        guest.shellGate = gate
        let target = VPhoneHostTarget(vm: "vm-a", instanceID: "boot-a1", pid: 101, processStartedAt: 1.0)
        let endpoint = try ControlEndpoint(executor: .init(control: guest, target: target))
        defer { endpoint.clean() }
        try endpoint.server.start()
        let inFlight = Task { () -> Data? in
            try? await endpoint.rawRequest(["t": "shell", "cmd": "hold"])
        }
        try await waitUntil { gate.waiting > 0 }
        endpoint.server.stop()
        // Either the cancellation reply or a closed connection; never success.
        if let stopped = await inFlight.value {
            XCTAssertEqual(try decodeResponse(stopped)["code"] as? String, "command_cancelled")
        }
        XCTAssertThrowsError(try endpoint.connectClient())
        XCTAssertFalse(FileManager.default.fileExists(atPath: endpoint.path))

        // A crashed process leaves the socket file without a listener.
        let leftover = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = endpoint.address()
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(leftover, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(leftover)
        XCTAssertEqual(bound, 0)
        XCTAssertThrowsError(try endpoint.connectClient())
        gate.open()
        XCTAssertEqual(guest.shellCalls, 1)
    }

    /// The restarted VM binds the same path with a new boot instance. A client
    /// that still holds the old boot's identity is refused; the new boot's
    /// guest receives nothing from it.
    func testRestartedVMRejectsRequestsBoundToThePreviousBoot() async throws {
        let oldGuest = HostGuestFake()
        let first = try ControlEndpoint(executor: .init(control: oldGuest, target: .init(
            vm: "vm-a", instanceID: "boot-1", pid: 101, processStartedAt: 1.0)))
        defer { first.clean() }
        try first.server.start()
        let before = try await first.request(["t": "capabilities"])
        let oldIdentity = try XCTUnwrap(before["target"] as? [String: Any])
        first.server.stop()

        let newGuest = HostGuestFake()
        let restarted = VPhoneHostControl(socketPath: first.path, executor: .init(control: newGuest, target: .init(
            vm: "vm-a", instanceID: "boot-2", pid: 303, processStartedAt: 3.0)))
        defer { restarted.stop() }
        try restarted.start()
        let stale = try await first.request(["t": "shell", "cmd": "id", "target": oldIdentity])
        XCTAssertEqual(stale["code"] as? String, "target_mismatch")
        XCTAssertEqual((stale["target"] as? [String: Any])?["instance_id"] as? String, "boot-2")
        let byPID = try await first.request(["t": "shell", "cmd": "id",
                                             "target": ["vm": "vm-a", "pid": 101]])
        XCTAssertEqual(byPID["code"] as? String, "target_mismatch")
        XCTAssertEqual(newGuest.shellCalls + oldGuest.shellCalls, 0)
        let current = try await first.request(["t": "shell", "cmd": "id",
                                               "target": ["vm": "vm-a", "instance_id": "boot-2"]])
        XCTAssertEqual(current["ok"] as? Bool, true)
        XCTAssertEqual(newGuest.shellCalls, 1)
        XCTAssertEqual(oldGuest.shellCalls, 0)
    }

    func testStopClosesSlowClientsAndDoesNotAffectAnotherEndpoint() async throws {
        let first = try ControlEndpoint(executor: .init())
        let second = try ControlEndpoint(executor: .init())
        defer { first.clean(); second.clean() }
        try first.server.start()
        try second.server.start()
        let fd = try first.connectClient()
        defer { close(fd) }
        // A completed request on another connection establishes that this
        // listener has drained earlier accepted connections on its serial queue.
        _ = try await first.request(["t": "capabilities"])
        first.server.stop()
        let eof = try await Task.detached { try HostControlIO.readRequest(fd, timeout: 1) }.value
        XCTAssertNil(eof)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        let alive = try await second.request(["t": "capabilities"])
        XCTAssertEqual(alive["ok"] as? Bool, true)
    }
}
