import Foundation

/// Generated once per daemon process, including each re-executed API worker.
enum APISessionIdentity {
    static let instanceID = UUID().uuidString
    static let capability = "session_identity"
}
