import Foundation

/// Comparison of separately supplied observations. This neither acquires an
/// observation nor proves pairing/trust, and never changes a guest identity.
public struct VPhoneDeviceIdentityCheck: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case incomplete, invalid, mismatch, matching }
    public let expected: String?
    public let guest: String?
    public let host: String?
    public let state: State

    public init(expected: String?, guest: String?, host: String?) {
        self.expected = Self.normalized(expected)
        self.guest = Self.normalized(guest)
        self.host = Self.normalized(host)
        let raw = [expected, guest, host]
        let values = [self.expected, self.guest, self.host]
        if zip(raw, values).contains(where: { $0 != nil && $1 == nil }) {
            state = .invalid
        } else if Set(values.compactMap { $0 }).count > 1 {
            state = .mismatch
        } else if values.contains(where: { $0 == nil }) {
            state = .incomplete
        } else {
            state = .matching
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if text.range(of: "^[0-9A-F]{8}-[0-9A-F]{16}$", options: .regularExpression) != nil ||
           text.range(of: "^[0-9A-F]{40}$", options: .regularExpression) != nil { return text }
        if text.range(of: "^[0-9A-F]{24}$", options: .regularExpression) != nil {
            let cut = text.index(text.startIndex, offsetBy: 8)
            return String(text[..<cut]) + "-" + String(text[cut...])
        }
        return nil
    }
}
