import Foundation
import VPhoneAPIKit
import XCTest
@testable import vphone_cli

@MainActor
final class RPCSessionFake: VPhoneHostAPISession {
    var state = "ready"
    var caps = ["session_identity", "clipboard", "input_gestures", "hid", "apps"]
    var generation = UUID()
    var calls: [(method: String, params: [String: VPhoneJSONValue], capability: String?)] = []
    var handler: ((String) async throws -> VPhoneJSONValue)?
    var snapshot: VPhoneAPISession.Snapshot {
        let health: [String: Any] = ["apiVersion": 1, "binaryHash": String(repeating: "b", count: 64),
                                     "capabilities": caps, "instanceID": "6A5A4D0B-6D53-4A4B-8F2B-0B8E7E3F7A11"]
        var value: [String: Any] = ["vmInstanceID": "fixture", "state": state]
        if state == "ready" { value["generation"] = generation.uuidString; value["health"] = health }
        return try! JSONDecoder().decode(VPhoneAPISession.Snapshot.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func uploadFile(_ source: VPhoneAPIUpload, path: String, permissions: String) async throws { throw URLError(.unsupportedURL) }
    func downloadFile(path: String, maximumBytes: Int, stagingDirectory: URL) async throws -> VPhoneAPIDownload {
        throw URLError(.unsupportedURL)
    }
    func call(_ method: String, params: [String: VPhoneJSONValue], requiring capability: String?) async throws -> VPhoneJSONValue {
        calls.append((method, params, capability))
        if let handler { return try await handler(method) }
        return .object(["method": .string(method)])
    }
}

/// VPhoneAPIError has no public initializer; decode one as the wire does.
func apiError(_ code: String, _ message: String) -> VPhoneAPIError {
    try! JSONDecoder().decode(VPhoneAPIError.self, from: JSONSerialization.data(
        withJSONObject: ["code": code, "message": message]))
}

@MainActor
final class HostRPCTests: XCTestCase {
    private func call(_ executor: VPhoneHostCommandExecutor, _ fields: [String: Any]) async throws -> [String: Any] {
        let data = await executor.execute(try JSONSerialization.data(withJSONObject: fields))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Method table

    /// Every method the local API daemon serves is either forwarded with a
    /// capability the daemon declares, or refused with a reason.
    func testMethodTableMatchesLocalDaemonSourcesAndDeclaredCapabilities() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let daemon = root.appendingPathComponent("sources/VPhoneDaemon/Daemon")
        let files = try FileManager.default.contentsOfDirectory(atPath: daemon.path)
            .filter { $0.hasPrefix("GuestAPI") && $0.hasSuffix(".swift") }
        XCTAssertFalse(files.isEmpty)
        let caseLine = try NSRegularExpression(pattern: #"case ((?:"[a-z_]+\.[a-z_.]+"(?:, )?)+):"#)
        let quoted = try NSRegularExpression(pattern: #""([^"]+)""#)
        func strings(_ text: String, _ regex: NSRegularExpression) -> [String] {
            regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
                String(text[Range($0.range(at: 1), in: text)!])
            }
        }
        var served = Set<String>()
        for file in files {
            let source = try String(contentsOf: daemon.appendingPathComponent(file), encoding: .utf8)
            for list in strings(source, caseLine) { served.formUnion(strings(list, quoted)) }
        }
        XCTAssertGreaterThan(served.count, 100)
        let forwarded = Set(VPhoneHostRPC.methods.keys)
        let blocked = Set(VPhoneHostRPC.blocked.keys)
        XCTAssertTrue(forwarded.isDisjoint(with: blocked))
        XCTAssertEqual(forwarded.union(blocked), served)

        let health = try String(contentsOf: daemon.appendingPathComponent("GuestAPI.swift"), encoding: .utf8)
        let block = try XCTUnwrap(health.range(of: #""capabilities": \[[^\]]*\]"#, options: .regularExpression))
        let declared = Set(strings(String(health[block]), try NSRegularExpression(pattern: #""([a-z_0-9]+)""#)))
        for (method, entry) in VPhoneHostRPC.methods {
            if let capability = entry.capability {
                XCTAssertTrue(declared.contains(capability), "\(method) requires undeclared \(capability)")
            }
        }
        XCTAssertTrue(VPhoneHostRPC.methods["input.tap"]!.input)
        XCTAssertTrue(VPhoneHostRPC.methods["ui.tap_element"]!.input)
        XCTAssertFalse(VPhoneHostRPC.methods["clipboard.get"]!.input)
    }

    // MARK: - Forwarding

    func testForwardsDeclaredMethodWithParamsAndReturnsResult() async throws {
        let api = RPCSessionFake()
        api.handler = { _ in .object(["text": .string("中文"), "count": .number(2), "types": .array([.string("public.text")])]) }
        let executor = VPhoneHostCommandExecutor(apiSession: api)
        let result = try await call(executor, ["t": "rpc", "method": "clipboard.set", "params": ["text": "中文"]])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["method"] as? String, "clipboard.set")
        let value = try XCTUnwrap(result["result"] as? [String: Any])
        XCTAssertEqual(value["text"] as? String, "中文")
        XCTAssertEqual(value["count"] as? Int, 2)
        XCTAssertNil(result["image"])
        XCTAssertEqual(api.calls.count, 1)
        XCTAssertEqual(api.calls[0].method, "clipboard.set")
        XCTAssertEqual(api.calls[0].params, ["text": .string("中文")])
        XCTAssertEqual(api.calls[0].capability, "clipboard")
        let explicit = try await call(executor, ["t": "rpc", "transport": "api", "method": "agent.health"])
        XCTAssertEqual(explicit["ok"] as? Bool, true)
        XCTAssertNil(api.calls[1].capability)
        XCTAssertEqual(api.calls[1].params, [:])
    }

    func testRPCScreenIsOptInAndUsesTheScreenAdapter() async throws {
        let api = RPCSessionFake()
        let screen = HostScreenFake()
        let executor = VPhoneHostCommandExecutor(screen: screen, apiSession: api)
        let plain = try await call(executor, ["t": "rpc", "method": "clipboard.get", "delay": 0])
        XCTAssertNil(plain["image"])
        let shown = try await call(executor, ["t": "rpc", "method": "clipboard.get", "screen": true, "delay": 0])
        XCTAssertEqual(shown["image"] as? String, "jpeg")
    }

    func testUnknownBlockedAndInvalidRequestsNeverDispatch() async throws {
        let api = RPCSessionFake()
        api.caps.append(contentsOf: ["touch", "location", "environment_update"])
        let executor = VPhoneHostCommandExecutor(apiSession: api)
        let unknown = try await call(executor, ["t": "rpc", "method": "notify.post", "params": ["name": "x"]])
        XCTAssertEqual(unknown["code"] as? String, "unsupported_method")
        XCTAssertEqual(unknown["method"] as? String, "notify.post")
        for method in ["input.touch", "location.set", "location.clear", "agent.apply_update", "environment.install"] {
            let refused = try await call(executor, ["t": "rpc", "method": method, "params": [:]])
            XCTAssertEqual(refused["code"] as? String, "method_not_forwardable", method)
            XCTAssertFalse((refused["error"] as? String ?? "").isEmpty)
        }
        let halfPress = try await call(executor, ["t": "rpc", "method": "input.hid",
                                                  "params": ["page": 12, "usage": 64, "down": true]])
        XCTAssertEqual(halfPress["code"] as? String, "method_not_forwardable")
        for fields: [String: Any] in [["t": "rpc"], ["t": "rpc", "method": 1], ["t": "rpc", "method": ""],
                                      ["t": "rpc", "method": "clipboard.get", "params": [1]],
                                      ["t": "rpc", "method": "clipboard.get", "params": "x"],
                                      ["t": "rpc", "method": "clipboard.get", "transport": 1],
                                      ["t": "rpc", "method": String(repeating: "a", count: 129)]] {
            let invalid = try await call(executor, fields)
            XCTAssertEqual(invalid["code"] as? String, "invalid_argument", "\(fields)")
        }
        let classic = try await call(executor, ["t": "rpc", "transport": "classic", "method": "clipboard.get"])
        XCTAssertEqual(classic["code"] as? String, "unsupported_transport")
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testReadinessCapabilityAndBootModeGateBeforeDispatch() async throws {
        let api = RPCSessionFake()
        api.caps = ["session_identity"]
        let executor = VPhoneHostCommandExecutor(apiSession: api)
        let missing = try await call(executor, ["t": "rpc", "method": "clipboard.get"])
        XCTAssertEqual(missing["code"] as? String, "capability_unavailable")
        XCTAssertEqual(missing["capability"] as? String, "clipboard")
        XCTAssertNil(missing["operation_may_continue"])
        api.state = "reconnecting"
        let notReady = try await call(executor, ["t": "rpc", "method": "agent.health"])
        XCTAssertEqual(notReady["code"] as? String, "api_not_ready")
        let noSession = try await call(VPhoneHostCommandExecutor(), ["t": "rpc", "method": "agent.health"])
        XCTAssertEqual(noSession["code"] as? String, "api_not_ready")
        api.state = "ready"
        let dfu = VPhoneHostCommandExecutor(apiSession: api, bootMode: .dfu)
        let refused = try await call(dfu, ["t": "rpc", "method": "agent.health"])
        XCTAssertEqual(refused["code"] as? String, "capability_unavailable")
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testStaleGenerationGuestErrorsAndTransportErrorsKeepUncertainty() async throws {
        let api = RPCSessionFake()
        let executor = VPhoneHostCommandExecutor(apiSession: api)
        api.handler = { _ in api.generation = UUID(); return .object([:]) }
        let stale = try await call(executor, ["t": "rpc", "method": "clipboard.clear"])
        XCTAssertEqual(stale["code"] as? String, "api_stale_session")
        XCTAssertEqual(stale["operation_may_continue"] as? Bool, true)
        api.handler = { _ in throw apiError("invalid_request", "secret guest text") }
        let guest = try await call(executor, ["t": "rpc", "method": "clipboard.get"])
        XCTAssertEqual(guest["code"] as? String, "api_guest_error")
        XCTAssertEqual(guest["guest_code"] as? String, "invalid_request")
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: guest), as: UTF8.self).contains("secret"))
        api.handler = { _ in throw apiError("Bad Code!", "x") }
        let odd = try await call(executor, ["t": "rpc", "method": "clipboard.get"])
        XCTAssertNil(odd["guest_code"])
        api.handler = { _ in throw apiError("timeout", "x") }
        let timeout = try await call(executor, ["t": "rpc", "method": "clipboard.get"])
        XCTAssertEqual(timeout["code"] as? String, "api_timeout")
        XCTAssertEqual(timeout["operation_may_continue"] as? Bool, true)
        api.handler = { _ in throw URLError(.networkConnectionLost) }
        let transport = try await call(executor, ["t": "rpc", "method": "clipboard.get"])
        XCTAssertEqual(transport["code"] as? String, "api_transport")
    }

    func testServiceDeadlineAndCancellationApplyToForwardedCalls() async throws {
        let api = RPCSessionFake()
        let gate = HostTestGate()
        api.handler = { _ in await gate.wait(); return .object([:]) }
        let executor = VPhoneHostCommandExecutor(apiSession: api)
        let service = VPhoneHostCommandService(timeout: .milliseconds(50), execute: executor.execute)
        let request = try JSONSerialization.data(withJSONObject: ["t": "rpc", "method": "clipboard.get"])
        let reply = await service.submit(request)
        let timedOut = try decodeResponse(reply)
        XCTAssertEqual(timedOut["code"] as? String, "command_timeout")
        XCTAssertEqual(timedOut["operation_may_continue"] as? Bool, true)
        gate.open()
    }

    // MARK: - Keys

    func testKeyForwardsKeyboardNamesOnlyThroughTheAPISession() async throws {
        let guest = HostGuestFake()
        let classicOnly = VPhoneHostCommandExecutor(control: guest)
        let unknown = try await call(classicOnly, ["t": "key", "name": "return", "screen": false])
        XCTAssertEqual(unknown["error"] as? String, "unknown key: return")
        let home = try await call(classicOnly, ["t": "key", "name": "home", "screen": false])
        XCTAssertEqual(home["ok"] as? Bool, true)
        XCTAssertEqual(guest.hidPresses, [0x40])

        let api = RPCSessionFake()
        let executor = VPhoneHostCommandExecutor(control: guest, apiSession: api)
        let paste = try await call(executor, ["t": "key", "name": "cmd+v", "screen": false])
        XCTAssertEqual(paste["ok"] as? Bool, true)
        XCTAssertEqual(api.calls.map(\.method), ["input.key"])
        XCTAssertEqual(api.calls[0].params, ["name": .string("cmd+v")])
        XCTAssertEqual(api.calls[0].capability, "input_gestures")
        let classic = try await call(executor, ["t": "key", "name": "return", "transport": "classic", "screen": false])
        XCTAssertEqual(classic["error"] as? String, "unknown key: return")
        XCTAssertEqual(api.calls.count, 1)
        api.caps = ["session_identity"]
        let missing = try await call(executor, ["t": "key", "name": "return", "screen": false])
        XCTAssertEqual(missing["code"] as? String, "capability_unavailable")
        XCTAssertEqual(api.calls.count, 1)
    }

    // MARK: - Input order

    func testForwardedInputWaitsForAnEarlierSocketGestureToFinish() async throws {
        let api = RPCSessionFake()
        let screen = HostScreenFake()
        screen.suspendGestures = true
        let executor = VPhoneHostCommandExecutor(screen: screen, apiSession: api)
        let tap = Task { await executor.execute(try JSONSerialization.data(
            withJSONObject: ["t": "tap", "x": 1.0, "y": 2.0, "screen": false])) }
        try await waitUntil { screen.tapped != nil }
        let typed = Task { await executor.execute(try JSONSerialization.data(
            withJSONObject: ["t": "rpc", "method": "input.type", "params": ["text": "a"]])) }
        // A non-input method is not ordered behind the gesture.
        let read = try await call(executor, ["t": "rpc", "method": "clipboard.get"])
        XCTAssertEqual(read["ok"] as? Bool, true)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(api.calls.map(\.method), ["clipboard.get"])
        XCTAssertEqual(executor.inputQueue.pending, 2)
        screen.completeGesture()
        let tapped = try decodeResponse(await tap.value)
        XCTAssertEqual(tapped["ok"] as? Bool, true)
        let result = try decodeResponse(await typed.value)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(api.calls.map(\.method), ["clipboard.get", "input.type"])
        XCTAssertEqual(executor.inputQueue.pending, 0)
    }

    func testCancelledQueuedInputDoesNotRun() async throws {
        let api = RPCSessionFake()
        let screen = HostScreenFake()
        screen.suspendGestures = true
        let executor = VPhoneHostCommandExecutor(screen: screen, apiSession: api)
        let tap = Task { await executor.execute(try JSONSerialization.data(
            withJSONObject: ["t": "tap", "x": 1.0, "y": 2.0, "screen": false])) }
        try await waitUntil { screen.tapped != nil }
        let queued = Task { await executor.execute(try JSONSerialization.data(
            withJSONObject: ["t": "rpc", "method": "input.tap", "params": ["x": 1, "y": 2]])) }
        try await waitUntil { executor.inputQueue.pending == 2 }
        queued.cancel()
        screen.completeGesture()
        _ = try await tap.value
        let cancelled = try decodeResponse(await queued.value)
        XCTAssertEqual(cancelled["code"] as? String, "command_cancelled")
        XCTAssertNil(cancelled["operation_may_continue"])
        XCTAssertTrue(api.calls.isEmpty)
    }

    // MARK: - Discovery

    func testCapabilitiesReportForwardableMethodsAndTarget() async throws {
        let api = RPCSessionFake()
        api.caps = ["session_identity", "clipboard"]
        let target = VPhoneHostTarget(vm: "vm-a", instanceID: "inst-a", pid: 123, processStartedAt: 10.5)
        let executor = VPhoneHostCommandExecutor(apiSession: api, target: target)
        let discovery = try await call(executor, ["t": "capabilities"])
        XCTAssertEqual((discovery["commands"] as? [String: Bool])?["rpc"], true)
        let methods = try XCTUnwrap(discovery["rpc_methods"] as? [String])
        XCTAssertTrue(methods.contains("clipboard.get"))
        XCTAssertTrue(methods.contains("agent.health"))
        XCTAssertFalse(methods.contains("input.tap"))
        XCTAssertFalse(methods.contains("input.touch"))
        let reported = try XCTUnwrap(discovery["target"] as? [String: Any])
        XCTAssertEqual(reported["vm"] as? String, "vm-a")
        XCTAssertEqual(reported["instance_id"] as? String, "inst-a")
        XCTAssertEqual(reported["pid"] as? Int, 123)
        XCTAssertEqual(reported["process_started_at"] as? Double, 10.5)
        api.state = "reconnecting"
        let offline = try await call(executor, ["t": "capabilities"])
        XCTAssertEqual((offline["commands"] as? [String: Bool])?["rpc"], false)
        XCTAssertEqual(offline["rpc_methods"] as? [String], [])
    }

    func testTargetChecksRejectBeforeAnyCommandRuns() async throws {
        let guest = HostGuestFake()
        let target = VPhoneHostTarget(vm: "vm-a", instanceID: "inst-a", pid: 123, processStartedAt: 10.5)
        let executor = VPhoneHostCommandExecutor(control: guest, target: target)
        for expected: [String: Any] in [["vm": "vm-a"], ["instance_id": "inst-a"],
                                         ["vm": "vm-a", "instance_id": "inst-a", "pid": 123, "process_started_at": 10.5]] {
            let ok = try await call(executor, ["t": "shell", "cmd": "true", "target": expected])
            XCTAssertEqual(ok["ok"] as? Bool, true, "\(expected)")
        }
        XCTAssertEqual(guest.shellCalls, 3)
        for expected: [String: Any] in [["vm": "vm-b"], ["instance_id": "old-boot"], ["pid": 124],
                                         ["process_started_at": 11.0], ["vm": "vm-a", "instance_id": "old-boot"]] {
            let refused = try await call(executor, ["t": "shell", "cmd": "true", "target": expected])
            XCTAssertEqual(refused["code"] as? String, "target_mismatch", "\(expected)")
            XCTAssertEqual(refused["operation_may_continue"] as? Bool, false)
            XCTAssertEqual((refused["target"] as? [String: Any])?["vm"] as? String, "vm-a")
        }
        for invalid: Any in ["vm-a", [:] as [String: Any], ["name": "vm-a"], ["vm": 1], ["pid": "123"], ["pid": true]] {
            let refused = try await call(executor, ["t": "shell", "cmd": "true", "target": invalid])
            XCTAssertEqual(refused["code"] as? String, "invalid_argument", "\(invalid)")
        }
        let unknownTarget = VPhoneHostCommandExecutor(control: guest)
        let unconfirmed = try await call(unknownTarget, ["t": "shell", "cmd": "true", "target": ["vm": "vm-a"]])
        XCTAssertEqual(unconfirmed["code"] as? String, "target_mismatch")
        XCTAssertEqual(guest.shellCalls, 3)
    }
}
