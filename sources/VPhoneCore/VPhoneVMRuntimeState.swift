import Foundation

/// Diagnostic record only. Kernel lock ownership, not this file, determines use.
public struct VPhoneVMRuntimeState: Codable, Sendable {
    public static let filename = ".vphone-runtime.json"
    public let bundleIdentifier: String
    public let bundlePath: String
    public let pid: Int32
    public let instanceID: String
    public let startedAt: Date
    public let operation: String

    public func write(in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.filename), options: .atomic)
    }
}
