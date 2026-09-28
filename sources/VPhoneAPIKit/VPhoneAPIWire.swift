import Foundation

/// Host limits for API v1 JSON messages. File streaming is a separate protocol.
enum VPhoneAPIWire {
    static let maximumRequestBytes = 1024 * 1024
    static let maximumResponseBytes = 8 * 1024 * 1024

    static func request(_ method: String, params: [String: VPhoneJSONValue], id: String) throws -> Data {
        guard !method.isEmpty, method.count <= 128 else {
            throw VPhoneAPIError(code: "invalid_request", message: "Method must contain 1 to 128 characters")
        }
        let data = try JSONEncoder().encode(VPhoneJSONValue.object([
            "method": .string(method), "params": .object(params), "id": .string(id),
        ]))
        guard data.count <= maximumRequestBytes else {
            throw VPhoneAPIError(code: "request_too_large", message: "API request exceeds 1 MiB")
        }
        return data
    }

    static func object(_ data: Data) throws -> [String: VPhoneJSONValue] {
        guard data.count <= maximumResponseBytes else {
            throw VPhoneAPIError(code: "response_too_large", message: "API message exceeds 8 MiB")
        }
        guard case let .object(value) = try JSONDecoder().decode(VPhoneJSONValue.self, from: data) else {
            throw invalidEnvelope()
        }
        return value
    }

    static func message(_ data: Data) throws -> VPhoneAPIMessage {
        let object = try object(data)
        switch object["type"] {
        case .string("response"):
            // A result can be JSON null. Presence, not Optional decoding, defines success.
            guard case .string = object["id"],
                  (object["result"] != nil) != (object["error"] != nil)
            else { throw invalidEnvelope() }
            let error: VPhoneAPIError?
            if let value = object["error"] {
                error = try JSONDecoder().decode(VPhoneAPIError.self, from: JSONEncoder().encode(value))
            } else {
                error = nil
            }
            return .response(VPhoneAPIResponse(type: "response", id: object["id"], result: object["result"], error: error))
        case .string("event"):
            guard case let .string(name) = object["event"], !name.isEmpty, let data = object["data"] else {
                throw invalidEnvelope()
            }
            return .event(VPhoneAPIEvent(type: "event", event: name, data: data))
        default: throw invalidEnvelope()
        }
    }

    static func result(_ response: VPhoneAPIResponse) throws -> VPhoneJSONValue {
        if let error = response.error { throw error }
        guard let result = response.result else { throw invalidEnvelope() }
        return result
    }

    static func invalidEnvelope() -> VPhoneAPIError {
        VPhoneAPIError(code: "protocol", message: "Invalid API v1 envelope")
    }
}

public struct VPhoneAPIHealth: Codable, Sendable, Equatable {
    public let apiVersion: Int
    public let binaryHash: String
    public let capabilities: Set<String>
    public let ios: String?
    public let instanceID: String?

    static func decode(_ data: Data, requiredCapabilities: Set<String>, expectedBinaryHash: String?) throws -> Self {
        let value = try VPhoneAPIWire.object(data)
        guard value["api_version"] == .number(1), value["status"] == .string("ok"),
              case let .string(hash) = value["binary_hash"], hash.utf8.count == 64,
              hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              case let .array(entries) = value["capabilities"]
        else { throw VPhoneAPIError(code: "incompatible_api", message: "Invalid API v1 health response") }
        var capabilities = Set<String>()
        for entry in entries {
            guard case let .string(name) = entry, !name.isEmpty else { throw VPhoneAPIWire.invalidEnvelope() }
            capabilities.insert(name)
        }
        guard requiredCapabilities.isSubset(of: capabilities) else {
            throw VPhoneAPIError(code: "unsupported_capability", message: "Guest is missing required capabilities")
        }
        if let expectedBinaryHash, hash != expectedBinaryHash {
            throw VPhoneAPIError(code: "binary_mismatch", message: "Guest daemon SHA-256 does not match")
        }
        let ios: String?
        if case let .string(version) = value["ios"] { ios = version } else { ios = nil }
        let instanceID: String?
        if let instance = value["instance_id"] {
            guard case let .string(id) = instance, let uuid = UUID(uuidString: id) else {
                throw VPhoneAPIWire.invalidEnvelope()
            }
            instanceID = uuid.uuidString
        } else { instanceID = nil }
        return Self(apiVersion: 1, binaryHash: hash, capabilities: capabilities, ios: ios, instanceID: instanceID)
    }
}
