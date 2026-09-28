import Foundation
import XCTest
import VPhoneAPIKit
@testable import vphone_cli

@MainActor
private final class HostAPISessionFake: VPhoneHostAPISession {
    var state = "ready"
    var caps = ["apps", "session_identity"]
    var generation = UUID()
    var calls: [(String, [String: VPhoneJSONValue], String?)] = []
    var handler: (() async throws -> VPhoneJSONValue)?
    var result: VPhoneJSONValue = .object(["apps": .array([])])
    var snapshot: VPhoneAPISession.Snapshot {
        get {
            let health: [String: Any] = ["apiVersion": 1, "binaryHash": String(repeating: "a", count: 64),
                "capabilities": caps, "instanceID": "BC862B51-525B-4E20-B6A1-A55193A615FC"]
            var value: [String: Any] = ["vmInstanceID": "fixture", "state": state]
            if state == "ready" { value["generation"] = generation.uuidString; value["health"] = health }
            return try! JSONDecoder().decode(VPhoneAPISession.Snapshot.self, from: JSONSerialization.data(withJSONObject: value))
        }
    }
    func uploadFile(_ source: VPhoneAPIUpload, path: String, permissions: String) async throws { throw URLError(.unsupportedURL) }
    func downloadFile(path: String, maximumBytes: Int, stagingDirectory: URL) async throws -> VPhoneAPIDownload {
        throw URLError(.unsupportedURL)
    }
    func call(_ method: String, params: [String: VPhoneJSONValue], requiring capability: String?) async throws -> VPhoneJSONValue {
        calls.append((method, params, capability))
        if let handler { return try await handler() }
        return result
    }
}

@MainActor
final class HostAPICommandTests: XCTestCase {
    private func call(_ executor: VPhoneHostCommandExecutor, _ fields: [String: Any]) async throws -> [String: Any] {
        let data = await executor.execute(try JSONSerialization.data(withJSONObject: fields))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private var app: VPhoneJSONValue {
        .object(["bundle_id": .string("fixture.app"), "name": .string("中文 App"), "version": .string("2"),
            "type": .string("user"), "state": .string("running"), "pid": .number(42),
            "path": .string("/Applications/Fixture.app"), "data_path": .string("/data/fixture"),
            "unmapped": .string("not returned")])
    }

    func testUnixSocketToManagedWebSocketWithoutClassicGuest() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("api-commands-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process()
        process.executableURL = root.appendingPathComponent(".venv/bin/python3")
        process.arguments = [root.appendingPathComponent("tests/fixtures/host_api/server.py").path, directory.path, "--host-commands"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        var port: Int?
        var deadline = ContinuousClock.now + .seconds(10)
        while port == nil, process.isRunning, ContinuousClock.now < deadline {
            port = (try? String(contentsOf: directory.appendingPathComponent("port"), encoding: .utf8)).flatMap(Int.init)
            if port == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(try XCTUnwrap(port))"))
        let session = VPhoneAPISession(client: try VPhoneAPIClient(baseURL: url, token: "1234567890abcdef", timeout: 5),
                                      vmInstanceID: "loopback-runtime")
        defer { session.stop() }
        session.start()
        deadline = ContinuousClock.now + .seconds(10)
        while session.snapshot.state != .ready, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(session.snapshot.state, .ready)
        let endpoint = try ControlEndpoint(executor: .init(apiSession: session))
        defer { endpoint.clean() }
        try endpoint.server.start()
        let discovery = try await endpoint.request(["t": "capabilities"])
        XCTAssertEqual((discovery["commands"] as? [String: Bool])?["app_list"], false)
        XCTAssertEqual((discovery["api_commands"] as? [String: Bool])?["app_list"], true)
        let apps = try await endpoint.request(["t": "app_list", "transport": "api", "filter": "user"])
        XCTAssertEqual(apps["ok"] as? Bool, true)
        XCTAssertEqual((apps["apps"] as? [[String: Any]])?.first?["data_container"] as? String, "/data/loopback")
        let foreground = try await endpoint.request(["t": "app_foreground", "transport": "api"])
        XCTAssertEqual(foreground["verified"] as? Bool, false)
        XCTAssertEqual(foreground["pid"] as? Int, 42)
        let launched = try await endpoint.request(["t": "app_launch", "transport": "api", "bundle_id": "loopback.app", "screen": false])
        XCTAssertEqual(launched["pid"] as? Int, 42)
        XCTAssertEqual(launched["frontmost_verified"] as? Bool, false)
        let terminated = try await endpoint.request(["t": "app_terminate", "transport": "api", "bundle_id": "loopback.app", "screen": false])
        XCTAssertEqual(terminated["ok"] as? Bool, true)
        XCTAssertEqual(terminated["pids"] as? [Int], [42])
        XCTAssertEqual((discovery["api_commands"] as? [String: Bool])?["file_get"], true)
        let inline = try await endpoint.request(["t": "file_get", "transport": "api", "path": "/bytes/256"])
        XCTAssertEqual(inline["size"] as? Int, 256)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(inline["data"] as? String)), Data(UInt8.min...UInt8.max))
        let save = directory.appendingPathComponent("saved-download").path
        let saved = try await endpoint.request(["t": "file_get", "transport": "api", "path": "/bytes/2097152", "save": save])
        XCTAssertEqual(saved["ok"] as? Bool, true)
        XCTAssertEqual(saved["path"] as? String, save)
        XCTAssertEqual(saved["size"] as? Int, 2097152)
        let duplicate = try await endpoint.request(["t": "file_get", "transport": "api", "path": "/bytes/0", "save": save])
        XCTAssertEqual(duplicate["code"] as? String, "destination_exists")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: save)[.size] as? Int, 2097152)
        for (path, destination) in [("/bytes/1048577", nil), ("/bytes/67108865", save + "-large")] as [(String, String?)] {
            var request: [String: Any] = ["t": "file_get", "transport": "api", "path": path]
            request["save"] = destination
            let rejected = try await endpoint.request(request)
            XCTAssertEqual(rejected["code"] as? String, "file_too_large")
        }
        for fields: [String: Any] in [["path": "relative"], ["path": "/x", "save": 1],
                                      ["path": "/x", "save": "relative"], ["path": "/x", "save": "/tmp/"]] {
            var request: [String: Any] = ["t": "file_get", "transport": "api"]
            request.merge(fields) { _, value in value }
            let invalid = try await endpoint.request(request)
            XCTAssertEqual(invalid["code"] as? String, "invalid_argument")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: save + "-large"))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".vphone-download-") })
        XCTAssertEqual((discovery["api_commands"] as? [String: Bool])?["file_put"], true)
        for fields: [String: Any] in [["data_b64": "AP8B", "load": "/missing", "perm": "640"],
                                      ["load": save, "perm": "600"], ["data_b64": ""]] {
            var request: [String: Any] = ["t": "file_put", "transport": "api", "path": "/中文+ upload"]
            request.merge(fields) { _, value in value }
            let uploaded = try await endpoint.request(request)
            XCTAssertEqual(uploaded["ok"] as? Bool, true)
            let expected = try fields["data_b64"].flatMap { Data(base64Encoded: $0 as! String) } ?? Data(contentsOf: URL(fileURLWithPath: save))
            XCTAssertEqual(uploaded["size"] as? Int, expected.count)
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("uploaded")), expected)
        }
        for fields: [String: Any] in [["data_b64": "!"], ["data_b64": 1], ["load": "relative"],
                                      ["data_b64": "", "perm": "4755"], ["data_b64": "", "perm": 644]] {
            var request: [String: Any] = ["t": "file_put", "transport": "api", "path": "/x"]
            request.merge(fields) { _, value in value }
            let invalid = try await endpoint.request(request)
            XCTAssertEqual(invalid["code"] as? String, "invalid_argument")
            XCTAssertNil(invalid["operation_may_continue"])
        }
        let ambiguous = try await endpoint.request(["t": "file_put", "transport": "api", "path": "/lost-reply", "data_b64": "AA=="])
        XCTAssertEqual(ambiguous["ok"] as? Bool, false)
        XCTAssertEqual(ambiguous["operation_may_continue"] as? Bool, true)
        session.stop()
        let stopped = try await endpoint.request(["t": "app_list", "transport": "api"])
        XCTAssertEqual(stopped["code"] as? String, "api_not_ready")
    }

    func testAppMutationsValidateResultsAndPreserveUncertainty() async throws {
        let api = HostAPISessionFake()
        let executor = VPhoneHostCommandExecutor(apiSession: api)
        api.result = .object(["pid": .number(42), "frontmost_verified": .bool(false)])
        let launched = try await call(executor, ["t": "app_launch", "transport": "api", "bundle_id": "fixture.app", "url": "fixture://open", "screen": false])
        XCTAssertEqual(launched["pid"] as? Int, 42)
        XCTAssertEqual(launched["frontmost_verified"] as? Bool, false)
        XCTAssertEqual(api.calls.last?.0, "apps.launch")
        XCTAssertEqual(api.calls.last?.1, ["bundle_id": .string("fixture.app"), "url": .string("fixture://open")])
        api.result = .object(["killed": .string("fixture.app"), "pids": .array([.number(42)]), "already_stopped": .bool(false)])
        let stopped = try await call(executor, ["t": "app_terminate", "transport": "api", "bundle_id": "fixture.app", "screen": false])
        XCTAssertEqual(stopped["ok"] as? Bool, true)
        XCTAssertEqual(stopped["pids"] as? [Int], [42])
        api.result = .object(["pid": .number(42)])
        let invalid = try await call(executor, ["t": "app_launch", "transport": "api", "bundle_id": "fixture.app", "screen": false])
        XCTAssertEqual(invalid["code"] as? String, "api_protocol")
        XCTAssertEqual(invalid["operation_may_continue"] as? Bool, true)
        api.handler = { throw CancellationError() }
        let cancelled = try await call(executor, ["t": "app_terminate", "transport": "api", "bundle_id": "fixture.app", "screen": false])
        XCTAssertEqual(cancelled["operation_may_continue"] as? Bool, true)
        let count = api.calls.count
        for fields: [String: Any] in [["bundle_id": ""], ["bundle_id": 1], ["bundle_id": "app", "url": 2]] {
            var request: [String: Any] = ["t": "app_launch", "transport": "api"]
            request.merge(fields) { _, value in value }
            let rejected = try await call(executor, request)
            XCTAssertEqual(rejected["code"] as? String, "invalid_argument")
            XCTAssertNil(rejected["operation_may_continue"])
        }
        XCTAssertEqual(api.calls.count, count)
    }

    func testListMapsFiltersFieldsAndDataContainer() async throws {
        let api = HostAPISessionFake()
        api.result = .object(["apps": .array([app])])
        let executor = VPhoneHostCommandExecutor(apiSession: api)
        for filter in ["all", "user", "system", "running"] {
            let result = try await call(executor, ["t": "app_list", "transport": "api", "filter": filter])
            XCTAssertEqual(result["ok"] as? Bool, true)
            let mapped = try XCTUnwrap((result["apps"] as? [[String: Any]])?.first)
            XCTAssertEqual(mapped["data_container"] as? String, "/data/fixture")
            XCTAssertEqual(mapped["name"] as? String, "中文 App")
            XCTAssertEqual(mapped["pid"] as? Int, 42)
            XCTAssertEqual(mapped.count, 8)
            XCTAssertEqual(api.calls.last?.0, "apps.list")
            XCTAssertEqual(api.calls.last?.1, ["filter": .string(filter)])
            XCTAssertEqual(api.calls.last?.2, "apps")
        }
        api.result = .object(["apps": .array([])])
        let empty = try await call(executor, ["t": "app_list", "transport": "api"])
        XCTAssertEqual((empty["apps"] as? [Any])?.count, 0)
        XCTAssertEqual(api.calls.last?.1, ["filter": .string("all")])
    }

    func testForegroundPreservesVerificationWithoutInferringFromPID() async throws {
        let api = HostAPISessionFake()
        let executor = VPhoneHostCommandExecutor(apiSession: api)
        for verified in [true, false] {
            api.result = .object(["bundle_id": .string("fixture.app"), "name": .string("App"),
                "pid": .number(42), "source": .string("fixture"), "verified": .bool(verified)])
            let result = try await call(executor, ["t": "app_foreground", "transport": "api"])
            XCTAssertEqual(result["ok"] as? Bool, true)
            XCTAssertEqual(result["verified"] as? Bool, verified)
            XCTAssertEqual(result["source"] as? String, "fixture")
            XCTAssertEqual(api.calls.last?.0, "apps.foreground")
            XCTAssertEqual(api.calls.last?.1, [:])
        }
    }

    func testExplicitRouteDoesNotChangeClassicOrFallback() async throws {
        let api = HostAPISessionFake()
        let guest = HostGuestFake()
        let executor = VPhoneHostCommandExecutor(control: guest, apiSession: api)
        for transport in [nil, "classic"] as [String?] {
            var request: [String: Any] = ["t": "app_list"]
            request["transport"] = transport
            let result = try await call(executor, request)
            XCTAssertEqual((result["apps"] as? [[String: Any]])?.first?["bundle_id"] as? String, "app")
        }
        XCTAssertTrue(api.calls.isEmpty)
        api.state = "reconnecting"
        let unavailable = try await call(executor, ["t": "app_list", "transport": "api"])
        XCTAssertEqual(unavailable["code"] as? String, "api_not_ready")
        XCTAssertNil(unavailable["apps"])
        XCTAssertTrue(api.calls.isEmpty)
        let disabled = try await call(VPhoneHostCommandExecutor(control: guest), ["t": "app_list", "transport": "api"])
        XCTAssertEqual(disabled["code"] as? String, "api_not_ready")
    }

    func testDiscoveryTracksCapabilitiesAndUnsupportedOperationsNeverDispatch() async throws {
        let api = HostAPISessionFake()
        let executor = VPhoneHostCommandExecutor(apiSession: api)
        for state in ["ready", "reconnecting", "stopped"] {
            api.state = state
            let discovery = try await call(executor, ["t": "capabilities"])
            XCTAssertEqual(discovery["api_commands"] as? [String: Bool],
                           ["app_list": state == "ready", "app_foreground": state == "ready", "app_launch": state == "ready", "app_terminate": state == "ready", "file_get": false, "file_put": false])
            XCTAssertEqual((discovery["commands"] as? [String: Bool])?["app_list"], false)
        }
        api.state = "ready"
        api.caps = ["session_identity"]
        let discovery = try await call(executor, ["t": "capabilities"])
        XCTAssertEqual((discovery["api_commands"] as? [String: Bool])?["app_list"], false)
        let missing = try await call(executor, ["t": "app_list", "transport": "api"])
        XCTAssertEqual(missing["code"] as? String, "capability_unavailable")
        for command in ["app_install", "shell", "capabilities"] {
            let result = try await call(executor, ["t": command, "transport": "api", "bundle_id": "app"])
            XCTAssertEqual(result["code"] as? String, "unsupported_transport")
        }
        let dfu = try await call(VPhoneHostCommandExecutor(apiSession: api, bootMode: .dfu), ["t": "app_list", "transport": "api"])
        XCTAssertEqual(dfu["code"] as? String, "capability_unavailable")
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testRejectsInvalidArgumentsBeforeCallingGuest() async throws {
        let api = HostAPISessionFake()
        let executor = VPhoneHostCommandExecutor(apiSession: api)
        for value: Any in [42, NSNull(), "unknown", ""] {
            let transport = try await call(executor, ["t": "app_list", "transport": value])
            XCTAssertEqual(transport["code"] as? String, "invalid_argument")
            let filter = try await call(executor, ["t": "app_list", "transport": "api", "filter": value])
            XCTAssertEqual(filter["code"] as? String, "invalid_argument")
        }
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testMalformedResultsFailWithoutPartialAppList() async throws {
        let api = HostAPISessionFake()
        let executor = VPhoneHostCommandExecutor(apiSession: api)
        var badApps: [VPhoneJSONValue] = [.null, .object([:])]
        guard case let .object(valid) = app else { return XCTFail("fixture") }
        for (key, value): (String, VPhoneJSONValue) in [
            ("bundle_id", .string("")), ("pid", .number(-1)), ("pid", .number(1.5)),
            ("pid", .number(Double(Int32.max) + 1)), ("pid", .bool(true)),
            ("data_path", .null), ("state", .array([])),
        ] {
            var invalid = valid; invalid[key] = value; badApps.append(.object(invalid))
        }
        for invalid in badApps {
            api.result = .object(["apps": .array([app, invalid])])
            let result = try await call(executor, ["t": "app_list", "transport": "api"])
            XCTAssertEqual(result["code"] as? String, "api_protocol")
            XCTAssertNil(result["apps"])
        }
        api.result = .object(["bundle_id": .string("app"), "name": .string("App"), "pid": .number(4)])
        let unverified = try await call(executor, ["t": "app_foreground", "transport": "api"])
        XCTAssertEqual(unverified["code"] as? String, "api_protocol")
    }

    func testRemoteErrorsCancellationAndStaleGeneration() async throws {
        let api = HostAPISessionFake()
        let executor = VPhoneHostCommandExecutor(apiSession: api)
        for (remote, expected) in [("timeout", "api_timeout"), ("disconnected", "api_disconnected"),
                                   ("denied", "api_guest_error"), ("busy", "api_busy")] {
            let error = try JSONDecoder().decode(VPhoneAPIError.self, from: JSONSerialization.data(withJSONObject:
                ["code": remote, "message": "SECRET guest error text"]))
            api.handler = { throw error }
            let result = try await call(executor, ["t": "app_list", "transport": "api"])
            XCTAssertEqual(result["code"] as? String, expected)
            XCTAssertFalse(String(describing: result).contains("SECRET"))
        }
        api.handler = { throw CancellationError() }
        let cancelled = try await call(executor, ["t": "app_list", "transport": "api"])
        XCTAssertEqual(cancelled["code"] as? String, "command_cancelled")
        api.handler = { [weak api] in api?.generation = UUID(); return .object(["apps": .array([])]) }
        let stale = try await call(executor, ["t": "app_list", "transport": "api"])
        XCTAssertEqual(stale["code"] as? String, "api_stale_session")
        XCTAssertNil(stale["apps"])
    }
}
