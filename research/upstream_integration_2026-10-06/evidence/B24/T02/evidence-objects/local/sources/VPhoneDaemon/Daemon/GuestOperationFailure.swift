import Foundation

/// Retain the operation's JSON result alongside the machine-readable error.
enum GuestOperationFailure {
    static func response(code: String, message: String, details: [String: Any]?) -> [String: Any] {
        var value: [String: Any] = ["code": code, "message": message]
        if let details { value["details"] = details }
        return value
    }
}
