import Darwin
import Foundation
import XCTest
import VPhoneCore
@testable import vphone_cli

@MainActor
private final class ControlEndpoint {
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
        let data = try JSONSerialization.data(withJSONObject: fields)
        let fd = try connectClient()
        defer { close(fd) }
        let response = try await Task.detached {
            HostControlIO.writeResponse(data + Data([10]), to: fd)
            return try XCTUnwrap(HostControlIO.readRequest(fd))
        }.value
        return try XCTUnwrap(JSONSerialization.jsonObject(with: response) as? [String: Any])
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
