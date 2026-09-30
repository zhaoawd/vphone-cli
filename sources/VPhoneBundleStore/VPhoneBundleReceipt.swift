import Foundation

public struct VPhoneBundleStoreError: LocalizedError {
    public let message: String
    init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Compatible with the upstream 2.0.8–2.2.3 receipt (the fields did not change);
/// the containing store is the trust boundary.
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

/// Store names follow upstream 2.2.3 `VPhoneLaunchpadNames`: a release
/// `X.Y.Z`, `X.Y.Z-local` for a build made on this Mac, or
/// `X.Y.Z-ci.<commit>` for a GitHub Actions artifact. Upstream 2.2.0 renamed
/// every patch identifier and dropped `--force-dsc-maxslide`, so older
/// bundles are refused by name before any store access.
enum VPhoneBundleVersion {
    static let minimum = (2, 2, 0)
    static var minimumText: String { "\(minimum.0).\(minimum.1).\(minimum.2)" }

    static func require(_ value: String) throws {
        guard value.utf8.count <= 64,
              value.range(of: "^[0-9]{1,9}\\.[0-9]{1,9}\\.[0-9]{1,9}(-local|-ci\\.[0-9a-f]{7,40})?$",
                          options: .regularExpression) != nil else {
            throw VPhoneBundleStoreError("Invalid Core Bundle version \(quoted(value)): use X.Y.Z, X.Y.Z-local or X.Y.Z-ci.<commit>.")
        }
        let parts = release(of: value).split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3, (parts[0], parts[1], parts[2]) >= minimum else {
            throw VPhoneBundleStoreError("Core Bundle \(value) is older than the minimum supported version \(minimumText).")
        }
    }

    /// The bundle's own `CFBundleShortVersionString` inside a store name.
    static func release(of value: String) -> String {
        if value.hasSuffix("-local") { return String(value.dropLast("-local".count)) }
        if let suffix = value.range(of: "-ci\\.[0-9a-f]{7,40}$", options: .regularExpression) {
            return String(value[..<suffix.lowerBound])
        }
        return value
    }

    static func quoted(_ value: String) -> String {
        "\"" + value.unicodeScalars.map { $0.properties.generalCategory == .control ? $0.escaped(asASCII: true) : String($0) }
            .joined() + "\""
    }
}
