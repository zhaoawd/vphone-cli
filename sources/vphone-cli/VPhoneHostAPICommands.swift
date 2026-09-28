import Foundation
import VPhoneAPIKit

/// The host command boundary needs only readiness and correlated API calls.
@MainActor
protocol VPhoneHostAPISession: AnyObject {
    var snapshot: VPhoneAPISession.Snapshot { get }
    func call(_ method: String, params: [String: VPhoneJSONValue], requiring capability: String?) async throws -> VPhoneJSONValue
}

extension VPhoneAPISession: VPhoneHostAPISession {}

@MainActor
enum VPhoneHostAPICommands {
    static let commands = ["app_list", "app_foreground"]

    static func capabilities(_ session: (any VPhoneHostAPISession)?) -> [String: Bool] {
        let available = session?.snapshot.state == .ready && session?.snapshot.health?.capabilities.contains("apps") == true
        return Dictionary(uniqueKeysWithValues: commands.map { ($0, available) })
    }

    static func execute(_ command: String, request: [String: Any], session: (any VPhoneHostAPISession)?) async -> Data {
        guard commands.contains(command) else { return failure("unsupported_transport") }
        var params: [String: VPhoneJSONValue] = [:]
        if command == "app_list" {
            let filter: String
            if let value = request["filter"] {
                guard let text = value as? String else { return failure("invalid_argument") }
                filter = text
            } else { filter = "all" }
            guard ["all", "user", "system", "running"].contains(filter) else { return failure("invalid_argument") }
            params["filter"] = .string(filter)
        }
        guard let session, session.snapshot.state == .ready else { return failure("api_not_ready") }
        guard session.snapshot.health?.capabilities.contains("apps") == true else { return failure("capability_unavailable") }
        let generation = session.snapshot.generation
        do {
            try Task.checkCancellation()
            let result = try await session.call(command == "app_list" ? "apps.list" : "apps.foreground",
                                                params: params, requiring: "apps")
            try Task.checkCancellation()
            guard session.snapshot.state == .ready, session.snapshot.generation == generation else {
                return failure("api_stale_session")
            }
            let fields = try command == "app_list" ? appList(result) : foreground(result)
            return VPhoneHostCommandExecutor.response(ok: true, extra: fields)
        } catch is CancellationError {
            return failure("command_cancelled")
        } catch is MappingError {
            return failure("api_protocol")
        } catch let error as VPhoneAPIError {
            let codes = ["not_ready": "api_not_ready", "unsupported_capability": "capability_unavailable",
                         "stale_session": "api_stale_session", "disconnected": "api_disconnected",
                         "timeout": "api_timeout", "busy": "api_busy", "protocol": "api_protocol",
                         "response_too_large": "api_response_too_large", "event_overflow": "api_disconnected"]
            // Stable host codes; never expose arbitrary guest error text.
            return failure(codes[error.code] ?? "api_guest_error")
        } catch {
            return failure("api_transport")
        }
    }

    private enum MappingError: Error { case invalidResult }

    private static func object(_ value: VPhoneJSONValue) throws -> [String: VPhoneJSONValue] {
        guard case let .object(fields) = value else { throw MappingError.invalidResult }
        return fields
    }

    private static func string(_ fields: [String: VPhoneJSONValue], _ key: String, optional: Bool = false) throws -> String {
        if optional, fields[key] == nil { return "" }
        guard case let .string(value) = fields[key] else { throw MappingError.invalidResult }
        return value
    }

    private static func pid(_ fields: [String: VPhoneJSONValue]) throws -> Int {
        guard case let .number(value) = fields["pid"], value.isFinite,
              value >= 0, value <= Double(Int32.max), value.rounded(.towardZero) == value
        else { throw MappingError.invalidResult }
        return Int(value)
    }

    private static func appList(_ result: VPhoneJSONValue) throws -> [String: Any] {
        let fields = try object(result)
        guard case let .array(apps) = fields["apps"] else { throw MappingError.invalidResult }
        return try ["apps": apps.map { value -> [String: Any] in
            let app = try object(value)
            let id = try string(app, "bundle_id")
            guard !id.isEmpty else { throw MappingError.invalidResult }
            // API v1 derives path/state/type/pid, but directory-scanned apps can
            // lack a display name, version or LaunchServices data container.
            return try ["bundle_id": id, "name": string(app, "name", optional: true),
                        "version": string(app, "version", optional: true), "type": string(app, "type"),
                        "state": string(app, "state"), "pid": pid(app), "path": string(app, "path"),
                        "data_container": string(app, "data_path", optional: true)]
        }]
    }

    private static func foreground(_ result: VPhoneJSONValue) throws -> [String: Any] {
        let fields = try object(result)
        guard case let .bool(verified) = fields["verified"] else { throw MappingError.invalidResult }
        var response: [String: Any] = try ["bundle_id": string(fields, "bundle_id"),
            "name": string(fields, "name"), "pid": pid(fields), "verified": verified]
        let source = try string(fields, "source", optional: true)
        if !source.isEmpty { response["source"] = source }
        return response
    }

    private static func failure(_ code: String) -> Data {
        VPhoneHostCommandExecutor.response(ok: false, error: code, extra: ["code": code])
    }
}
