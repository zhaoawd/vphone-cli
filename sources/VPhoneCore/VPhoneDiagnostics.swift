import Foundation

// MARK: - Category, severity, code

/// Which part of the system a finding is about. The raw values are part of the
/// `doctor --json` schema and must not change.
public enum VPhoneDiagnosticCategory: String, Codable, CaseIterable, Sendable {
    /// Host OS, virtualization support, SIP/research guests, signing, disk space.
    case environment
    /// Python runtime, bundled resources, external host tools.
    case dependency
    /// Locks, running processes, attached images, mount residue.
    case occupancy
    /// Library and bundle contents supplied to an operation (names, manifests, files, checkpoint files).
    case input
    /// Boot-chain firmware patching and CFW installation state.
    case patch
    /// DFU restore state recorded in the bundle.
    case restore
    /// Host control channel and guest daemon of a running VM.
    case guestRuntime = "guest_runtime"
    /// A check itself could not run.
    case `internal`
}

/// Ordered by how much it should worry a user: `unknown` ranks above
/// `warning` because a check that could not run may hide an error.
public enum VPhoneDiagnosticSeverity: String, Codable, CaseIterable, Sendable, Comparable {
    case ok
    case warning
    case unknown
    case error

    var rank: Int {
        switch self {
        case .ok: 0
        case .warning: 1
        case .unknown: 2
        case .error: 3
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    /// `doctor` exit status for a report whose worst finding has this severity.
    /// 1 and 64 remain ArgumentParser's failure and usage codes.
    public var exitCode: Int32 {
        switch self {
        case .ok: 0
        case .warning: 3
        case .unknown: 4
        case .error: 5
        }
    }
}

/// Stable finding codes. Adding a code is compatible; renaming or removing one is not.
public enum VPhoneDiagnosticCode: String, Codable, CaseIterable, Sendable {
    // environment
    case macosVersion = "macos_version"
    case hypervisorSupport = "hypervisor_support"
    case nestedVirtualization = "nested_virtualization"
    case sipStatus = "sip_status"
    case researchGuests = "research_guests"
    case signingEntitlements = "signing_entitlements"
    case diskSpace = "disk_space"
    // dependency
    case pythonRuntime = "python_runtime"
    case runtimeResources = "runtime_resources"
    case hostTools = "host_tools"
    // input
    case libraryRoot = "library_root"
    case bundleUnreadable = "bundle_unreadable"
    case vmNotFound = "vm_not_found"
    case vmManifestInvalid = "vm_manifest_invalid"
    case vmFiles = "vm_files"
    case createCheckpointAbsent = "create_checkpoint_absent"
    case createCheckpointInvalid = "create_checkpoint_invalid"
    // create status (category follows the stage, see VPhoneDiagnostics.category(for:))
    case createSucceeded = "create_succeeded"
    case createIncomplete = "create_incomplete"
    case createInterrupted = "create_interrupted"
    case createStageFailed = "create_stage_failed"
    case createCancelled = "create_cancelled"
    case createCompletedUnverified = "create_completed_unverified"
    case createRecoveryRequired = "create_recovery_required"
    // patch
    case firmwareTransactionPending = "firmware_transaction_pending"
    case firmwareHistory = "firmware_history"
    case patchRecord = "patch_record"
    case patchRecordFailed = "patch_record_failed"
    case patchRecordRunning = "patch_record_running"
    case patchRecordInvalid = "patch_record_invalid"
    // restore
    case restoreState = "restore_state"
    // occupancy
    case libraryLock = "library_lock"
    case runningVMProcesses = "running_vm_processes"
    case vmRunning = "vm_running"
    case vmIdle = "vm_idle"
    case vmOperationInProgress = "vm_operation_in_progress"
    case vmLockHolderUnknown = "vm_lock_holder_unknown"
    case vmBootProcessWithoutLock = "vm_boot_process_without_lock"
    case createRunInProgress = "create_run_in_progress"
    case attachedImages = "attached_images"
    case cfwMountResidue = "cfw_mount_residue"
    // guest runtime
    case guestNotRunning = "guest_not_running"
    case guestConnected = "guest_connected"
    case guestDisconnected = "guest_disconnected"
    case hostControlSocketMissing = "host_control_socket_missing"
    case hostControlUnreachable = "host_control_unreachable"
    case hostControlCapabilitiesUnavailable = "host_control_capabilities_unavailable"
    // internal
    case checkFailed = "check_failed"
}

// MARK: - Finding

public struct VPhoneDiagnosticFinding: Equatable, Sendable, Encodable {
    public var category: VPhoneDiagnosticCategory
    public var code: VPhoneDiagnosticCode
    public var severity: VPhoneDiagnosticSeverity
    public var message: String
    /// Observed values. Keys are snake_case; values are already-rendered strings.
    public var evidence: [String: String]
    /// A command or step for the user. Never executed by `doctor`.
    public var suggestedAction: String?
    /// The VM a finding belongs to; nil for host findings.
    public var vm: String?

    public init(
        _ category: VPhoneDiagnosticCategory, _ code: VPhoneDiagnosticCode, _ severity: VPhoneDiagnosticSeverity,
        _ message: String, evidence: [String: String] = [:], action: String? = nil, vm: String? = nil
    ) {
        self.category = category
        self.code = code
        self.severity = severity
        self.message = message
        self.evidence = evidence
        suggestedAction = action
        self.vm = vm
    }

    enum CodingKeys: String, CodingKey {
        case category, code, severity, message, evidence
        case suggestedAction = "suggested_action"
        case vm
    }

    /// Every key is always present (null when absent) so the schema is fixed.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(category, forKey: .category)
        try container.encode(code, forKey: .code)
        try container.encode(severity, forKey: .severity)
        try container.encode(message, forKey: .message)
        try container.encode(evidence, forKey: .evidence)
        try container.encode(suggestedAction, forKey: .suggestedAction)
        try container.encode(vm, forKey: .vm)
    }
}

// MARK: - Redaction

/// Applied to every message, evidence value and suggested action before a
/// report is rendered. Checks are written not to collect secrets; this is the
/// second line of defence for text that comes from files or subprocesses.
public struct VPhoneDiagnosticRedactor: Sendable {
    public static let placeholder = "<redacted>"
    let homePath: String

    public init(homePath: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        self.homePath = homePath.hasSuffix("/") ? String(homePath.dropLast()) : homePath
    }

    private static let sensitiveKey = try! NSRegularExpression(
        pattern: "(password|passwd|token|secret|askpass|api[_-]?key|authorization|cookie|credential)",
        options: [.caseInsensitive])
    private static let url = try! NSRegularExpression(
        pattern: "([A-Za-z][A-Za-z0-9+.-]*://)([^\\s/?#@]*@)?([^\\s?#]*)(\\?[^\\s#]*)?(#\\S*)?")
    private static let flagValue = try! NSRegularExpression(
        pattern: "(--?[A-Za-z0-9_-]*(?:password|passwd|token|secret|api-key)[A-Za-z0-9_-]*)(=|\\s+)(\\S+)",
        options: [.caseInsensitive])
    private static let assignment = try! NSRegularExpression(
        pattern: "\\b((?:[A-Za-z0-9_]*_)?(?:password|passwd|token|secret|api[_-]?key))(\\s*[=:]\\s*)(\\S+)",
        options: [.caseInsensitive])
    private static let bearer = try! NSRegularExpression(
        pattern: "\\b(bearer|basic)\\s+[A-Za-z0-9._~+/=-]+", options: [.caseInsensitive])

    public static func isSensitiveKey(_ key: String) -> Bool {
        sensitiveKey.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
    }

    public func redact(_ text: String) -> String {
        var result = Self.replaceURLs(in: text)
        result = Self.replace(Self.flagValue, in: result) { groups in groups[1] + groups[2] + Self.placeholder }
        result = Self.replace(Self.assignment, in: result) { groups in groups[1] + groups[2] + Self.placeholder }
        result = Self.replace(Self.bearer, in: result) { groups in groups[1] + " " + Self.placeholder }
        if !homePath.isEmpty, homePath != "/",
           let home = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: homePath) + "(?=/|$|[\\s\"',;:)])") {
            result = Self.replace(home, in: result) { _ in "~" }
        }
        return result
    }

    public func redact(_ finding: VPhoneDiagnosticFinding) -> VPhoneDiagnosticFinding {
        var copy = finding
        copy.message = redact(finding.message)
        copy.suggestedAction = finding.suggestedAction.map(redact)
        copy.evidence = Dictionary(uniqueKeysWithValues: finding.evidence.map { key, value in
            (key, Self.isSensitiveKey(key) ? Self.placeholder : redact(value))
        })
        return copy
    }

    /// URLs keep scheme, host and path; user info, query and fragment are replaced.
    private static func replaceURLs(in text: String) -> String {
        replace(url, in: text) { groups in
            var rendered = groups[1] + (groups[2].isEmpty ? "" : placeholder + "@") + groups[3]
            if !groups[4].isEmpty { rendered += "?" + placeholder }
            if !groups[5].isEmpty { rendered += "#" + placeholder }
            return rendered
        }
    }

    private static func replace(
        _ expression: NSRegularExpression, in text: String, _ render: ([String]) -> String
    ) -> String {
        let source = text as NSString
        var output = ""
        var cursor = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            output += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
            output += render(groups)
            cursor = match.range.location + match.range.length
        }
        output += source.substring(from: cursor)
        return output
    }
}

// MARK: - Report

public struct VPhoneDiagnosticReport: Encodable, Sendable {
    public static let schema = "vphone.diagnostics"
    public static let schemaVersion = 1

    public let generatedAt: Date
    /// nil for a host-only report.
    public let vm: String?
    public let libraryRoot: String
    public let toolCommit: String?
    /// Redacted, grouped by category in `VPhoneDiagnosticCategory.allCases` order.
    public let findings: [VPhoneDiagnosticFinding]

    public init(
        vm: String?, libraryRoot: URL, toolCommit: String?, findings: [VPhoneDiagnosticFinding],
        redactor: VPhoneDiagnosticRedactor = VPhoneDiagnosticRedactor(), generatedAt: Date = Date()
    ) {
        self.generatedAt = generatedAt
        self.vm = vm
        self.libraryRoot = redactor.redact(libraryRoot.path)
        self.toolCommit = toolCommit
        let order = Dictionary(uniqueKeysWithValues: VPhoneDiagnosticCategory.allCases.enumerated().map { ($1, $0) })
        self.findings = findings.enumerated()
            .sorted { (order[$0.element.category]!, $0.offset) < (order[$1.element.category]!, $1.offset) }
            .map { redactor.redact($0.element) }
    }

    public var worstSeverity: VPhoneDiagnosticSeverity { findings.map(\.severity).max() ?? .ok }
    public var exitCode: Int32 { worstSeverity.exitCode }

    public var counts: [VPhoneDiagnosticSeverity: Int] {
        var counts = Dictionary(uniqueKeysWithValues: VPhoneDiagnosticSeverity.allCases.map { ($0, 0) })
        for finding in findings { counts[finding.severity, default: 0] += 1 }
        return counts
    }

    enum CodingKeys: String, CodingKey {
        case schema, schemaVersion = "schema_version", generatedAt = "generated_at", readOnly = "read_only"
        case scope, toolCommit = "tool_commit", summary, findings
    }

    enum ScopeKeys: String, CodingKey { case vm, libraryRoot = "library_root" }
    enum SummaryKeys: String, CodingKey { case worstSeverity = "worst_severity", exitCode = "exit_code", counts }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schema, forKey: .schema)
        try container.encode(Self.schemaVersion, forKey: .schemaVersion)
        try container.encode(ISO8601DateFormatter().string(from: generatedAt), forKey: .generatedAt)
        try container.encode(true, forKey: .readOnly)
        var scope = container.nestedContainer(keyedBy: ScopeKeys.self, forKey: .scope)
        try scope.encode(vm, forKey: .vm)
        try scope.encode(libraryRoot, forKey: .libraryRoot)
        try container.encode(toolCommit, forKey: .toolCommit)
        var summary = container.nestedContainer(keyedBy: SummaryKeys.self, forKey: .summary)
        try summary.encode(worstSeverity, forKey: .worstSeverity)
        try summary.encode(exitCode, forKey: .exitCode)
        try summary.encode(Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, $0.value) }), forKey: .counts)
        try container.encode(findings, forKey: .findings)
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public var text: String {
        var lines = [
            "vphone-cli doctor (read-only) — scope: " + (vm.map { "vm \($0)" } ?? "host"),
            "library: \(libraryRoot)",
        ]
        var lastCategory: VPhoneDiagnosticCategory?
        for finding in findings {
            if finding.category != lastCategory {
                lines.append("")
                lines.append("[\(finding.category.rawValue)]")
                lastCategory = finding.category
            }
            let label = finding.severity.rawValue.uppercased().padding(toLength: 7, withPad: " ", startingAt: 0)
            lines.append("  \(label) \(finding.code.rawValue)" + (finding.vm.map { " (\($0))" } ?? "") + ": \(finding.message)")
            for key in finding.evidence.keys.sorted() {
                lines.append("            \(key): \(finding.evidence[key]!)")
            }
            if let action = finding.suggestedAction {
                lines.append("            suggested (not run): \(action)")
            }
        }
        let counts = counts
        lines.append("")
        lines.append("summary: worst=\(worstSeverity.rawValue) exit=\(exitCode) "
            + VPhoneDiagnosticSeverity.allCases.map { "\($0.rawValue)=\(counts[$0] ?? 0)" }.joined(separator: " "))
        return lines.joined(separator: "\n")
    }
}
