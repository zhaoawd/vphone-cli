import Foundation

public struct VPhoneBundleStoreError: LocalizedError {
    public let message: String
    init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Compatible with the upstream 2.0.8 receipt; the containing store is the trust boundary.
public struct VPhoneBundleReceipt: Codable, Equatable, Sendable {
    public let version: String
    public let sha256: String
    public let installedAt: Date
    public let cdhashes: [String: String]

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: data)
    }
}

public enum VPhoneBundleExecutable: String, CaseIterable, Sendable {
    case cli = "vphone-cli"
    case vm = "vphone-vm"
}

enum VPhoneBundleVersion {
    static func require(_ value: String) throws {
        guard value.utf8.count <= 64,
              value.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+(-local)?$", options: .regularExpression) != nil else {
            throw VPhoneBundleStoreError("Invalid Core Bundle version: \(value)")
        }
        let release = value.hasSuffix("-local") ? String(value.dropLast(6)) : value
        let parts = release.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3, (parts[0], parts[1], parts[2]) >= (2, 0, 8) else {
            throw VPhoneBundleStoreError("Core Bundle 2.0.8 or newer is required.")
        }
    }
}
