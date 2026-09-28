import Foundation

/// JSON values used by the public API, so callers do not need `[String: Any]`.
public indirect enum VPhoneJSONValue: Codable, Sendable, Equatable {
    case object([String: VPhoneJSONValue])
    case array([VPhoneJSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() {
            self = .null
        } else if let bool = try? value.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? value.decode(Double.self) {
            self = .number(number)
        } else if let string = try? value.decode(String.self) {
            self = .string(string)
        } else if let object = try? value.decode([String: VPhoneJSONValue].self) {
            self = .object(object)
        } else {
            self = try .array(value.decode([VPhoneJSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .object(object): try value.encode(object)
        case let .array(array): try value.encode(array)
        case let .string(string): try value.encode(string)
        case let .number(number): try value.encode(number)
        case let .bool(bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }
}

public struct VPhoneAPIError: Error, Codable, Sendable, CustomStringConvertible {
    public let code: String
    public let message: String
    public var description: String {
        "\(code): \(message)"
    }
}

public struct VPhoneAPIResponse: Codable, Sendable {
    public let type: String
    public let id: VPhoneJSONValue?
    public let result: VPhoneJSONValue?
    public let error: VPhoneAPIError?
}

public struct VPhoneAPIEvent: Codable, Sendable {
    public let type: String
    public let event: String
    public let data: VPhoneJSONValue
}

public enum VPhoneAPIMessage: Sendable {
    case response(VPhoneAPIResponse)
    case event(VPhoneAPIEvent)
}
