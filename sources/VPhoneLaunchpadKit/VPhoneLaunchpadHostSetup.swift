import Foundation
import Observation

// MARK: - Diagnostics report

/// `vphone-cli doctor --json`, schema `vphone.diagnostics` version 1
/// (`VPhoneDiagnosticReport` in VPhoneCore). Decoded field by field so the
/// panel shows what the CLI reported, including severities or categories a
/// newer CLI adds.
public struct VPhoneLaunchpadDiagnosticReport: Decodable, Equatable, Sendable {
    public static let schemaName = "vphone.diagnostics"
    public static let schemaVersion = 1

    public struct Scope: Decodable, Equatable, Sendable {
        public let vm: String?
        public let libraryRoot: String

        enum CodingKeys: String, CodingKey {
            case vm
            case libraryRoot = "library_root"
        }
    }

    public struct Summary: Decodable, Equatable, Sendable {
        public let worstSeverity: String
        public let exitCode: Int32
        public let counts: [String: Int]

        enum CodingKeys: String, CodingKey {
            case worstSeverity = "worst_severity"
            case exitCode = "exit_code"
            case counts
        }
    }

    public struct Finding: Decodable, Equatable, Sendable {
        public let category: String
        public let code: String
        public let severity: String
        public let message: String
        public let evidence: [String: String]
        public let suggestedAction: String?
        public let vm: String?

        enum CodingKeys: String, CodingKey {
            case category, code, severity, message, evidence, vm
            case suggestedAction = "suggested_action"
        }
    }

    public let schema: String
    public let schemaVersion: Int
    public let generatedAt: String
    public let readOnly: Bool
    public let scope: Scope
    public let toolCommit: String?
    public let summary: Summary
    public let findings: [Finding]

    enum CodingKeys: String, CodingKey {
        case schema, scope, summary, findings
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case readOnly = "read_only"
        case toolCommit = "tool_commit"
    }

    /// Decodes a report and checks it is the schema this panel reads.
    public static func decode(_ data: Data) throws -> Self {
        let report = try JSONDecoder().decode(Self.self, from: data)
        guard report.schema == schemaName, report.schemaVersion == schemaVersion else {
            throw VPhoneLaunchpadError("Unsupported doctor schema \(report.schema) version \(report.schemaVersion).")
        }
        guard report.readOnly else {
            throw VPhoneLaunchpadError("The doctor report is not marked read-only.")
        }
        return report
    }
}

// MARK: - Check rows

/// A finding's severity as the panel shows it. A value the panel does not
/// know is shown as `unknown`, the level doctor uses for a check that could
/// not run.
public enum VPhoneLaunchpadCheckSeverity: String, Sendable, CaseIterable {
    case ok
    case warning
    case unknown
    case error

    public init(doctorValue: String) {
        self = Self(rawValue: doctorValue) ?? .unknown
    }
}

/// One doctor finding as a Host Setup row.
public struct VPhoneLaunchpadHostCheckRow: Identifiable, Equatable, Sendable {
    public let id: Int
    public let category: String
    public let code: String
    public let severity: VPhoneLaunchpadCheckSeverity
    public let message: String
    /// Sorted by key.
    public let evidence: [(key: String, value: String)]
    /// Shown as text to copy; Launchpad never runs it.
    public let suggestedAction: String?
    public let vm: String?

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.category == rhs.category && lhs.code == rhs.code && lhs.severity == rhs.severity
            && lhs.message == rhs.message && lhs.suggestedAction == rhs.suggestedAction && lhs.vm == rhs.vm
            && lhs.evidence.map(\.key) == rhs.evidence.map(\.key) && lhs.evidence.map(\.value) == rhs.evidence.map(\.value)
    }
}

/// Rows of one doctor category, in report order.
public struct VPhoneLaunchpadHostCheckSection: Identifiable, Equatable, Sendable {
    public let category: String
    public let rows: [VPhoneLaunchpadHostCheckRow]

    public var id: String {
        category
    }
}

public extension VPhoneLaunchpadDiagnosticReport {
    var rows: [VPhoneLaunchpadHostCheckRow] {
        findings.enumerated().map { index, finding in
            VPhoneLaunchpadHostCheckRow(
                id: index,
                category: finding.category,
                code: finding.code,
                severity: VPhoneLaunchpadCheckSeverity(doctorValue: finding.severity),
                message: finding.message,
                evidence: finding.evidence.sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value) },
                suggestedAction: finding.suggestedAction,
                vm: finding.vm
            )
        }
    }

    /// Rows grouped by category. doctor already orders findings by
    /// category; a category keeps the position of its first finding.
    var sections: [VPhoneLaunchpadHostCheckSection] {
        var order: [String] = []
        var grouped: [String: [VPhoneLaunchpadHostCheckRow]] = [:]
        for row in rows {
            if grouped[row.category] == nil {
                order.append(row.category)
            }
            grouped[row.category, default: []].append(row)
        }
        return order.map { VPhoneLaunchpadHostCheckSection(category: $0, rows: grouped[$0]!) }
    }

    var worst: VPhoneLaunchpadCheckSeverity {
        VPhoneLaunchpadCheckSeverity(doctorValue: summary.worstSeverity)
    }

    func count(_ severity: VPhoneLaunchpadCheckSeverity) -> Int {
        rows.count(where: { $0.severity == severity })
    }
}

// MARK: - Helper status

/// `vphone-cli helper status`. Launchpad shows it and offers no
/// registration: helper registration is deferred (decision of 2026-09-30).
public struct VPhoneLaunchpadHelperStatus: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// The helper answered with this protocol version.
        case reachable(protocolVersion: String)
        /// The command failed; the reason is what `vphone-cli` printed.
        case unavailable(reason: String)
    }

    public let state: State
    /// The command's output as printed (stdout and stderr merged).
    public let output: String
    public let exitStatus: Int32

    public init(_ result: VPhoneLaunchpadCommandResult) {
        exitStatus = result.status
        output = result.lines.joined(separator: "\n")
        let prefix = "helper protocol: "
        if result.succeeded, let line = result.lines.last(where: { $0.hasPrefix(prefix) }) {
            state = .reachable(protocolVersion: String(line.dropFirst(prefix.count)))
        } else {
            state = .unavailable(reason: result.failureReason)
        }
    }

    public init(failure: String) {
        exitStatus = -1
        output = failure
        state = .unavailable(reason: failure)
    }
}

// MARK: - Host setup

/// The Host Setup panel's data: one `doctor --json` run and one
/// `helper status` run. They run when the panel opens and when the user asks
/// again, never on a timer (T26 design 5.2): doctor briefly probes the
/// library and VM locks.
@MainActor
@Observable
public final class VPhoneLaunchpadHostSetup {
    public enum DoctorState: Equatable, Sendable {
        case notRun
        case report(VPhoneLaunchpadDiagnosticReport, exitStatus: Int32)
        case failed(String)
    }

    /// doctor exit statuses that come with a report: all ok, worst warning,
    /// worst unknown, worst error.
    public nonisolated static let reportStatuses: Set<Int32> = [0, 3, 4, 5]

    public private(set) var doctor: DoctorState = .notRun
    public private(set) var helper: VPhoneLaunchpadHelperStatus?
    public private(set) var isChecking = false
    public private(set) var checkedAt: Date?

    public let libraryRoot: String
    private let commandLine: VPhoneLaunchpadCommandLine

    public init(commandLine: VPhoneLaunchpadCommandLine, libraryRoot: String) {
        self.commandLine = commandLine
        self.libraryRoot = libraryRoot
    }

    public var sections: [VPhoneLaunchpadHostCheckSection] {
        if case let .report(report, _) = doctor {
            return report.sections
        }
        return []
    }

    /// Runs doctor, then helper status. A second call while one runs returns
    /// at once.
    public func refresh() async {
        guard !isChecking else {
            return
        }
        isChecking = true
        defer {
            isChecking = false
            checkedAt = Date()
        }
        doctor = await runDoctor()
        helper = await runHelperStatus()
        let line: String = switch doctor {
        case let .report(report, status):
            "[launchpad] host setup: doctor exit \(status), \(report.findings.count) findings, worst \(report.summary.worstSeverity)"
        case let .failed(reason):
            "[launchpad] host setup: doctor failed: \(reason.split(separator: "\n").first ?? "")"
        case .notRun:
            "[launchpad] host setup: doctor not run"
        }
        let helperLine = switch helper?.state {
        case let .reachable(version)?: "reachable, protocol \(version)"
        case .unavailable?: "unavailable, exit \(helper!.exitStatus)"
        case nil: "not run"
        }
        FileHandle.standardOutput.write(Data("\(line); helper status \(helperLine)\n".utf8))
    }

    private func runDoctor() async -> DoctorState {
        guard let command = VPhoneLaunchpadReadOnlyCommand.doctor(libraryRoot: libraryRoot) else {
            return .failed("The library root is not an absolute path: \(libraryRoot)")
        }
        do {
            let result = try await commandLine.run(command)
            return Self.doctorState(result)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Maps a finished doctor run: a report for exit 0, 3, 4 or 5 with a
    /// decodable document; otherwise the reason `vphone-cli` printed.
    public nonisolated static func doctorState(_ result: VPhoneLaunchpadCommandResult) -> DoctorState {
        guard reportStatuses.contains(result.status) else {
            return .failed(result.failureReason)
        }
        guard let data = result.jsonData else {
            return .failed("doctor printed no JSON document (exit status \(result.status)).")
        }
        do {
            return .report(try VPhoneLaunchpadDiagnosticReport.decode(data), exitStatus: result.status)
        } catch let error as VPhoneLaunchpadError {
            return .failed(error.message)
        } catch {
            return .failed("doctor JSON could not be read: \(error)")
        }
    }

    private func runHelperStatus() async -> VPhoneLaunchpadHelperStatus {
        do {
            return VPhoneLaunchpadHelperStatus(try await commandLine.run(.helperStatus))
        } catch {
            return VPhoneLaunchpadHelperStatus(failure: error.localizedDescription)
        }
    }
}
