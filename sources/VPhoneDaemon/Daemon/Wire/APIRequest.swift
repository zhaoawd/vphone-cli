import Foundation

/// Request parsing shared with firmware-free tests. The HTTP layer enforces
/// its body-size limit before calling this decoder.
struct APIRequest: @unchecked Sendable {
    let method: String
    let params: [String: Any]
    let id: Any?

    static func decode(_ data: Data) throws -> APIRequest {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = object["method"] as? String, !method.isEmpty,
              method.count <= 128,
              object["params"] == nil || object["params"] is [String: Any]
        else {
            throw APIRequestDecodingError.invalidRequest("Expected {method, params?, id?}")
        }
        let id = object["id"]
        if let id, !(id is String), !(id is NSNumber) {
            throw APIRequestDecodingError.invalidRequest("id must be a string or number")
        }
        return APIRequest(method: method, params: object["params"] as? [String: Any] ?? [:], id: id)
    }

}

enum APIRequestDecodingError: Error, CustomStringConvertible {
    case invalidRequest(String)
    var description: String {
        switch self { case let .invalidRequest(message): message }
    }
}
