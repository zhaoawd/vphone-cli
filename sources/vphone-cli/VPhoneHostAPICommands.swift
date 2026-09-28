import Foundation
import VPhoneAPIKit
import VPhoneCore

/// The host command boundary needs only readiness and correlated API calls.
@MainActor
protocol VPhoneHostAPISession: AnyObject {
    var snapshot: VPhoneAPISession.Snapshot { get }
    func uploadFile(_ source: VPhoneAPIUpload, path: String, permissions: String) async throws
    func downloadFile(path: String, maximumBytes: Int, stagingDirectory: URL) async throws -> VPhoneAPIDownload
    func call(_ method: String, params: [String: VPhoneJSONValue], requiring capability: String?) async throws -> VPhoneJSONValue
}

extension VPhoneAPISession: VPhoneHostAPISession {}

@MainActor
enum VPhoneHostAPICommands {
    static let commands = ["app_list", "app_foreground", "file_get", "file_put"]

    static func capabilities(_ session: (any VPhoneHostAPISession)?) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: commands.map { command in
            (command, session?.snapshot.state == .ready &&
                required(command).isSubset(of: session?.snapshot.health?.capabilities ?? []))
        })
    }

    private static func required(_ command: String) -> Set<String> {
        switch command {
        case "file_get": ["files", "file_download_identity"]
        case "file_put": ["files", "file_upload_identity"]
        default: ["apps"]
        }
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
        guard required(command).isSubset(of: session.snapshot.health?.capabilities ?? []) else { return failure("capability_unavailable") }
        let generation = session.snapshot.generation
        var submitted = false
        do {
            try Task.checkCancellation()
            if command == "file_put" {
                guard let path = request["path"] as? String, path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains("\0") else { return failure("invalid_argument") }
                let permissions = request["perm"] as? String ?? "644"
                guard request["perm"] == nil || request["perm"] is String,
                      !permissions.isEmpty, permissions.count <= 4,
                      permissions.utf8.allSatisfy({ (48...55).contains($0) }),
                      let mode = UInt16(permissions, radix: 8), mode <= 0o777 else { return failure("invalid_argument") }
                let source: VPhoneAPIUpload
                if let value = request["data_b64"] {
                    guard let string = value as? String, let data = Data(base64Encoded: string) else { return failure("invalid_argument") }
                    source = try VPhoneAPIUpload.prepare(data: data)
                } else if let path = request["load"] as? String {
                    guard path.hasPrefix("/"), !path.contains("\0") else { return failure("invalid_argument") }
                    source = try await VPhoneAPIUpload.prepare(path: path)
                } else { return failure("invalid_argument") }
                try Task.checkCancellation()
                guard session.snapshot.state == .ready, session.snapshot.generation == generation else { return failure("api_stale_session") }
                submitted = true
                try await session.uploadFile(source, path: path, permissions: permissions)
                return VPhoneHostCommandExecutor.response(ok: true, extra: ["size": source.size])
            }
            if command == "file_get" {
                guard let path = request["path"] as? String, path.hasPrefix("/"), !path.contains("\0") else {
                    return failure("invalid_argument")
                }
                let save: String?
                if let value = request["save"] {
                    guard let text = value as? String, text.hasPrefix("/"), !text.hasSuffix("/"),
                          !text.contains("\0"), ![".", ".."].contains((text as NSString).lastPathComponent) else {
                        return failure("invalid_argument")
                    }
                    save = text
                } else { save = nil }
                let destination = save.map { URL(fileURLWithPath: $0) }
                let directory = destination?.deletingLastPathComponent() ?? FileManager.default.temporaryDirectory
                let file = try await session.downloadFile(path: path,
                    maximumBytes: save == nil ? HostControlIO.maximumInlineBytes : HostControlIO.maximumFileBytes,
                    stagingDirectory: directory)
                try Task.checkCancellation()
                guard session.snapshot.state == .ready, session.snapshot.generation == generation else {
                    return failure("api_stale_session")
                }
                let size = file.size
                if let destination, let save {
                    try file.publish(to: destination)
                    return VPhoneHostCommandExecutor.response(ok: true, path: save, extra: ["size": size])
                }
                return VPhoneHostCommandExecutor.response(ok: true,
                    extra: ["size": size, "data": try file.data().base64EncodedString()])
            }
            let result = try await session.call(command == "app_list" ? "apps.list" : "apps.foreground",
                                                params: params, requiring: "apps")
            try Task.checkCancellation()
            guard session.snapshot.state == .ready, session.snapshot.generation == generation else {
                return failure("api_stale_session")
            }
            let fields = try command == "app_list" ? appList(result) : foreground(result)
            return VPhoneHostCommandExecutor.response(ok: true, extra: fields)
        } catch is CancellationError {
            return failure("command_cancelled", mayContinue: submitted)
        } catch is MappingError {
            return failure("api_protocol")
        } catch let error as VPhoneAPIError {
            let codes = ["not_ready": "api_not_ready", "unsupported_capability": "capability_unavailable",
                         "stale_session": "api_stale_session", "disconnected": "api_disconnected",
                         "timeout": "api_timeout", "busy": "api_busy", "protocol": "api_protocol",
                         "response_too_large": "api_response_too_large", "event_overflow": "api_disconnected",
                         "file_too_large": "file_too_large", "destination_exists": "destination_exists",
                         "file_io": "io_error", "identity_mismatch": "api_stale_session", "http": "api_http"]
            // Stable host codes; never expose arbitrary guest error text.
            return failure(codes[error.code] ?? "api_guest_error", mayContinue: submitted)
        } catch {
            return failure("api_transport", mayContinue: submitted)
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

    private static func failure(_ code: String, mayContinue: Bool = false) -> Data {
        VPhoneHostCommandExecutor.response(ok: false, error: code,
            extra: mayContinue ? ["code": code, "operation_may_continue": true] : ["code": code])
    }
}
