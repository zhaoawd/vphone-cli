import Foundation

/// Diagnostic record only. Kernel lock ownership, not this file, determines use.
public struct VPhoneVMRuntimeState: Codable, Sendable {
    public static let filename = ".vphone-runtime.json"
    /// `operation` values written by a VM boot (the lock holder that owns the
    /// running VM). Every other value belongs to a short-lived operation
    /// (stage-vphoned, config, export, delete, ...).
    public static let bootOperation = "boot"
    public static let dfuOperation = "dfu"
    public let bundleIdentifier: String
    public let bundlePath: String
    public let pid: Int32
    public let instanceID: String
    public let startedAt: Date
    public let operation: String

    /// True when this record was written by a booting VM rather than by one of
    /// the short maintenance operations that also take the bundle lock.
    public var isBootOperation: Bool {
        operation == Self.bootOperation || operation == Self.dfuOperation
    }

    /// Best-effort read of the diagnostic record. Returns nil when the file is
    /// absent or unreadable/unparseable; callers must treat the content as a
    /// hint (it can be stale or belong to a finished operation).
    public static func read(in directory: URL) -> VPhoneVMRuntimeState? {
        let url = directory.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VPhoneVMRuntimeState.self, from: data)
    }

    public func write(in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.filename), options: .atomic)
    }
}
