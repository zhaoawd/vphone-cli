// PatchExperimentRecord.swift — Reproducible patch experiment record (C5).
//
// The record wraps the existing `PatchRunReport` (method results, requirement rules,
// byte records) and `FirmwareTransaction.Journal` (staging/commit state) with the
// conditions needed to reproduce a run: source state, tool identity, firmware
// builds, effective options and input digests. The JSON file is the only structured
// source; the text summary and comparisons are derived from the decoded record.

import CryptoKit
import Darwin
import Foundation

// MARK: - Run Trace

/// Pipeline stage reached by the most recent run.
public enum FirmwareRunStage: String, Codable, Sendable, Equatable {
    case notStarted, preflight, prepare, stageInputs, patch, validateOutput, commit, finished
}

/// Progress captured while `FirmwarePipeline.patchAllStructured` runs. It is shared with
/// the staged pipeline so completed component reports survive a thrown error.
public final class FirmwareRunTrace {
    public internal(set) var stage: FirmwareRunStage = .notStarted
    public internal(set) var component: String?
    public internal(set) var gates: PatchGateSnapshot?
    public internal(set) var plannedComponents: [String] = []
    public internal(set) var processedComponents: [String] = []
    public internal(set) var componentReports: [ComponentReport] = []
    var transaction: FirmwareTransaction?

    public init() {}

    func record(_ component: String, _ reports: [ComponentReport]) {
        processedComponents.append(component)
        componentReports.append(contentsOf: reports)
    }
}

// MARK: - Explicit Null Encoding

/// Encodes nil as JSON `null` instead of omitting the key, and requires the key on decode.
@propertyWrapper
struct Nullable<Value: Codable & Equatable>: Codable, Equatable {
    var wrappedValue: Value?
    init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = try container.decodeNil() ? nil : try container.decode(Value.self)
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue { try container.encode(wrappedValue) } else { try container.encodeNil() }
    }
}

// MARK: - Record

public struct PatchExperimentRecord: Codable, Equatable {
    public static let schemaName = "vphone.patch-experiment-record"
    public static let currentSchemaVersion = 1
    /// Tree digest produced by `FirmwareTransaction.digest` (names, node kinds, contents).
    static let treeDigestAlgorithm = "vphone-tree-sha256-v1"

    public enum Status: String, Codable, Sendable { case running, succeeded, failed, cancelled }

    /// A value that may be unknown. Exactly one of `value` / `reason` is non-null.
    struct Known: Codable, Equatable {
        @Nullable var value: String?
        @Nullable var reason: String?
        static func known(_ value: String) -> Known { Known(value: value, reason: nil) }
        static func unknown(_ reason: String) -> Known { Known(value: nil, reason: reason) }
    }

    struct FailedStage: Codable, Equatable {
        /// A `FirmwareRunStage` raw value, or `record` for record-level integrity checks.
        var stage: String
        @Nullable var component: String?
    }

    struct SourceChange: Codable, Equatable {
        /// Path relative to the source root (submodule contents are prefixed by the submodule path).
        var path: String
        /// `git status --porcelain=v1` XY code, trimmed (`M`, `A`, `D`, `??`, `R`, ...).
        var state: String
        @Nullable var sha256: String?
        @Nullable var reason: String?
    }

    struct Submodule: Codable, Equatable {
        var path: String
        var commit: String
        /// `git submodule status` prefix: `clean`, `+` (different commit), `-` (not initialized), `U`.
        var state: String
    }

    struct Source: Codable, Equatable {
        /// `clean`, `dirty` or `unavailable`.
        var status: String
        @Nullable var reason: String?
        @Nullable var commit: String?
        /// Pathspec used for the status scan.
        var scope: [String]
        var changes: [SourceChange]
        var submodules: [Submodule]
    }

    struct Tool: Codable, Equatable {
        var buildCommit: Known
        var executableSHA256: Known
        var swiftCompiler: Known
        var hostOS: Known
        var packageResolvedSHA256: Known
        var buildDependenciesSHA256: Known
        var python: Known
        var sealTool: Known
        var source: Source
    }

    struct Build: Codable, Equatable {
        var manifest: String
        var productVersion: Known
        var buildVersion: Known
    }

    struct Firmware: Codable, Equatable {
        var iPhone: Build
        var cloudOS: Build
        var origin: Known
    }

    /// Every effective option, including values left at their defaults.
    struct Options: Codable, Equatable {
        var variant: String
        var forceExcGuard: Bool
        var frida: Bool
        var noBinpack: Bool
        var noVphoned: Bool
        /// Requested ablation values, trimmed, de-duplicated and sorted.
        var ablate: [String]
        var allowAblationOutput: Bool

        var isDryRun: Bool { !ablate.isEmpty && !allowAblationOutput }
    }

    struct FileDigest: Codable, Equatable {
        /// Path relative to the VM directory.
        var path: String
        var components: [String]
        var algorithm: String
        @Nullable var sizeBytes: Int?
        @Nullable var digest: String?
        @Nullable var reason: String?
    }

    struct Artifacts: Codable, Equatable {
        /// `available`, `unavailable` or `pending` (a running record's outputs).
        var availability: String
        @Nullable var reason: String?
        var files: [FileDigest]
        var roots: [FileDigest]

        static func unavailable(_ reason: String) -> Artifacts {
            Artifacts(availability: "unavailable", reason: reason, files: [], roots: [])
        }
    }

    struct Conditions: Codable, Equatable {
        var tool: Tool
        var firmware: Firmware
        var options: Options
        var inputs: Artifacts
    }

    struct Patch: Codable, Equatable {
        /// The existing run report; partial when the run stopped after gates were evaluated.
        @Nullable var report: PatchRunReport?
        @Nullable var reason: String?
        @Nullable var reportSHA256: String?
        /// `report.failedRequired`, kept for readers; validated against the report on load.
        var failedRequired: [String]
        var plannedComponents: [String]
        var processedComponents: [String]
        var notRunComponents: [String]
    }

    struct Transaction: Codable, Equatable {
        /// `committed`, `uncommitted` or `none`.
        var state: String
        @Nullable var reason: String?
        /// Location relative to the VM directory when the record was written.
        @Nullable var location: String?
        @Nullable var journal: FirmwareTransaction.Journal?
    }

    /// Run identity and absolute paths; never part of the condition digest.
    struct RunContext: Codable, Equatable {
        var vmDirectory: String
        @Nullable var executable: String?
        @Nullable var sourceRoot: String?
        var recordPath: String
    }

    var schema: String
    var schemaVersion: Int
    var runID: String
    var startedAt: String
    @Nullable var finishedAt: String?
    public internal(set) var status: Status
    @Nullable var failedStage: FailedStage?
    @Nullable var error: String?
    var conditions: Conditions
    var conditionDigest: String
    var patch: Patch
    var transaction: Transaction
    var outputs: Artifacts
    var run: RunContext
}

// MARK: - Errors

public struct PatchExperimentRecordError: Error, LocalizedError, CustomStringConvertible {
    public let message: String
    public var errorDescription: String? { message }
    public var description: String { message }
}

// MARK: - Canonical JSON and Validation

extension PatchExperimentRecord {
    static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(of conditions: Conditions) throws -> String {
        sha256(try canonicalData(conditions))
    }

    /// Pretty-printed with sorted keys; the key order is fixed for a given schema.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self) + Data("\n".utf8)
    }

    public static func load(from url: URL) throws -> PatchExperimentRecord {
        try decode(try Data(contentsOf: url))
    }

    public static func decode(_ data: Data) throws -> PatchExperimentRecord {
        struct Header: Decodable { let schema: String?; let schemaVersion: Int? }
        let header: Header
        do { header = try JSONDecoder().decode(Header.self, from: data) } catch {
            throw PatchExperimentRecordError(message: "Record is not valid JSON: \(error)")
        }
        guard header.schema == schemaName, header.schemaVersion == currentSchemaVersion else {
            throw PatchExperimentRecordError(message:
                "Unsupported record schema \(header.schema ?? "null") version \(header.schemaVersion.map(String.init) ?? "null")")
        }
        let record: PatchExperimentRecord
        do { record = try JSONDecoder().decode(PatchExperimentRecord.self, from: data) } catch {
            throw PatchExperimentRecordError(message: "Record does not match schema \(currentSchemaVersion): \(error)")
        }
        try record.validate()
        return record
    }

    /// Structural and semantic checks shared by write and load.
    func validate() throws {
        func fail(_ message: String) -> PatchExperimentRecordError { PatchExperimentRecordError(message: "Invalid record: \(message)") }
        guard schema == Self.schemaName, schemaVersion == Self.currentSchemaVersion else { throw fail("schema") }
        guard UUID(uuidString: runID) != nil else { throw fail("runID") }
        guard try Self.digest(of: conditions) == conditionDigest else { throw fail("conditionDigest does not match conditions") }

        let tool = conditions.tool
        let firmware = conditions.firmware
        let known = [tool.buildCommit, tool.executableSHA256, tool.swiftCompiler, tool.hostOS, tool.packageResolvedSHA256,
                     tool.buildDependenciesSHA256, tool.python, tool.sealTool, firmware.iPhone.productVersion,
                     firmware.iPhone.buildVersion, firmware.cloudOS.productVersion, firmware.cloudOS.buildVersion, firmware.origin]
        guard known.allSatisfy({ ($0.value == nil) != ($0.reason == nil) }) else { throw fail("unknown values need exactly one of value/reason") }
        guard ["clean", "dirty", "unavailable"].contains(tool.source.status),
              (tool.source.status == "unavailable") == (tool.source.commit == nil),
              (tool.source.status == "clean") == tool.source.changes.isEmpty || tool.source.status == "unavailable" else {
            throw fail("source status")
        }
        for artifacts in [conditions.inputs, outputs] {
            guard ["available", "unavailable", "pending"].contains(artifacts.availability),
                  (artifacts.availability == "available") == (artifacts.reason == nil) else { throw fail("artifact availability") }
            for list in [artifacts.files, artifacts.roots] {
                guard Set(list.map(\.path)).count == list.count else { throw fail("duplicate artifact path") }
                guard list.allSatisfy({ ($0.digest == nil) != ($0.reason == nil) }) else { throw fail("artifact digest/reason") }
            }
        }
        guard FirmwarePipeline.Variant(rawValue: conditions.options.variant) != nil else { throw fail("variant") }

        let failedRequired = patch.report?.failedRequired.map(\.description) ?? []
        guard patch.failedRequired == failedRequired else { throw fail("failedRequired does not match report") }
        if let report = patch.report {
            guard patch.reportSHA256 == Self.sha256(try Self.canonicalData(report)) else { throw fail("reportSHA256") }
        } else {
            guard patch.reason != nil, patch.reportSHA256 == nil else { throw fail("missing report needs a reason") }
        }

        let phase = transaction.journal?.phase
        switch transaction.state {
        case "committed": guard phase == .committed else { throw fail("committed transaction without committed journal") }
        case "uncommitted": guard let phase, phase != .committed else { throw fail("uncommitted transaction journal") }
        case "none": guard transaction.journal == nil, transaction.reason != nil else { throw fail("transaction none") }
        default: throw fail("transaction state")
        }
        if let failedStage {
            guard FirmwareRunStage(rawValue: failedStage.stage) != nil || failedStage.stage == "record" else { throw fail("failedStage") }
        }

        switch status {
        case .running:
            guard finishedAt == nil, failedStage == nil, outputs.availability == "pending" else { throw fail("running record") }
        case .succeeded:
            guard finishedAt != nil, failedStage == nil, error == nil, patch.report != nil, failedRequired.isEmpty,
                  transaction.state == "committed" || (transaction.state == "none" && conditions.options.isDryRun) else {
                throw fail("succeeded record must have a committed transaction or be a dry run without failures")
            }
        case .failed, .cancelled:
            guard finishedAt != nil, failedStage != nil else { throw fail("\(status.rawValue) record needs failedStage") }
        }
        if outputs.availability == "available" {
            guard status == .succeeded, transaction.state == "committed" else {
                throw fail("outputs can only be available for a committed, succeeded run")
            }
        }
        guard conditions.inputs.availability != "pending" else { throw fail("inputs cannot be pending") }
    }

    /// Replace a path's extension with `.summary.txt` (appends when there is none).
    public static func summaryURL(for recordURL: URL) -> URL {
        let base = recordURL.pathExtension.isEmpty ? recordURL : recordURL.deletingPathExtension()
        return base.appendingPathExtension("summary.txt")
    }
}

// MARK: - Durable Write

extension PatchExperimentRecord {
    public enum WriteStep: String, Sendable { case create, write, fsync, rename, syncDirectory }

    /// Temporary file, fsync, rename, directory fsync. On failure before the rename the
    /// destination keeps its previous content (a `running` record is never complete).
    /// On failure after the rename the new file is removed, so no record that looks
    /// complete remains without durable publication.
    static func writeDurably(_ data: Data, to url: URL, inject: (WriteStep) throws -> Void) throws {
        func posix() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        try inject(.create)
        var fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw posix() }
        var renamed = false
        do {
            try inject(.write)
            try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 { if errno == EINTR { continue }; throw posix() }
                    offset += written
                }
            }
            try inject(.fsync)
            guard fsync(fd) == 0 else { throw posix() }
            close(fd); fd = -1
            try inject(.rename)
            guard rename(temporary.path, url.path) == 0 else { throw posix() }
            renamed = true
            try inject(.syncDirectory)
            let dirFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard dirFD >= 0 else { throw posix() }
            defer { close(dirFD) }
            guard fsync(dirFD) == 0 else { throw posix() }
        } catch {
            if fd >= 0 { close(fd) }
            unlink(renamed ? url.path : temporary.path)
            throw error
        }
    }
}

// MARK: - Summary

extension PatchExperimentRecord {
    /// Human-readable summary rendered only from record fields.
    public func summary() -> String {
        func show(_ known: Known) -> String { known.value ?? "unknown (\(known.reason ?? ""))" }
        func artifactLines(_ title: String, _ artifacts: Artifacts) -> [String] {
            var lines = ["\(title): \(artifacts.availability)" + (artifacts.reason.map { " — \($0)" } ?? "")]
            for entry in artifacts.roots + artifacts.files {
                let size = entry.sizeBytes.map { " \($0) bytes" } ?? ""
                lines.append("  \(entry.path) [\(entry.components.joined(separator: ","))]"
                    + " \(entry.digest.map { "\(entry.algorithm)=\($0)" } ?? "unavailable (\(entry.reason ?? ""))")\(size)")
            }
            return lines
        }
        let tool = conditions.tool
        let options = conditions.options
        var lines = [
            "Patch experiment record (schema \(schemaVersion))",
            "run:        \(runID)",
            "started:    \(startedAt)",
            "finished:   \(finishedAt ?? "not finished")",
            "status:     \(status.rawValue)" + (failedStage.map { " at stage \($0.stage)" + ($0.component.map { " (\($0))" } ?? "") } ?? ""),
        ]
        if let error { lines.append("error:      \(error)") }
        lines.append("condition digest: \(conditionDigest)")
        lines.append("")
        lines.append("source:     \(tool.source.status)" + (tool.source.commit.map { " commit \($0)" } ?? "")
            + (tool.source.reason.map { " — \($0)" } ?? "") + " (scope: \(tool.source.scope.joined(separator: " ")))")
        for change in tool.source.changes {
            lines.append("  \(change.state) \(change.path) " + (change.sha256.map { "sha256=\($0)" } ?? "unavailable (\(change.reason ?? ""))"))
        }
        for submodule in tool.source.submodules where submodule.state != "clean" {
            lines.append("  submodule \(submodule.path) \(submodule.state) \(submodule.commit)")
        }
        lines += [
            "build commit:      \(show(tool.buildCommit))",
            "executable sha256: \(show(tool.executableSHA256))",
            "swift compiler:    \(show(tool.swiftCompiler))",
            "host OS:           \(show(tool.hostOS))",
            "Package.resolved:  \(show(tool.packageResolvedSHA256))",
            "build deps record: \(show(tool.buildDependenciesSHA256))",
            "python:            \(show(tool.python))",
            "seal tool:         \(show(tool.sealTool))",
            "",
            "iPhone firmware:   \(show(conditions.firmware.iPhone.productVersion)) build \(show(conditions.firmware.iPhone.buildVersion)) (\(conditions.firmware.iPhone.manifest))",
            "cloudOS firmware:  \(show(conditions.firmware.cloudOS.productVersion)) build \(show(conditions.firmware.cloudOS.buildVersion)) (\(conditions.firmware.cloudOS.manifest))",
            "firmware origin:   \(show(conditions.firmware.origin))",
            "options:           variant=\(options.variant) forceExcGuard=\(options.forceExcGuard) frida=\(options.frida) "
                + "noBinpack=\(options.noBinpack) noVphoned=\(options.noVphoned) "
                + "ablate=[\(options.ablate.joined(separator: ","))] allowAblationOutput=\(options.allowAblationOutput)",
        ]
        lines += artifactLines("inputs", conditions.inputs)
        lines.append("")
        if let report = patch.report {
            var outcomes: [String: Int] = [:]
            for result in report.components.flatMap(\.results) { outcomes[result.outcome.rawValue, default: 0] += 1 }
            lines.append("gates:      \(report.gates.summary)")
            lines.append("method results: " + outcomes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                + "; byte records: \(report.allRecords.count); ablated steps: \(report.ablation.count)")
            lines.append("required failures: " + (patch.failedRequired.isEmpty ? "none" : patch.failedRequired.joined(separator: ", ")))
        } else {
            lines.append("patch report: unavailable (\(patch.reason ?? ""))")
        }
        lines.append("components processed: \(patch.processedComponents.joined(separator: ", "))")
        lines.append("components not run:   " + (patch.notRunComponents.isEmpty ? "none" : patch.notRunComponents.joined(separator: ", ")))
        lines.append("transaction: \(transaction.state)" + (transaction.journal.map { " id \($0.id) phase \($0.phase.rawValue)" } ?? "")
            + (transaction.location.map { " at \($0)" } ?? "") + (transaction.reason.map { " — \($0)" } ?? ""))
        lines += artifactLines("outputs", outputs)
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Comparison

public struct PatchExperimentComparison: Codable {
    public enum Result: String, Codable, Sendable { case same, different, undetermined }

    public struct Difference: Codable, Equatable, Sendable {
        public let path: String
        public let left: String
        public let right: String
    }

    public struct Aspect: Codable, Sendable {
        public let result: Result
        public let reason: String?
        public let differences: [Difference]
    }

    public struct Side: Codable, Sendable {
        public let runID: String
        public let status: String
        public let conditionDigest: String
    }

    public let left: Side
    public let right: Side
    public let conditions: Aspect
    public let patchResults: Aspect
    public let artifacts: Aspect
    /// Differences in fields excluded from all three results (run identity, times,
    /// absolute paths, error text and transaction identity).
    public let excluded: [Difference]

    static let renderLimit = 40

    public var allSame: Bool { [conditions, patchResults, artifacts].allSatisfy { $0.result == .same } }

    public func render() -> String {
        var lines = [
            "left:  \(left.runID) status=\(left.status) conditions=\(left.conditionDigest)",
            "right: \(right.runID) status=\(right.status) conditions=\(right.conditionDigest)",
        ]
        for (name, aspect) in [("conditions", conditions), ("patch results", patchResults), ("artifact digests", artifacts)] {
            lines.append("\(name): \(aspect.result.rawValue)" + (aspect.reason.map { " — \($0)" } ?? ""))
            for difference in aspect.differences.prefix(Self.renderLimit) {
                lines.append("  \(difference.path): \(difference.left) -> \(difference.right)")
            }
            if aspect.differences.count > Self.renderLimit {
                lines.append("  ... \(aspect.differences.count - Self.renderLimit) more (use --json for the full list)")
            }
        }
        lines.append("excluded fields that differ: " + (excluded.isEmpty ? "none" : excluded.map(\.path).joined(separator: ", ")))
        return lines.joined(separator: "\n") + "\n"
    }
}

extension PatchExperimentRecord {
    public static func compare(_ left: PatchExperimentRecord, _ right: PatchExperimentRecord) throws -> PatchExperimentComparison {
        func differences<T: Encodable>(_ prefix: String, _ a: T, _ b: T) throws -> [PatchExperimentComparison.Difference] {
            var result: [PatchExperimentComparison.Difference] = []
            let lhs = try JSONSerialization.jsonObject(with: canonicalData(a), options: [.fragmentsAllowed])
            let rhs = try JSONSerialization.jsonObject(with: canonicalData(b), options: [.fragmentsAllowed])
            diff(lhs, rhs, path: prefix, into: &result)
            return result
        }
        func aspect(_ diffs: [PatchExperimentComparison.Difference]) -> PatchExperimentComparison.Aspect {
            .init(result: diffs.isEmpty ? .same : .different, reason: nil, differences: diffs)
        }

        let conditions = aspect(try differences("conditions", left.conditions, right.conditions))

        struct PatchOutcome: Encodable { let status: Status; let failedStage: FailedStage?; let patch: Patch }
        let patchDiffs = try differences("",
            PatchOutcome(status: left.status, failedStage: left.failedStage, patch: left.patch),
            PatchOutcome(status: right.status, failedStage: right.failedStage, patch: right.patch))
        let patchResults: PatchExperimentComparison.Aspect
        if left.status == .running || right.status == .running {
            patchResults = .init(result: .undetermined, reason: "a run has not finished", differences: patchDiffs)
        } else {
            patchResults = aspect(patchDiffs)
        }

        let artifacts: PatchExperimentComparison.Aspect
        let outputDiffs = try differences("outputs", left.outputs, right.outputs)
        let incomplete = [left.outputs, right.outputs].contains { outputs in
            outputs.availability != "available" || (outputs.files + outputs.roots).contains { $0.digest == nil }
        }
        if incomplete {
            artifacts = .init(result: .undetermined,
                              reason: "outputs left=\(left.outputs.availability) right=\(right.outputs.availability); "
                                + "digests are compared only when both runs committed complete outputs",
                              differences: outputDiffs)
        } else {
            artifacts = aspect(outputDiffs)
        }

        struct Excluded: Encodable {
            let runID: String; let startedAt: String; let finishedAt: String?; let error: String?
            let transaction: Transaction; let run: RunContext
        }
        let excluded = try differences("",
            Excluded(runID: left.runID, startedAt: left.startedAt, finishedAt: left.finishedAt, error: left.error,
                     transaction: left.transaction, run: left.run),
            Excluded(runID: right.runID, startedAt: right.startedAt, finishedAt: right.finishedAt, error: right.error,
                     transaction: right.transaction, run: right.run))

        return PatchExperimentComparison(
            left: .init(runID: left.runID, status: left.status.rawValue, conditionDigest: left.conditionDigest),
            right: .init(runID: right.runID, status: right.status.rawValue, conditionDigest: right.conditionDigest),
            conditions: conditions, patchResults: patchResults, artifacts: artifacts, excluded: excluded)
    }

    /// Recursive JSON diff. Arrays whose elements are objects with unique `path` strings
    /// are matched by path; other arrays of containers by index. Arrays of scalars
    /// (ablation ids, component names) are compared as one value.
    static func diff(_ a: Any?, _ b: Any?, path: String, into result: inout [PatchExperimentComparison.Difference]) {
        func render(_ value: Any?) -> String {
            guard let value else { return "<absent>" }
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) else {
                return String(describing: value)
            }
            let text = String(decoding: data, as: UTF8.self)
            return text.count > 160 ? String(text.prefix(157)) + "..." : text
        }
        func join(_ key: String) -> String { path.isEmpty ? key : "\(path).\(key)" }
        func keyed(_ array: [Any]) -> [String: Any]? {
            var map: [String: Any] = [:]
            for element in array {
                guard let object = element as? [String: Any], let key = object["path"] as? String, map[key] == nil else { return nil }
                map[key] = object
            }
            return map
        }

        if let lhs = a as? [String: Any], let rhs = b as? [String: Any] {
            for key in Set(lhs.keys).union(rhs.keys).sorted() { diff(lhs[key], rhs[key], path: join(key), into: &result) }
        } else if let lhs = a as? [Any], let rhs = b as? [Any],
                  !(lhs + rhs).allSatisfy({ !($0 is [String: Any]) && !($0 is [Any]) }) {
            if let left = keyed(lhs), let right = keyed(rhs), !(left.isEmpty && right.isEmpty) {
                for key in Set(left.keys).union(right.keys).sorted() {
                    diff(left[key], right[key], path: "\(path)[\(key)]", into: &result)
                }
            } else {
                for index in 0..<max(lhs.count, rhs.count) {
                    diff(index < lhs.count ? lhs[index] : nil, index < rhs.count ? rhs[index] : nil,
                         path: "\(path)[\(index)]", into: &result)
                }
            }
        } else if render(a) != render(b) {
            result.append(.init(path: path, left: render(a), right: render(b)))
        }
    }
}
