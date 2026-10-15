import CryptoKit
import Darwin
import Foundation
import VPhoneKernelIOTrace
import VPhoneCore

/// Desired state is independent of transaction evidence. Call mutations under the VM lock.
public enum FirmwareDesiredPlanStore {
    public static let filename = ".firmware-desired-plan.json"
    static let pendingFilename = ".firmware-desired-pending.json"
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case missing, corrupt, identityMismatch, invalidPlan, changedSincePreview, publicationUncertain, backupConflict
        case unreadable(Int32), unsupportedSchema(Int)
        public var description: String {
            switch self {
            case .missing: "Missing desired plan; explicitly preview and save a bound plan first"
            case .corrupt: "Corrupt desired plan"
            case .identityMismatch: "Firmware desired plan VM/generation/disk identity mismatch"
            case .invalidPlan: "Firmware desired plan differs from current catalog, rules or version context"
            case .changedSincePreview: "Firmware desired plan changed since preview"
            case .publicationUncertain: "Firmware desired plan publication uncertain; explicit readback required before retry"
            case .backupConflict: "Firmware desired plan backup conflicts with preserved evidence"
            case let .unreadable(code): "Unreadable desired plan: errno \(code)"
            case let .unsupportedSchema(version): "Unsupported desired plan schema \(version)"
            }
        }
    }
    public struct Record: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let upstreamTarget: String
        public let catalogSHA256: String
        public let planSHA256: String
        public let generationID: String
        public let identity: VPhoneFirmwareIdentity
        public let plan: VariantPlanResolver.VariantPlan
        /// Raw-file CAS digest: read accepts only this exact canonical encoding.
        public var sha256: String { get throws { try recordDigest(self) } }
    }
    public enum Read: Sendable {
        case missing
        case legacy(PatchSelectionFileMigration.Preview)
        case ready(Record)
    }
    public struct Prepared: Sendable {
        public let record: Record
        public let expectedSHA256: String?
        public var expectedLegacySHA256: String? { legacy.map(FirmwareDesiredPlanStore.sha) }
        let directory: URL
        let previous: Data?
        let legacy: Data?
    }
    struct Pending: Codable { let previousSHA256: String?; let candidate: Record }
    enum Event: CaseIterable { case beforeBackup, backupFileSync, backupSync, afterBackup, candidateSync, pendingFileSync, pendingDirectorySync, beforeRename, afterRename, directorySync, cleanupSync }

    public static func read(in directory: URL) throws -> Read {
        if try bytes(directory.appendingPathComponent(pendingFilename)) != nil { throw Failure.publicationUncertain }
        return try readCurrent(in: directory)
    }
    private static func readCurrent(in directory: URL) throws -> Read {
        guard let data = try bytes(directory.appendingPathComponent(filename)) else {
            if try bytes(directory.appendingPathComponent(PatchSelectionFileMigration.filename)) != nil {
                return .legacy(try PatchSelectionFileMigration.prepare(file: directory.appendingPathComponent(PatchSelectionFileMigration.filename)).preview)
            }
            return .missing
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schema = object["schemaVersion"] as? Int else { throw Failure.corrupt }
        guard schema == 1 else { throw Failure.unsupportedSchema(schema) }
        guard let record = try? JSONDecoder().decode(Record.self, from: data), try encoded(record) == data else { throw Failure.corrupt }
        try validate(record, in: directory)
        return .ready(record)
    }
    public static func prepare(in directory: URL, plan: VariantPlanResolver.VariantPlan,
                               generation: FirmwareGeneration.Manifest) throws -> Prepared {
        let observed = try bytes(directory.appendingPathComponent(filename))
        let observedLegacy = try bytes(directory.appendingPathComponent(PatchSelectionFileMigration.filename))
        let state = try read(in: directory)
        // A decoded Manifest is only data. Always re-open the actual generation.
        let verified: FirmwareGeneration.Manifest
        do { verified = try FirmwareGeneration.loadVerified(in: directory, id: generation.id) }
        catch { throw Failure.identityMismatch }
        guard verified == generation else { throw Failure.identityMismatch }
        let record = Record(schemaVersion: 1, upstreamTarget: PatchSelectionMigration.upstreamTarget,
            catalogSHA256: try FirmwarePlanBinding.catalogDigest(), planSHA256: try FirmwareGeneration.planDigest(plan),
            generationID: verified.id, identity: verified.content.identity, plan: plan)
        try validate(record, in: directory)
        if case .legacy(let legacy) = state {
            guard let variant = FirmwarePipeline.Variant(rawValue: plan.variant),
                  try VariantPlanResolver.resolve(variant: variant, gates: plan.gates,
                    select: Set(legacy.selection.selected), block: Set(legacy.selection.blocked)) == plan else {
                throw Failure.invalidPlan
            }
        }
        let previous = try bytes(directory.appendingPathComponent(filename))
        let legacy = try bytes(directory.appendingPathComponent(PatchSelectionFileMigration.filename))
        guard previous == observed, legacy == observedLegacy else { throw Failure.changedSincePreview }
        return Prepared(record: record, expectedSHA256: previous.map(sha), directory: directory, previous: previous, legacy: legacy)
    }
    public static func publish(_ prepared: Prepared, expectedSHA256: String?) throws -> Record {
        try publish(prepared, expectedSHA256: expectedSHA256, inject: { _ in })
    }
    static func publish(_ prepared: Prepared, expectedSHA256: String?, inject: (Event) throws -> Void) throws -> Record {
        try withStoreLock(prepared.directory) {
            let directory = prepared.directory
            if try bytes(directory.appendingPathComponent(pendingFilename)) != nil { throw Failure.publicationUncertain }
            guard expectedSHA256 == prepared.expectedSHA256 else { throw Failure.changedSincePreview }
            func check() throws {
                guard try bytes(directory.appendingPathComponent(filename)) == prepared.previous,
                      try bytes(directory.appendingPathComponent(PatchSelectionFileMigration.filename)) == prepared.legacy else {
                    throw Failure.changedSincePreview
                }
                try validate(prepared.record, in: directory)
            }
            try check()
            try inject(.beforeBackup)
            for data in [prepared.previous, prepared.legacy].compactMap({ $0 }) {
                let backup = directory.appendingPathComponent(".firmware-desired-backup-" + sha(data))
                if let existing = try bytes(backup) {
                    guard existing == data else { throw Failure.backupConflict }
                    try syncFile(backup)
                } else { try writeExclusive(data, to: backup, beforeSync: { try inject(.backupFileSync) }) }
            }
            try inject(.backupSync)
            try syncDirectory(directory)
            try inject(.afterBackup)
            let candidate = directory.appendingPathComponent(".firmware-desired-candidate-" + UUID().uuidString)
            try writeExclusive(encoded(prepared.record), to: candidate, beforeSync: { try inject(.candidateSync) })
            defer { try? FileManager.default.removeItem(at: candidate) }
            try check()
            let pending = directory.appendingPathComponent(pendingFilename)
            let intent = try encoded(Pending(previousSHA256: prepared.expectedSHA256, candidate: prepared.record))
            do {
                try writeExclusive(intent, to: pending, beforeSync: { try inject(.pendingFileSync) })
                try inject(.pendingDirectorySync)
                try syncDirectory(directory)
                try inject(.beforeRename)
                try check()
                // All supported writers serialize with both the VM lock and this store lock.
                let destination = directory.appendingPathComponent(filename)
                let result = prepared.previous == nil
                    ? renamex_np(candidate.path, destination.path, UInt32(RENAME_EXCL))
                    : rename(candidate.path, destination.path)
                guard result == 0 else { throw Failure.unreadable(errno) }
                try inject(.afterRename)
                try inject(.directorySync)
                try syncDirectory(directory)
                guard case .ready(let actual) = try readCurrent(in: directory), actual == prepared.record else { throw Failure.corrupt }
                guard unlink(pending.path) == 0 else { throw Failure.unreadable(errno) }
                try inject(.cleanupSync)
                try syncDirectory(directory)
                return actual
            } catch {
                // Keep an explicit barrier even if failure followed the marker unlink.
                if (try? bytes(pending)) == nil { try? writeExclusive(intent, to: pending) }
                throw Failure.publicationUncertain
            }
        }
    }
    /// Reconcile publication evidence only. Never invokes a patcher or republishes a candidate.
    public static func readback(in directory: URL) throws -> Read {
        try withStoreLock(directory) {
            let pendingURL = directory.appendingPathComponent(pendingFilename)
            guard let data = try bytes(pendingURL) else { return try readCurrent(in: directory) }
            guard let pending = try? JSONDecoder().decode(Pending.self, from: data) else { throw Failure.corrupt }
            let actual = try bytes(directory.appendingPathComponent(filename))
            let candidate = try encoded(pending.candidate)
            guard actual.map(sha) == pending.previousSHA256 || actual == candidate else { throw Failure.changedSincePreview }
            let observed = try readCurrent(in: directory)
            try syncDirectory(directory)
            guard unlink(pendingURL.path) == 0 else { throw Failure.unreadable(errno) }
            try syncDirectory(directory)
            return observed
        }
    }
    static func validate(_ record: Record, in directory: URL) throws {
        let generation: FirmwareGeneration.Manifest
        do { generation = try FirmwareGeneration.loadVerified(in: directory, id: record.generationID) }
        catch { throw Failure.identityMismatch }
        guard generation.content.identity == record.identity else { throw Failure.identityMismatch }
        guard record.schemaVersion == 1, record.upstreamTarget == PatchSelectionMigration.upstreamTarget,
              try record.catalogSHA256 == FirmwarePlanBinding.catalogDigest(),
              try record.planSHA256 == FirmwareGeneration.planDigest(record.plan) else { throw Failure.invalidPlan }
        try FirmwarePlanBinding.validateCurrentPlan(record.plan)
        let originals = try FirmwareGeneration.originalURLs(in: directory, id: record.generationID)
        guard let restore = originals.first(where: { $0.lastPathComponent.contains("Restore") }),
              let variant = FirmwarePipeline.Variant(rawValue: record.plan.variant) else { throw Failure.invalidPlan }
        let versions = try FirmwareVersionInputs.read(in: restore)
        guard let base = FirmwareVersionInputs.components(versions.baseVersion)?.first else { throw Failure.invalidPlan }
        let g = record.plan.gates
        let capable = FirmwarePipeline.productVersionAtLeast(versions.cloudOSVersion, 26, 4)
        guard g.variant == variant.rawValue, g.iosBaseIs18 == (base == 18), g.iosBaseIs27 == (base == 27),
              g.cloudOSIsFridaCapable == capable, g.applyIOS27 == (base == 27),
              g.excGuardActive == (variant == .dev || base == 18 || g.forceExcGuard),
              g.applyFrida == (g.enableFrida && capable) else { throw Failure.invalidPlan }
    }
    private static func withStoreLock<T>(_ directory: URL, _ body: () throws -> T) throws -> T {
        let fd = open(directory.appendingPathComponent(".firmware-desired.lock").path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unreadable(errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw Failure.corrupt }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.changedSincePreview }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    private static func bytes(_ url: URL) throws -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 { if errno == ENOENT { return nil }; throw Failure.unreadable(errno) }
        defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_size >= 0, before.st_size <= 8 << 20 else { throw Failure.corrupt }
        guard before.st_mode & 0o444 != 0 else { throw Failure.unreadable(EACCES) }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
        guard fstat(fd, &after) == 0, data.count == before.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Failure.changedSincePreview }
        return data
    }
    private static func writeExclusive(_ data: Data, to url: URL, beforeSync: () throws -> Void = {}) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unreadable(errno) }
        defer { close(fd) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
        try beforeSync()
        guard KernelIOTrace.synchronize(fd, phase: "FirmwareDesiredPlanStore.fsync") == 0 else { throw Failure.unreadable(errno) }
    }
    private static func syncFile(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unreadable(errno) }; defer { close(fd) }
        guard KernelIOTrace.synchronize(fd, phase: "FirmwareDesiredPlanStore.fsync") == 0 else { throw Failure.unreadable(errno) }
    }
    private static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unreadable(errno) }; defer { close(fd) }
        guard KernelIOTrace.synchronize(fd, phase: "FirmwareDesiredPlanStore.fsync") == 0 else { throw Failure.unreadable(errno) }
    }
    private static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func recordDigest<T: Encodable>(_ value: T) throws -> String { sha(try encoded(value)) }
}
