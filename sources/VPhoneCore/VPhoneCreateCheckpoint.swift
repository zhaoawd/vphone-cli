import CryptoKit
import Darwin
import Foundation

// MARK: - Stages

/// The ordered stages of `vm create`. Raw values are the checkpoint spelling.
public enum VPhoneCreateStage: String, Codable, CaseIterable, Sendable, Comparable {
    case prepare
    case patch
    case restore
    case cfw
    case firstBoot = "first_boot"
    case jbFinalize = "jb_finalize"
    case verification

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// Why a stage does not apply to a variant, or nil when it applies. The
    /// only source of `not_applicable`; a missing executor result never is.
    public static func notApplicableRule(_ stage: Self, variant: String) -> String? {
        switch stage {
        case .cfw where variant == "less":
            "variant less installs no CFW"
        case .jbFinalize where variant != "jb" && variant != "exp":
            "jb_finalize applies only to variants jb and exp"
        default:
            nil
        }
    }
}

public enum VPhoneCreateStageStatus: String, Codable, Sendable {
    case pending
    case running
    /// Executor completed and the read-only verifier accepted the evidence.
    case succeeded
    /// Executor completed but no verifier evidence exists; recorded with a reason.
    /// Never counts as success.
    case unverified
    case failed
    case cancelled
    case notApplicable = "not_applicable"

    /// Terminal states the pipeline moves past.
    public var isDone: Bool { self == .succeeded || self == .unverified || self == .notApplicable }
}

public enum VPhoneCreateOverallStatus: String, Codable, Sendable {
    case incomplete
    case interrupted
    case failed
    case cancelled
    case recoveryRequired = "recovery_required"
    case completedUnverified = "completed_unverified"
    case succeeded
}

// MARK: - Options

/// A firmware source as recorded. URL user info and query are never stored in
/// clear text; the digest of the full string still identifies it.
public struct VPhoneCreateSourceRecord: Codable, Equatable, Sendable {
    public var display: String
    public var sha256: String
    public var redacted: Bool

    public init(_ source: String) {
        sha256 = VPhoneCreateDigest.sha256(Data(source.utf8))
        if var parts = URLComponents(string: source), parts.scheme != nil,
           parts.user != nil || parts.password != nil || parts.query != nil || parts.fragment != nil {
            parts.user = nil
            parts.password = nil
            parts.query = nil
            parts.fragment = nil
            display = parts.string ?? "<redacted>"
            redacted = true
        } else {
            display = source
            redacted = false
        }
    }
}

/// Normalized options that decide what a create produces. Operator conveniences
/// (sudo password, root popup, interactive, verbosity, keep-artifacts) are not
/// part of it and may differ between attempts.
public struct VPhoneCreateEffectiveOptions: Codable, Equatable, Sendable {
    public var variant: String
    public var iphoneSource: VPhoneCreateSourceRecord?
    public var cloudosSource: VPhoneCreateSourceRecord?
    public var spoofBuild: String?
    public var forceDscMaxSlide: Bool
    public var enableFrida: Bool
    public var cpuCount: UInt
    public var memoryMb: UInt64
    public var diskSizeGb: UInt64

    public init(
        variant: String, iphoneSource: String?, cloudosSource: String?, spoofBuild: String?,
        forceDscMaxSlide: Bool, enableFrida: Bool, cpuCount: UInt, memoryMb: UInt64, diskSizeGb: UInt64
    ) {
        self.variant = variant
        self.iphoneSource = iphoneSource.map(VPhoneCreateSourceRecord.init)
        self.cloudosSource = cloudosSource.map(VPhoneCreateSourceRecord.init)
        self.spoofBuild = spoofBuild
        self.forceDscMaxSlide = forceDscMaxSlide
        self.enableFrida = enableFrida
        self.cpuCount = cpuCount
        self.memoryMb = memoryMb
        self.diskSizeGb = diskSizeGb
    }

    public var digest: String {
        VPhoneCreateDigest.sha256((try? VPhoneCreateJSON.encoder.encode(self)) ?? Data())
    }

    /// Changed option names mapped to the earliest stage each one affects.
    public func changes(to other: Self) -> [(field: String, stage: VPhoneCreateStage)] {
        var result: [(String, VPhoneCreateStage)] = []
        if variant != other.variant {
            // Only less changes what fw prepare downloads.
            result.append(("variant", variant == "less" || other.variant == "less" ? .prepare : .patch))
        }
        if iphoneSource?.sha256 != other.iphoneSource?.sha256 { result.append(("iphone_source", .prepare)) }
        if cloudosSource?.sha256 != other.cloudosSource?.sha256 { result.append(("cloudos_source", .prepare)) }
        if cpuCount != other.cpuCount { result.append(("cpu_count", .prepare)) }
        if memoryMb != other.memoryMb { result.append(("memory_mb", .prepare)) }
        if diskSizeGb != other.diskSizeGb { result.append(("disk_size_gb", .prepare)) }
        if enableFrida != other.enableFrida { result.append(("enable_frida", .patch)) }
        if spoofBuild != other.spoofBuild { result.append(("spoof_build", .cfw)) }
        if forceDscMaxSlide != other.forceDscMaxSlide { result.append(("force_dsc_max_slide", .cfw)) }
        return result
    }
}

// MARK: - Identity, tool, artifacts

public struct VPhoneCreateBundleIdentity: Codable, Equatable, Sendable {
    public var name: String
    public var path: String
    /// `st_dev:st_ino` of the bundle directory. A clone, copy, import or a
    /// replacement directory at the same path gets a different value.
    public var directoryId: String
    /// SHA-256 of config.plist `machineIdentifier` once a boot has created it.
    public var machineIdentifierSha256: String?

    public init(name: String, path: String, directoryId: String, machineIdentifierSha256: String? = nil) {
        self.name = name
        self.path = path
        self.directoryId = directoryId
        self.machineIdentifierSha256 = machineIdentifierSha256
    }
}

public struct VPhoneCreateToolRecord: Codable, Equatable, Sendable {
    public var executableSha256: String?
    public var stageContractVersion: Int

    public init(executableSha256: String?, stageContractVersion: Int) {
        self.executableSha256 = executableSha256
        self.stageContractVersion = stageContractVersion
    }
}

public enum VPhoneCreateFingerprintKind: String, Codable, Sendable {
    /// Content digest; used for small files.
    case sha256File = "sha256_file"
    /// size, mtime, inode; used for large images whose content hash is too slow.
    case fileMetadata = "file_metadata"
    /// Relative path, node type, size, mtime and inode of every entry.
    case treeMetadata = "tree_metadata"
}

public enum VPhoneCreateArtifactAvailability: String, Codable, Sendable {
    case available
    case removed
}

/// What a verifier reports it observed; the runner computes the fingerprint.
public struct VPhoneCreateArtifactSpec: Equatable, Sendable {
    public var name: String
    public var relativePath: String
    public var kind: VPhoneCreateFingerprintKind
    /// Stages that need this artifact, either as input or for recovery.
    public var retainUntil: [VPhoneCreateStage]

    public init(name: String, relativePath: String, kind: VPhoneCreateFingerprintKind, retainUntil: [VPhoneCreateStage] = []) {
        self.name = name
        self.relativePath = relativePath
        self.kind = kind
        self.retainUntil = retainUntil
    }
}

public struct VPhoneCreateArtifactRecord: Codable, Equatable, Sendable {
    public var name: String
    public var relativePath: String
    public var kind: VPhoneCreateFingerprintKind
    public var fingerprint: String?
    public var sizeBytes: Int64?
    public var availability: VPhoneCreateArtifactAvailability
    public var recordedBy: VPhoneCreateStage
    public var retainUntil: [VPhoneCreateStage]
    public var removedReason: String?
    public var rebuild: String?
}

// MARK: - Stage record

public struct VPhoneCreateStageHistoryEntry: Codable, Equatable, Sendable {
    public var attemptId: String?
    public var status: VPhoneCreateStageStatus
    public var startedAt: Date?
    public var finishedAt: Date?
    public var error: String?
    public var reason: String?
    /// Why the record was moved into history (rerun, restart, interrupted).
    public var supersededBecause: String
}

public struct VPhoneCreateStageRecord: Codable, Equatable, Sendable {
    public var stage: VPhoneCreateStage
    public var status: VPhoneCreateStageStatus
    public var attemptId: String?
    public var pid: Int32?
    public var startedAt: Date?
    public var finishedAt: Date?
    /// `completed` when the executor returned; `threw` when it raised.
    public var executorResult: String?
    public var verifierVersion: String?
    public var evidence: [String: String]
    /// Fingerprints of every available artifact when the stage started.
    public var inputs: [String: String]
    public var outputs: [String]
    public var reason: String?
    public var error: String?
    public var history: [VPhoneCreateStageHistoryEntry]

    init(stage: VPhoneCreateStage, variant: String) {
        self.stage = stage
        let rule = VPhoneCreateStage.notApplicableRule(stage, variant: variant)
        status = rule == nil ? .pending : .notApplicable
        reason = rule
        evidence = [:]
        inputs = [:]
        outputs = []
        history = []
    }

    /// Move the current record into history and reset it to its initial state.
    mutating func supersede(because why: String, variant: String) {
        if status != .pending && status != .notApplicable {
            history.append(VPhoneCreateStageHistoryEntry(
                attemptId: attemptId, status: status, startedAt: startedAt, finishedAt: finishedAt,
                error: error, reason: reason, supersededBecause: why))
        }
        let kept = history
        self = VPhoneCreateStageRecord(stage: stage, variant: variant)
        history = kept
    }
}

// MARK: - Attempts and recovery

public struct VPhoneCreateAttemptRef: Codable, Equatable, Sendable {
    public var attemptId: String
    /// SHA-256 of the checkpoint file as it was when this attempt began.
    public var checkpointSha256: String
    /// Location of that file, relative to the checkpoint directory.
    public var archivedAs: String
}

public struct VPhoneCreateAttemptRecord: Codable, Equatable, Sendable {
    public var attemptId: String
    public var kind: String
    public var startedAt: Date
    public var pid: Int32
    public var restartFrom: VPhoneCreateStage?
    public var acceptedToolChange: Bool
    /// Stage → evidence of the re-verification or re-probe done before this attempt ran.
    public var checks: [String: String]
}

public struct VPhoneCreateRecoveryRequirement: Codable, Equatable, Sendable {
    public var kind: String
    public var stage: VPhoneCreateStage?
    public var detail: String
    public var action: String
}

// MARK: - Checkpoint

public struct VPhoneCreateCheckpoint: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    /// Bump when a stage's output contract changes incompatibly.
    public static let stageContractVersion = 1

    public var schemaVersion: Int
    public var creationId: String
    public var createdAt: Date
    public var updatedAt: Date
    public var bundleIdentity: VPhoneCreateBundleIdentity
    public var effectiveOptions: VPhoneCreateEffectiveOptions
    public var inputsDigest: String
    public var tool: VPhoneCreateToolRecord
    public var attemptId: String
    public var resumedFrom: VPhoneCreateAttemptRef?
    public var attempts: [VPhoneCreateAttemptRecord]
    public var stages: [VPhoneCreateStageRecord]
    public var artifacts: [VPhoneCreateArtifactRecord]
    public var recoveryRequired: VPhoneCreateRecoveryRequirement?

    public init(
        identity: VPhoneCreateBundleIdentity, options: VPhoneCreateEffectiveOptions,
        tool: VPhoneCreateToolRecord, now: Date
    ) {
        schemaVersion = Self.currentSchemaVersion
        creationId = UUID().uuidString.lowercased()
        createdAt = now
        updatedAt = now
        bundleIdentity = identity
        effectiveOptions = options
        inputsDigest = options.digest
        self.tool = tool
        attemptId = UUID().uuidString.lowercased()
        attempts = [VPhoneCreateAttemptRecord(
            attemptId: attemptId, kind: "create", startedAt: now, pid: getpid(),
            restartFrom: nil, acceptedToolChange: false, checks: [:])]
        stages = VPhoneCreateStage.allCases.map { VPhoneCreateStageRecord(stage: $0, variant: options.variant) }
        artifacts = []
    }

    public func record(_ stage: VPhoneCreateStage) -> VPhoneCreateStageRecord {
        stages.first { $0.stage == stage }!
    }

    mutating func update(_ stage: VPhoneCreateStage, _ body: (inout VPhoneCreateStageRecord) -> Void) {
        let index = stages.firstIndex { $0.stage == stage }!
        body(&stages[index])
    }

    /// The record of `name` written by the latest stage, which is the one later
    /// stages consume. Older records of the same name only document history.
    public func artifact(_ name: String) -> VPhoneCreateArtifactRecord? {
        artifacts.filter { $0.name == name }.max { $0.recordedBy < $1.recordedBy }
    }

    /// First stage that still has to run, nil when every stage is done.
    public var nextStage: VPhoneCreateStage? {
        stages.first { !$0.status.isDone }?.stage
    }

    public var overallStatus: VPhoneCreateOverallStatus {
        if recoveryRequired != nil { return .recoveryRequired }
        let statuses = stages.map(\.status)
        if statuses.contains(.failed) { return .failed }
        if statuses.contains(.cancelled) { return .cancelled }
        if statuses.contains(.running) { return .interrupted }
        guard statuses.allSatisfy(\.isDone) else { return .incomplete }
        return statuses.contains(.unverified) ? .completedUnverified : .succeeded
    }

    /// Artifacts whose every retaining stage is done and which are still present.
    public var removableArtifacts: [VPhoneCreateArtifactRecord] {
        artifacts.filter { artifact in
            artifact.availability == .available && !artifact.retainUntil.isEmpty
                && artifact.retainUntil.allSatisfy { record($0).status.isDone }
        }
    }

    // MARK: Validation

    /// Structural checks run before any executor. Throws on the first violation.
    public func validate() throws {
        func invalid(_ message: String) -> VPhoneCreateCheckpointError { .invalid(message) }
        guard schemaVersion == Self.currentSchemaVersion else {
            throw VPhoneCreateCheckpointError.unsupportedSchema(schemaVersion)
        }
        guard UUID(uuidString: creationId) != nil else { throw invalid("creation_id is not a UUID") }
        guard UUID(uuidString: attemptId) != nil else { throw invalid("attempt_id is not a UUID") }
        guard attempts.contains(where: { $0.attemptId == attemptId }) else {
            throw invalid("attempt_id has no attempt record")
        }
        guard Set(attempts.map(\.attemptId)).count == attempts.count else { throw invalid("duplicate attempt ids") }
        guard inputsDigest == effectiveOptions.digest else { throw invalid("inputs_digest does not match effective_options") }
        guard ["regular", "dev", "jb", "exp", "less"].contains(effectiveOptions.variant) else {
            throw invalid("unknown variant \(effectiveOptions.variant)")
        }
        let names = stages.map(\.stage)
        guard Set(names).count == names.count else { throw invalid("duplicate stage records") }
        guard names == VPhoneCreateStage.allCases else { throw invalid("stage list must be exactly \(VPhoneCreateStage.allCases.map(\.rawValue))") }
        var sawUnfinished = false
        var running = 0
        for record in stages {
            let rule = VPhoneCreateStage.notApplicableRule(record.stage, variant: effectiveOptions.variant)
            if (record.status == .notApplicable) != (rule != nil) {
                throw invalid("\(record.stage.rawValue): not_applicable does not match the variant rule")
            }
            if record.status == .running { running += 1 }
            switch record.status {
            case .succeeded, .unverified:
                guard !sawUnfinished else { throw invalid("\(record.stage.rawValue) is done after an unfinished stage") }
                guard record.executorResult == "completed", record.verifierVersion != nil,
                      record.startedAt != nil, record.finishedAt != nil
                else { throw invalid("\(record.stage.rawValue): done without executor result and verifier") }
                if record.status == .unverified, record.reason == nil {
                    throw invalid("\(record.stage.rawValue): unverified without a reason")
                }
            case .notApplicable:
                break
            case .pending:
                sawUnfinished = true
            case .running, .failed, .cancelled:
                guard !sawUnfinished else { throw invalid("\(record.stage.rawValue) started after an unfinished stage") }
                guard record.startedAt != nil, record.attemptId != nil else {
                    throw invalid("\(record.stage.rawValue): \(record.status.rawValue) without attempt and start time")
                }
                sawUnfinished = true
            }
        }
        guard running <= 1 else { throw invalid("more than one running stage") }
        let artifactKeys = artifacts.map { "\($0.name)\u{0}\($0.recordedBy.rawValue)" }
        guard Set(artifactKeys).count == artifactKeys.count else { throw invalid("duplicate artifact records") }
        for artifact in artifacts {
            try Self.validateRelativePath(artifact.relativePath)
            if artifact.availability == .available, artifact.fingerprint == nil {
                throw invalid("artifact \(artifact.name) is available without a fingerprint")
            }
            guard record(artifact.recordedBy).status == .succeeded || record(artifact.recordedBy).status == .unverified else {
                throw invalid("artifact \(artifact.name) recorded by \(artifact.recordedBy.rawValue), which is not done")
            }
        }
    }

    static func validateRelativePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw VPhoneCreateCheckpointError.invalid("artifact path escapes the bundle: \(path)")
        }
    }
}

public enum VPhoneCreateCheckpointError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case missing(String)
    case unsupportedSchema(Int)
    case unreadable(String)
    case invalid(String)

    public var description: String {
        switch self {
        case let .missing(path): "no create checkpoint at \(path)"
        case let .unsupportedSchema(version): "create checkpoint schema_version \(version) is not supported (expected \(VPhoneCreateCheckpoint.currentSchemaVersion))"
        case let .unreadable(detail): "create checkpoint is unreadable: \(detail)"
        case let .invalid(detail): "create checkpoint is invalid: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}

// MARK: - JSON and digests

public enum VPhoneCreateJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum VPhoneCreateDigest {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(fileAt url: URL) throws -> (digest: String, size: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var size: Int64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
            size += Int64(chunk.count)
        }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }

    /// Fingerprint of an artifact inside the bundle. Throws when it is missing
    /// or has the wrong node type.
    public static func fingerprint(
        _ kind: VPhoneCreateFingerprintKind, at url: URL
    ) throws -> (fingerprint: String, size: Int64) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw VPhoneCreateRunError.artifactMissing(url.path)
        }
        let type = info.st_mode & S_IFMT
        switch kind {
        case .sha256File:
            guard type == S_IFREG else { throw VPhoneCreateRunError.artifactMissing(url.path + " (not a regular file)") }
            let content = try sha256(fileAt: url)
            return (content.digest, content.size)
        case .fileMetadata:
            guard type == S_IFREG else { throw VPhoneCreateRunError.artifactMissing(url.path + " (not a regular file)") }
            return (sha256(Data(metadataLine("", info).utf8)), Int64(info.st_size))
        case .treeMetadata:
            guard type == S_IFDIR else { throw VPhoneCreateRunError.artifactMissing(url.path + " (not a directory)") }
            var lines: [String] = []
            var total: Int64 = 0
            try walk(url, relative: "", lines: &lines, total: &total)
            return (sha256(Data(lines.joined(separator: "\n").utf8)), total)
        }
    }

    private static func metadataLine(_ relative: String, _ info: stat) -> String {
        let mtime = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
        return "\(relative)\u{0}\(info.st_mode & S_IFMT)\u{0}\(info.st_size)\u{0}\(mtime)\u{0}\(info.st_ino)"
    }

    private static func walk(_ url: URL, relative: String, lines: inout [String], total: inout Int64) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
            let child = url.appendingPathComponent(name)
            let rel = relative.isEmpty ? name : relative + "/" + name
            var info = stat()
            guard lstat(child.path, &info) == 0 else { throw VPhoneCreateRunError.artifactMissing(child.path) }
            lines.append(metadataLine(rel, info))
            switch info.st_mode & S_IFMT {
            case S_IFDIR: try walk(child, relative: rel, lines: &lines, total: &total)
            case S_IFREG: total += Int64(info.st_size)
            default: break
            }
        }
    }

    static func directoryId(_ url: URL) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw VPhoneCreateRunError.identityMismatch("bundle directory is missing or not a directory: \(url.path)")
        }
        return "\(info.st_dev):\(info.st_ino)"
    }

    static func machineIdentifierDigest(_ bundleURL: URL) -> String? {
        guard let manifest = try? VPhoneVirtualMachineManifest.load(from: bundleURL.appendingPathComponent("config.plist")),
              !manifest.machineIdentifier.isEmpty
        else { return nil }
        return sha256(manifest.machineIdentifier)
    }
}
