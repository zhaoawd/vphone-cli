import Foundation

/// Event-loop-confined connection state. Admission is a one-use preface; the
/// external classification survives every subsequent HTTP head and WS frame.
final class GuestProxyAdmission: @unchecked Sendable {
    static let capability = "external_proxy_maintenance_v1"
    private(set) var external = false
    private var consumed = false

    func admit(classes: [String], nonces: [String]) -> String? {
        guard !external, !consumed, classes == ["external"], nonces.count == 1,
              UUID(uuidString: nonces[0]) != nil else { return nil }
        external = true
        return nonces[0]
    }

    func consumeRequest() -> Bool {
        guard !consumed else { return false }
        consumed = true
        return true
    }
}
