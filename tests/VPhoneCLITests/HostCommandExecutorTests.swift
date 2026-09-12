import Foundation
import XCTest
import VPhoneCore
@testable import vphone_cli

@MainActor
private final class HostGuestFake: VPhoneHostGuest {
    var isConnected = true
    var guestCaps = ["hid", "shell", "file", "apps", "url", "clipboard", "location", "location_owned", "vcam_status", "ipa_install"]
    var failure: Error?
    var uploaded: (String, Data, String)?
    var request: [String: Any] = [:]
    var shellArgs: (String, String?, Int?)?
    var text: String?
    func check() throws { if let failure { throw failure } }
    func sendHIDPress(page: UInt32, usage: UInt32) {}
    func clipboardSet(text: String) async throws { try check(); self.text = text }
    func runShell(command: String, cwd: String?, timeoutMs: Int?) async throws -> VPhoneControl.ShellResult {
        try check()
        shellArgs = (command, cwd, timeoutMs)
        return .init(stdout: "out", stderr: "err", exitCode: 7, timedOut: false, truncated: true)
    }
    func downloadFile(path: String) async throws -> Data { try check(); return Data([0, 255, 10]) }
    func uploadFile(path: String, data: Data, permissions: String) async throws {
        try check(); uploaded = (path, data, permissions)
    }
    func appLaunch(bundleId: String, url: String?) async throws -> Int { try check(); return 42 }
    func appTerminate(bundleId: String) async throws { try check() }
    func appList(filter: String) async throws -> [VPhoneControl.AppInfo] {
        try check()
        return [.init(bundleId: "app", name: "Test", version: "1", type: "User", state: "running", pid: 42, path: "/app", dataContainer: "/data")]
    }
    func appForeground() async throws -> (bundleId: String, name: String, pid: Int, source: String) {
        try check(); return ("app", "Test", 42, "sbs")
    }
    func openURL(_ url: String) async throws { try check() }
    func sendRequest(_ dict: [String: Any]) async throws -> ([String: Any], Data?) {
        try check(); request = dict
        if dict["t"] as? String == "vcam_status" {
            return (["generation": dict["generation"]!, "vphoned_published_frame_index": 3,
                     "libvcam_observed_frame_index": 2], nil)
        }
        return (["t": "ok", "msg": "installed", "bundle_id": "app"], nil)
    }
}

@MainActor
private final class HostScreenFake: VPhoneHostScreen {
    var isAvailable = true
    var colors: [Bool] = []
    var failure: Error?
    var tapped: (Double, Double)?
    var swipeDuration: Int?
    func saveScreenshot(to url: URL) async throws -> URL { if let failure { throw failure }; return url }
    func captureCompactScreenshot(color: Bool) async -> String? { colors.append(color); return "jpeg" }
    func tap(x: Double, y: Double) { tapped = (x, y) }
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int) { swipeDuration = durationMs }
}

@MainActor
private final class HostCameraFake: VPhoneHostCamera {
    var isConnected = true
    var accepts = true
    var presented: String?
    func present(imagePath: String, generation: String, role: String, fps: Double) -> Bool {
        presented = generation; return accepts
    }
    func hostStatus(generation: String) -> [String: Any] { ["generation": generation, "streaming": true] }
    func stop(generation: String) -> Bool { generation == presented }
}

@MainActor
private final class HostLocationGuestFake: VPhoneSystemLocationGuestAdapter {
    var failure: VPhoneSystemLocationError?
    var fixes: [VPhoneSystemLocationFix] = []
    func requireOwnedLocationCapability() throws { if let failure { throw failure } }
    func activate(generation: String) async throws {}
    func deliver(_ fix: VPhoneSystemLocationFix, generation: String, deliverySequence: Int) async throws { fixes.append(fix) }
    func clear(generation: String?) async throws {}
}

@MainActor
private final class HostLocationFake: VPhoneHostLocation {
    let guest = HostLocationGuestFake()
    lazy var systemLocationController = VPhoneSystemLocationController(adapter: guest)
    var ownershipChecks = 0
    func externalControlCheck() -> @MainActor () throws -> Void {
        { self.ownershipChecks += 1 }
    }
}

@MainActor
final class HostCommandExecutorTests: XCTestCase {
    private func call(_ executor: VPhoneHostCommandExecutor, _ fields: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: fields)
        let result = await executor.execute(data)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: result) as? [String: Any])
    }

    func testWithoutViewReportsCapabilitiesAndRejectsUnavailableOperations() async throws {
        let executor = VPhoneHostCommandExecutor()
        let caps = try await call(executor, ["t": "capabilities"])
        let commands = try XCTUnwrap(caps["commands"] as? [String: Bool])
        XCTAssertEqual(commands["capabilities"], true)
        for name in ["screenshot", "shell", "file_put", "app_list", "location_source_set", "camera_present"] {
            XCTAssertEqual(commands[name], false)
        }
        for request: [String: Any] in [["t": "screenshot"], ["t": "shell", "cmd": "true"],
                                     ["t": "file_get", "path": "/x"], ["t": "app_list"],
                                     ["t": "location_source_status"], ["t": "camera_status", "generation": "g"]] {
            let result = try await call(executor, request)
            XCTAssertEqual(result["ok"] as? Bool, false)
            XCTAssertNotNil(result["error"])
        }
    }

    func testCapabilitiesFollowConnectionAndScreenChanges() async throws {
        let guest = HostGuestFake()
        let screen = HostScreenFake()
        let camera = HostCameraFake()
        let executor = VPhoneHostCommandExecutor(control: guest, camera: camera, screen: screen)
        let first = try await call(executor, ["t": "capabilities"])
        XCTAssertEqual((first["commands"] as? [String: Bool])?["shell"], true)
        guest.isConnected = false
        screen.isAvailable = false
        camera.isConnected = false
        let second = try await call(executor, ["t": "capabilities"])
        let commands = try XCTUnwrap(second["commands"] as? [String: Bool])
        XCTAssertEqual(commands["shell"], false)
        XCTAssertEqual(commands["screenshot"], false)
        XCTAssertEqual(commands["camera_present"], false)
    }

    func testShellFieldsAndScreenOptInArePreserved() async throws {
        let guest = HostGuestFake()
        let screen = HostScreenFake()
        let executor = VPhoneHostCommandExecutor(control: guest, screen: screen)
        let result = try await call(executor, ["t": "shell", "cmd": "exit 7", "cwd": "/tmp", "timeout_ms": 123])
        XCTAssertEqual(result["stdout"] as? String, "out")
        XCTAssertEqual(result["stderr"] as? String, "err")
        XCTAssertEqual(result["code"] as? Int, 7)
        XCTAssertEqual(result["timed_out"] as? Bool, false)
        XCTAssertEqual(result["truncated"] as? Bool, true)
        XCTAssertEqual(guest.shellArgs?.1, "/tmp")
        XCTAssertEqual(guest.shellArgs?.2, 123)
        XCTAssertTrue(screen.colors.isEmpty)
        let withScreen = try await call(executor, ["t": "shell", "cmd": "true", "screen": true])
        XCTAssertEqual(withScreen["image"] as? String, "jpeg")
    }

    func testFilesPreserveBytesPermissionsAndHostPathModes() async throws {
        let guest = HostGuestFake()
        let executor = VPhoneHostCommandExecutor(control: guest)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let downloaded = try await call(executor, ["t": "file_get", "path": "/guest"])
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(downloaded["data"] as? String)), Data([0, 255, 10]))
        let saved = try await call(executor, ["t": "file_get", "path": "/guest", "save": url.path])
        XCTAssertEqual(saved["path"] as? String, url.path)
        XCTAssertEqual(try Data(contentsOf: url), Data([0, 255, 10]))
        _ = try await call(executor, ["t": "file_put", "path": "/guest", "load": url.path, "perm": "600"])
        XCTAssertEqual(guest.uploaded?.1, Data([0, 255, 10]))
        XCTAssertEqual(guest.uploaded?.2, "600")
        _ = try await call(executor, ["t": "file_put", "path": "/guest", "data_b64": "eA==", "load": "/missing"])
        XCTAssertEqual(guest.uploaded?.1, Data("x".utf8))
        XCTAssertEqual(guest.uploaded?.2, "644")
    }

    func testAppAndInputDefaultsKeepCompactScreenPolicy() async throws {
        let guest = HostGuestFake()
        let screen = HostScreenFake()
        let executor = VPhoneHostCommandExecutor(control: guest, screen: screen)
        for fields: [String: Any] in [["t": "app_launch", "bundle_id": "app"],
                                    ["t": "app_terminate", "bundle_id": "app"],
                                    ["t": "open_url", "url": "test://x"],
                                    ["t": "type", "text": "中文"], ["t": "key", "name": "home"],
                                    ["t": "tap", "x": 1, "y": 2],
                                    ["t": "swipe", "x1": 1, "y1": 2, "x2": 3, "y2": 4, "ms": 0]] {
            var request = fields
            request["delay"] = 0
            let result = try await call(executor, request)
            XCTAssertEqual(result["ok"] as? Bool, true)
            XCTAssertEqual(result["image"] as? String, "jpeg")
        }
        XCTAssertEqual(guest.text, "中文")
        XCTAssertEqual(screen.tapped?.0, 1)
        XCTAssertEqual(screen.swipeDuration, 0)
        let before = screen.colors.count
        let apps = try await call(executor, ["t": "app_list"])
        XCTAssertEqual((apps["apps"] as? [[String: Any]])?.first?["data_container"] as? String, "/data")
        let foreground = try await call(executor, ["t": "app_foreground"])
        XCTAssertEqual(foreground["source"] as? String, "sbs")
        _ = try await call(executor, ["t": "type", "text": "x", "screen": false])
        XCTAssertEqual(screen.colors.count, before)
        let install = try await call(executor, ["t": "ipa_install", "path": "/a.ipa", "cert_path": "/cert"])
        XCTAssertEqual(guest.request["registration"] as? String, "User")
        XCTAssertEqual(guest.request["cert_path"] as? String, "/cert")
        XCTAssertEqual(install["msg"] as? String, "installed")
    }

    func testGuestFailuresAndScreenshotFailuresRemainErrors() async throws {
        let guest = HostGuestFake()
        guest.failure = VPhoneControl.ControlError.protocolError("test rejection")
        let screen = HostScreenFake()
        screen.failure = CocoaError(.fileWriteNoPermission)
        let executor = VPhoneHostCommandExecutor(control: guest, screen: screen)
        for request: [String: Any] in [["t": "shell", "cmd": "x"], ["t": "file_get", "path": "/x"],
                                     ["t": "app_list"], ["t": "screenshot", "path": "/x.png"]] {
            let result = try await call(executor, request)
            XCTAssertEqual(result["ok"] as? Bool, false)
            XCTAssertNotNil(result["error"])
        }
    }

    func testInvalidDelaysFailBeforeScreenInput() async throws {
        let screen = HostScreenFake()
        let executor = VPhoneHostCommandExecutor(screen: screen)
        for fields: [String: Any] in [["t": "tap", "x": 1, "y": 2, "delay": -1],
                                     ["t": "swipe", "x1": 1, "y1": 2, "x2": 3, "y2": 4, "ms": -1]] {
            let result = try await call(executor, fields)
            XCTAssertEqual(result["code"] as? String, "invalid_argument")
        }
        XCTAssertNil(screen.tapped)
        XCTAssertNil(screen.swipeDuration)
    }

    func testScreenshotAlwaysCapturesAndSupportsColor() async throws {
        let screen = HostScreenFake()
        let executor = VPhoneHostCommandExecutor(screen: screen)
        let result = try await call(executor, ["t": "screenshot", "screen": false, "color": true, "path": "/tmp/test.png"])
        XCTAssertEqual(result["image"] as? String, "jpeg")
        XCTAssertEqual(result["path"] as? String, "/tmp/test.png")
        XCTAssertEqual(screen.colors, [true])
    }

    func testCameraPreservesReceiptAndConflictSemantics() async throws {
        let guest = HostGuestFake()
        let camera = HostCameraFake()
        let executor = VPhoneHostCommandExecutor(control: guest, camera: camera)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let present = try await call(executor, ["t": "camera_present", "path": url.path, "generation": "g"])
        XCTAssertEqual(present["ok"] as? Bool, true)
        let receipt = try XCTUnwrap(present["transport_receipt"] as? [String: Any])
        XCTAssertEqual(receipt["libvcam_observed_frame_index"] as? Int, 2)
        let status = try await call(executor, ["t": "camera_status", "generation": "g"])
        XCTAssertEqual(status["streaming"] as? Bool, true)
        let conflict = try await call(executor, ["t": "camera_stop", "generation": "old"])
        XCTAssertEqual(conflict["ok"] as? Bool, false)
        guest.failure = VPhoneControl.ControlError.notConnected
        let failed = try await call(executor, ["t": "camera_present", "path": url.path, "generation": "g"])
        XCTAssertEqual(failed["ok"] as? Bool, false)
        XCTAssertEqual(failed["generation"] as? String, "g")
    }

    func testLocationUsesRealControllerWithFakeGuestAndPreservesCodes() async throws {
        let location = HostLocationFake()
        let executor = VPhoneHostCommandExecutor(location: location)
        let result = try await call(executor, ["t": "location_source_set", "mode": "fixed", "owner": "test", "coordinate_system": "wgs84", "producer_sequence": 0,
                                              "lat": 31.2, "lon": 121.5, "timestamp": 1_700_000_000, "heartbeat_s": 3600])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(location.guest.fixes.last?.latitude, 31.2)
        XCTAssertGreaterThan(location.ownershipChecks, 0)
        let generation = try XCTUnwrap(result["generation"] as? String)
        let stopped = try await call(executor, ["t": "location_source_stop", "generation": generation])
        XCTAssertEqual(stopped["ok"] as? Bool, true)
        location.guest.failure = .init(code: "location_guest_unavailable", message: "unavailable")
        let failed = try await call(executor, ["t": "location_stream_start", "owner": "test", "coordinate_system": "wgs84"])
        XCTAssertEqual(failed["code"] as? String, "location_guest_unavailable")
    }
}
