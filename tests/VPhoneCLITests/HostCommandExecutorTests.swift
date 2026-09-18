import Foundation
import XCTest
import VPhoneCore
@testable import vphone_cli

@MainActor
final class HostGuestFake: VPhoneHostGuest {
    var isConnected = true
    var guestCaps = ["hid", "shell", "file", "apps", "url", "clipboard", "location", "location_owned", "vcam_status", "vcam_receipt_v3", "ipa_install"]
    var failure: Error?
    var uploaded: (String, Data, String)?
    var request: [String: Any] = [:]
    var cameraReply: [String: Any]?
    var cameraReplyHook: (() -> Void)?
    var cameraIDProvider: (() -> String)?
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
            cameraReplyHook?()
            if let cameraReply { return (cameraReply, nil) }
            return (["generation": dict["generation"]!, "presentation_id": cameraIDProvider?() ?? "",
                     "vphoned_published_frame_index": 3,
                     "libvcam_observed_frame_index": 2], nil)
        }
        return (["t": "ok", "msg": "installed", "bundle_id": "app"], nil)
    }
}

@MainActor
final class HostScreenFake: VPhoneHostScreen {
    var isAvailable = true
    var colors: [Bool] = []
    var failure: Error?
    var tapped: (Double, Double)?
    var swipeDuration: Int?
    /// false makes the fake behave like a full gesture queue.
    var acceptsGestures = true
    func saveScreenshot(to url: URL) async throws -> URL { if let failure { throw failure }; return url }
    func captureCompactScreenshot(color: Bool) async -> String? { colors.append(color); return "jpeg" }
    func tap(x: Double, y: Double) -> Bool { tapped = (x, y); return acceptsGestures }
    func swipe(fromX: Double, fromY: Double, toX: Double, toY: Double, durationMs: Int) -> Bool {
        swipeDuration = durationMs
        return acceptsGestures
    }
}

@MainActor
final class HostCameraFake: VPhoneHostCamera {
    var isConnected = true
    var accepts = true
    var presented: String?
    var presentationID = UUID().uuidString
    var role = "qr"
    var imagePath: String?
    var videoPath: String?
    func present(imagePath: String, generation: String, role: String, fps: Double) -> Bool {
        self.imagePath = imagePath
        presented = generation; presentationID = UUID().uuidString; self.role = role; return accepts
    }
    func present(videoPath: String, generation: String, role: String, fps: Double) -> Bool {
        self.videoPath = videoPath
        presented = generation; presentationID = UUID().uuidString; self.role = role; return accepts
    }
    func presentNeutral(generation: String, fps: Double) -> Bool {
        present(imagePath: "", generation: generation, role: "neutral", fps: fps)
    }
    func hostStatus(generation: String) -> [String: Any] {
        ["generation": presented ?? "", "presentation_id": presentationID, "role": role,
         "streaming": presented != nil, "connected": isConnected]
    }
    func stop(generation: String) -> Bool {
        guard generation == presented else { return false }
        presented = nil
        return true
    }
}

@MainActor
final class HostLocationGuestFake: VPhoneSystemLocationGuestAdapter {
    var failure: VPhoneSystemLocationError?
    var fixes: [VPhoneSystemLocationFix] = []
    func requireOwnedLocationCapability() throws { if let failure { throw failure } }
    func activate(generation: String) async throws {}
    func deliver(_ fix: VPhoneSystemLocationFix, generation: String, deliverySequence: Int) async throws { fixes.append(fix) }
    func clear(generation: String?) async throws {}
}

@MainActor
final class HostLocationFake: VPhoneHostLocation {
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
        guest.cameraIDProvider = { camera.presentationID }
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

    func testAppLaunchAvailabilityFollowsSplitAppsCapability() async throws {
        let guest = HostGuestFake()
        let executor = VPhoneHostCommandExecutor(control: guest, screen: HostScreenFake())
        let base = ["hid", "shell", "file", "clipboard"]
        // (guest caps, app_launch, app_list/app_terminate/app_foreground, open_url)
        let cases: [([String], Bool, Bool, Bool)] = [
            // Legacy guest (no apps_v2): apps keeps implying app_launch.
            (base + ["apps", "url"], true, true, true),
            // Split guest without uiopen (regular/dev/less).
            (base + ["apps_v2", "apps"], false, true, false),
            // Split guest with uiopen (jb/exp).
            (base + ["apps_v2", "apps", "app_launch", "url"], true, true, true),
            // app_launch still requires apps (handler rejects when apps failed to load).
            (base + ["apps_v2", "app_launch", "url"], false, false, true),
            (base, false, false, false),
        ]
        for (caps, launch, query, url) in cases {
            guest.guestCaps = caps
            let snapshot = try await call(executor, ["t": "capabilities"])
            let commands = try XCTUnwrap(snapshot["commands"] as? [String: Bool])
            XCTAssertEqual(commands["app_launch"], launch, "\(caps)")
            for name in ["app_list", "app_terminate", "app_foreground"] {
                XCTAssertEqual(commands[name], query, "\(name) \(caps)")
            }
            XCTAssertEqual(commands["open_url"], url, "\(caps)")
        }
        guest.isConnected = false
        guest.guestCaps = base + ["apps_v2", "apps", "app_launch", "url"]
        let offline = try await call(executor, ["t": "capabilities"])
        XCTAssertEqual((offline["commands"] as? [String: Bool])?["app_launch"], false)
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
        guest.cameraIDProvider = { camera.presentationID }
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

    func testCameraVideoPresentationUsesVideoProducerAndReceiptSemantics() async throws {
        let guest = HostGuestFake()
        let camera = HostCameraFake()
        guest.cameraIDProvider = { camera.presentationID }
        let executor = VPhoneHostCommandExecutor(control: guest, camera: camera)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let present = try await call(executor, [
            "t": "camera_present", "source": "video", "path": url.path,
            "generation": "video-loop", "role": "test", "fps": 10,
        ])

        XCTAssertEqual(present["ok"] as? Bool, true)
        XCTAssertEqual(present["source"] as? String, "video")
        XCTAssertEqual(camera.videoPath, url.path)
        XCTAssertNil(camera.imagePath)
        XCTAssertNotNil(present["transport_receipt"])
    }

    func testCameraPresentRejectsUnknownSourceBeforeChangingPresentation() async throws {
        let camera = HostCameraFake()
        camera.presented = "existing"
        let executor = VPhoneHostCommandExecutor(control: HostGuestFake(), camera: camera)
        let result = try await call(executor, [
            "t": "camera_present", "source": "stream", "path": "/missing",
            "generation": "new",
        ])
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(result["code"] as? String, "invalid_argument")
        XCTAssertEqual(camera.presented, "existing")
        XCTAssertNil(camera.imagePath)
        XCTAssertNil(camera.videoPath)
    }

    func testRepeatedGenerationCannotUseAnOldPresentationReceipt() async throws {
        let guest = HostGuestFake()
        let camera = HostCameraFake()
        guest.cameraIDProvider = { camera.presentationID }
        camera.presented = "g"
        let oldID = camera.presentationID
        let executor = VPhoneHostCommandExecutor(control: guest, camera: camera)
        guest.cameraReply = ["generation": "g", "presentation_id": oldID,
                             "vphoned_published_frame_index": 4, "libvcam_observed_frame_index": 3]
        _ = camera.present(imagePath: "", generation: "g", role: "qr", fps: 8)
        let status = try await call(executor, ["t": "camera_status", "generation": "g"])
        XCTAssertNil(status["transport_receipt"])
        let stop = try await call(executor, ["t": "camera_stop", "generation": "g", "presentation_id": oldID])
        XCTAssertEqual(stop["ok"] as? Bool, false)
        XCTAssertEqual(camera.presented, "g")
        guest.cameraReply = nil
        let fresh = try await call(executor, ["t": "camera_status", "generation": "g"])
        XCTAssertEqual((fresh["transport_receipt"] as? [String: Any])?["presentation_id"] as? String, camera.presentationID)
    }

    func testSameGenerationReplacementDuringReplyInvalidatesTheRequest() async throws {
        let guest = HostGuestFake()
        let camera = HostCameraFake()
        camera.presented = "g"
        guest.cameraIDProvider = { camera.presentationID }
        guest.cameraReplyHook = { _ = camera.presentNeutral(generation: "g", fps: 8) }
        let executor = VPhoneHostCommandExecutor(control: guest, camera: camera)
        let status = try await call(executor, ["t": "camera_status", "generation": "g"])
        XCTAssertNil(status["transport_receipt"])
    }

    func testExplicitNeutralPolicyWaitsForItsOwnReceiptAndKeepsStreaming() async throws {
        let guest = HostGuestFake()
        let camera = HostCameraFake()
        camera.presented = "qr"
        guest.cameraIDProvider = { camera.presentationID }
        let executor = VPhoneHostCommandExecutor(control: guest, camera: camera)
        let result = try await call(executor, ["t": "camera_stop", "generation": "qr", "policy": "neutral"])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["role"] as? String, "neutral")
        XCTAssertEqual(result["streaming"] as? Bool, true)
        XCTAssertNotEqual(result["generation"] as? String, "qr")
        XCTAssertEqual((result["transport_receipt"] as? [String: Any])?["presentation_id"] as? String, camera.presentationID)
        let off = try await call(executor, ["t": "camera_stop", "generation": camera.presented!])
        XCTAssertEqual(off["stop_policy"] as? String, "keep_last")
        XCTAssertEqual(off["streaming"] as? Bool, false)
        XCTAssertEqual(off["guest_frame_cleared"] as? Bool, false)
    }

    func testNeutralPolicyDoesNotChangeSourceWhenUnavailableOrInvalid() async throws {
        let guest = HostGuestFake()
        let camera = HostCameraFake()
        camera.presented = "g"
        camera.isConnected = false
        let executor = VPhoneHostCommandExecutor(control: guest, camera: camera)
        for policy: Any in ["neutral", "invalid", 7] {
            let result = try await call(executor, ["t": "camera_stop", "generation": "g", "policy": policy])
            XCTAssertEqual(result["ok"] as? Bool, false)
            XCTAssertEqual(camera.presented, "g")
        }
    }

    func testNeutralProducerAndPresentationIdentityWithoutVM() throws {
        let frame = try XCTUnwrap(VPhoneNeutralFrameProducer(width: 2, height: 2).nextFrame())
        XCTAssertEqual(frame.pixels, Data(repeating: 255, count: 16))
        XCTAssertEqual(frame.bytesPerRow, 8)
        let camera = VPhoneCameraServer()
        _ = camera.presentNeutral(generation: "g", fps: 8)
        let first = camera.presentationID
        _ = camera.presentNeutral(generation: "g", fps: 8)
        XCTAssertNotEqual(first, camera.presentationID)
        XCTAssertEqual(camera.currentRole, "neutral")
        camera.setSource(.testPattern)
        XCTAssertTrue(camera.presentationID.isEmpty)
        XCTAssertTrue(camera.currentGeneration.isEmpty)
    }

    func testCameraGenerationFitsGuestUTF8Field() {
        XCTAssertTrue(VPhoneHostCommandExecutor.validCameraGeneration(String(repeating: "a", count: 79)))
        XCTAssertFalse(VPhoneHostCommandExecutor.validCameraGeneration(String(repeating: "a", count: 80)))
        XCTAssertTrue(VPhoneHostCommandExecutor.validCameraGeneration(String(repeating: "中", count: 26)))
        XCTAssertFalse(VPhoneHostCommandExecutor.validCameraGeneration(String(repeating: "中", count: 27)))
        XCTAssertFalse(VPhoneHostCommandExecutor.validCameraGeneration(""))
        XCTAssertFalse(VPhoneHostCommandExecutor.validCameraGeneration("a\0b"))
    }

    func testCameraStatusAfterStopDoesNotReturnRetainedGuestReceipt() async throws {
        let guest = HostGuestFake()
        let camera = HostCameraFake()
        guest.cameraIDProvider = { camera.presentationID }
        camera.presented = "g"
        let executor = VPhoneHostCommandExecutor(control: guest, camera: camera)
        _ = try await call(executor, ["t": "camera_stop", "generation": "g"])
        let status = try await call(executor, ["t": "camera_status", "generation": "g"])
        XCTAssertEqual(status["streaming"] as? Bool, false)
        XCTAssertNil(status["transport_receipt"])
    }

    func testCameraSourceSwitchDuringGuestReplyCannotReturnOldReceipt() async throws {
        let guest = HostGuestFake()
        let camera = HostCameraFake()
        guest.cameraIDProvider = { camera.presentationID }
        camera.presented = "g"
        guest.cameraReplyHook = { camera.presented = "new" }
        let executor = VPhoneHostCommandExecutor(control: guest, camera: camera)
        let status = try await call(executor, ["t": "camera_status", "generation": "g"])
        XCTAssertNil(status["transport_receipt"])
        XCTAssertEqual(status["generation"] as? String, "new")
    }

    func testCameraRejectsImpossibleAndUnconsumedGuestReceipts() async throws {
        let guest = HostGuestFake()
        let camera = HostCameraFake()
        guest.cameraIDProvider = { camera.presentationID }
        camera.presented = "g"
        let executor = VPhoneHostCommandExecutor(control: guest, camera: camera)
        for fields: [String: Any] in [
            ["generation": "g", "vphoned_published_frame_index": 2, "libvcam_observed_frame_index": 3],
            ["generation": "g", "vphoned_published_frame_index": 2, "libvcam_observed_frame_index": 0],
            ["generation": "old", "vphoned_published_frame_index": 2, "libvcam_observed_frame_index": 1]
        ] {
            guest.cameraReply = fields.merging(["presentation_id": camera.presentationID]) { _, new in new }
            let status = try await call(executor, ["t": "camera_status", "generation": "g"])
            XCTAssertNil(status["transport_receipt"])
        }
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
