import Foundation

// MARK: - VPhoneVMOperation

/// Every `operation` string that may appear in a bundle's runtime record.
///
/// One table so the value written by a lock holder and the value a reader
/// compares against cannot drift apart. Two groups:
///
/// - `boot` and `dfu` are held for the lifetime of a running VM. Any other
///   operation must refuse to run while one of them holds the lock, and the
///   refusal tells the user to stop the VM first.
/// - Everything else is a short offline operation on the bundle's files.
public enum VPhoneVMOperation {
    // VM lifetime.
    public static let boot = "boot"
    public static let dfu = "dfu"

    // Swift offline operations.
    public static let stageVphoned = "stage-vphoned"
    public static let config = "config"
    public static let rename = "rename"
    public static let clone = "clone"
    public static let delete = "delete"
    public static let export = "export"
    public static let importArchive = "import"
    public static let create = "create"
    public static let fwPatch = "fw-patch"
    public static let cfwRecord = "cfw-record"
    public static let restoreDecrypt = "restore-decrypt"
    public static let cleanupFirmware = "cleanup-firmware"

    // Written by shell entries through `scripts/vm_lock.py`, which takes the
    // same directory flock. `fwPrepare` and `cfw` are also written by Swift
    // (`fw prepare` locks in-process; `cfw install` locks inside the host
    // driver after it re-execs under sudo). No Swift code writes the last four;
    // they are listed here so the whole vocabulary lives in one place.
    public static let fwPrepare = "fw-prepare"
    public static let cfw = "cfw"
    public static let backup = "backup"
    public static let restoreBackup = "restore-backup"
    public static let switchVM = "switch"
    public static let package = "package"

    /// Operations that own a running VM rather than a short file operation.
    public static let vmLifetime: Set<String> = [boot, dfu]

    /// Complete vocabulary, for tests and diagnostics.
    public static let all: [String] = [
        boot, dfu, stageVphoned, config, rename, clone, delete, export, importArchive, create,
        fwPrepare, fwPatch, cfw, cfwRecord, restoreDecrypt, cleanupFirmware,
        backup, restoreBackup, switchVM, package,
    ]
}

/// Diagnostic record only. Kernel lock ownership, not this file, determines use.
public struct VPhoneVMRuntimeState: Codable, Sendable {
    public static let filename = ".vphone-runtime.json"
    /// `operation` values written by a VM boot (the lock holder that owns the
    /// running VM). Every other value belongs to a short-lived operation
    /// (stage-vphoned, config, export, delete, ...). See `VPhoneVMOperation`
    /// for the whole table.
    public static let bootOperation = VPhoneVMOperation.boot
    public static let dfuOperation = VPhoneVMOperation.dfu
    public let bundleIdentifier: String
    public let bundlePath: String
    public let pid: Int32
    public let instanceID: String
    public let startedAt: Date
    public let operation: String

    /// True when this record was written by a booting VM rather than by one of
    /// the short maintenance operations that also take the bundle lock.
    public var isBootOperation: Bool {
        VPhoneVMOperation.vmLifetime.contains(operation)
    }

    /// True when this record was written by a DFU boot, the only holder a
    /// `restore` may cooperate with.
    public var isDFUOperation: Bool { operation == VPhoneVMOperation.dfu }

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
