import Foundation
import VPhoneAPIKit

// MARK: - Method Table

/// Host-control `rpc` forwarding to the API v1 daemon (VSOCK 1339).
///
/// Only methods in `methods` are forwarded. Each entry names the guest
/// capability that `/v1/health` (and the WebSocket hello) must declare; a nil
/// capability means the method predates area capabilities and needs only a
/// ready API session. The table follows `sources/VPhoneDaemon/Daemon/GuestAPI*.swift`
/// (area file -> declared area capability); `HostRPCTests` checks that every
/// daemon method is either forwarded or listed in `blocked`.
enum VPhoneHostRPC {
    struct Method {
        let capability: String?
        /// Input methods run in the host input queue, after earlier socket
        /// taps, swipes and keys have emitted their last event.
        let input: Bool
    }

    static let methods: [String: Method] = {
        var table: [String: Method] = [:]
        func add(_ capability: String?, _ names: [String], input: Bool = false) {
            for name in names { table[name] = Method(capability: capability, input: input) }
        }
        add(nil, ["agent.health", "settings.get", "settings.set", "settings.delete",
                  "developer_mode.status", "developer_mode.enable", "power.low_power_mode"])
        add("device_info", ["device.snapshot", "device.screen", "device.info", "device.network",
                            "device.ioreg", "device.environment", "device.basebin"])
        add("screenshot", ["screen.screenshot"])
        add("display", ["display.brightness", "display.rotation", "display.rotation_lock"])
        add("audio", ["audio.volume", "audio.state"])
        add("network_capture", ["network.capture"])
        add("system_control", ["security.ssl_killswitch", "diagnostics.self_test", "system.uicache",
                               "system.system_apps", "system.respring", "system.reboot"])
        add("apps", ["apps.list", "apps.search", "apps.refresh", "apps.launch", "apps.terminate",
                     "apps.uninstall", "apps.foreground"])
        add("url", ["apps.open_url"])
        add("ipa_install", ["apps.install"])
        add("app_details", ["apps.info", "apps.binary", "apps.data_dir", "apps.url_schemes", "apps.handlers",
                            "apps.registration", "apps.register", "apps.unregister", "apps.unregister_dir",
                            "apps.network_policy"])
        add("bootstrap_install", ["bootstrap.install", "bootstrap.status", "bootstrap.inspect", "bootstrap.firmware"])
        add("bootstrap_uninstall", ["bootstrap.uninstall"])
        add("hid", ["input.hid"], input: true)
        add("input_gestures", ["input.button", "input.key", "input.type", "input.paste", "input.tap",
                               "input.double_tap", "input.long_press", "input.swipe", "input.drag",
                               "input.touch_sequence"], input: true)
        add("ui_inspection", ["ui.tree", "accessibility.tree", "ui.element_at", "ui.wait", "ui.wait_gone",
                              "ui.ocr", "ui.describe"])
        add("ui_inspection", ["ui.tap_element"], input: true)
        add("location", ["location.current"])
        add("clipboard", ["clipboard.get", "clipboard.set", "clipboard.clear"])
        add("files", ["files.list", "files.mkdir", "files.remove", "files.rename"])
        add("file_tools", ["files.read", "files.write", "files.find", "files.copy", "files.symlink",
                           "files.chmod", "files.chown", "files.plist", "files.plist_set"])
        add("keychain", ["keychain.list", "keychain.add", "keychain.delete", "keychain.get",
                         "keychain.update", "keychain.database"])
        add("packages", ["packages.list", "packages.status", "packages.info", "packages.compare",
                         "packages.tweaks", "packages.repos"])
        add("logs", ["logs.syslog", "logs.crashes", "logs.crash"])
        add("processes", ["processes.list", "processes.kill", "memory.jetsam", "memory.pressure"])
        add("services", ["services.list", "services.status", "services.print", "services.dump",
                         "services.disabled", "services.start", "services.enable", "services.stop",
                         "services.disable", "services.remove", "services.signal", "services.load",
                         "services.unload", "launchd.getenv", "launchd.setenv", "launchd.unsetenv"])
        add("environment_update", ["environment.status"])
        add("environment_activation", ["environment.loaded"])
        return table
    }()

    /// Daemon methods that the socket refuses to forward, with the reason
    /// returned to the caller. Each has a host path that keeps its contract.
    static let blocked: [String: String] = [
        "input.touch": "single touch phases would split one gesture across requests; use tap, swipe or input.touch_sequence",
        "location.set": "bypasses location owner and generation; use location_source_set or location_stream_*",
        "location.clear": "bypasses location owner and generation; use location_source_stop",
        "agent.apply_update": "guest daemon replacement has its own update transaction",
        "environment.install": "guest library replacement has its own update transaction; use environment_update",
        "environment.restore": "guest library replacement has its own update transaction; use environment_rollback",
    ]

    // MARK: - Validation

    enum Rejection: Error, Equatable {
        case invalidArgument
        case unsupportedTransport
        case unsupportedMethod
        case notForwardable(String)
    }

    struct Plan {
        let method: String
        let entry: Method
        let params: [String: VPhoneJSONValue]
    }

    /// Validates a request before any guest contact.
    static func plan(_ request: [String: Any]) -> Result<Plan, Rejection> {
        if let transport = request["transport"] {
            guard let name = transport as? String else { return .failure(.invalidArgument) }
            guard name == "api" else { return .failure(.unsupportedTransport) }
        }
        guard let method = request["method"] as? String, !method.isEmpty,
              method.utf8.count <= 128, !method.contains("\0") else { return .failure(.invalidArgument) }
        let rawParams = request["params"] ?? [String: Any]()
        guard let object = rawParams as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: object),
              case let .object(params)? = try? JSONDecoder().decode(VPhoneJSONValue.self, from: data)
        else { return .failure(.invalidArgument) }
        if let reason = blocked[method] { return .failure(.notForwardable(reason)) }
        if method == "input.hid", params["down"] != nil {
            return .failure(.notForwardable("a half key press would split one press across requests; omit down"))
        }
        guard let entry = methods[method] else { return .failure(.unsupportedMethod) }
        return .success(Plan(method: method, entry: entry, params: params))
    }

    /// Declared capabilities that make each forwarded method callable now.
    @MainActor
    static func availableMethods(_ session: (any VPhoneHostAPISession)?) -> [String] {
        guard let session, session.snapshot.state == .ready else { return [] }
        let declared = session.snapshot.health?.capabilities ?? []
        return methods.filter { $0.value.capability.map(declared.contains) ?? true }.keys.sorted()
    }

    // MARK: - Execution

    /// Calls a validated method. Failures after submission set
    /// `operation_may_continue`, because the guest may still run the method.
    /// The success value is the method result as JSON.
    @MainActor
    static func call(_ plan: Plan, session: (any VPhoneHostAPISession)?) async -> Result<Data, Failure> {
        guard let session, session.snapshot.state == .ready else { return .failure(.init(code: "api_not_ready")) }
        if let capability = plan.entry.capability,
           session.snapshot.health?.capabilities.contains(capability) != true {
            return .failure(.init(code: "capability_unavailable", capability: capability))
        }
        let generation = session.snapshot.generation
        guard !Task.isCancelled else { return .failure(.init(code: "command_cancelled")) }
        do {
            let value = try await session.call(plan.method, params: plan.params, requiring: plan.entry.capability)
            try Task.checkCancellation()
            guard session.snapshot.state == .ready, session.snapshot.generation == generation else {
                return .failure(.init(code: "api_stale_session", mayContinue: true))
            }
            guard let result = try? JSONEncoder().encode(value) else {
                return .failure(.init(code: "api_protocol", mayContinue: true))
            }
            return .success(result)
        } catch is CancellationError {
            return .failure(.init(code: "command_cancelled", mayContinue: true))
        } catch let error as VPhoneAPIError {
            if let code = VPhoneHostAPICommands.hostCode(forAPIError: error.code) {
                return .failure(.init(code: code, mayContinue: true))
            }
            // Guest error text is not returned; a short machine code is.
            let guestCode = error.code.utf8.count <= 64
                && error.code.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_").contains($0) }
                ? error.code : nil
            return .failure(.init(code: "api_guest_error", mayContinue: true, guestCode: guestCode))
        } catch {
            return .failure(.init(code: "api_transport", mayContinue: true))
        }
    }

    struct Failure: Error {
        var code: String
        var mayContinue = false
        var capability: String?
        var guestCode: String?

        var fields: [String: Any] {
            var fields: [String: Any] = ["code": code]
            if mayContinue { fields["operation_may_continue"] = true }
            if let capability { fields["capability"] = capability }
            if let guestCode { fields["guest_code"] = guestCode }
            return fields
        }
    }
}
