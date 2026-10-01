import Foundation

// MARK: - Read-only commands

/// The only `vphone-cli` commands the Host Setup and Core Bundle panels run
/// (T26 B5). Each one reads state and changes nothing: `doctor --json`,
/// `helper status` and `core-bundle verify --version`. A value exists only
/// through the factories below, so no panel can build `helper register`,
/// `helper install-bundle`, `core-bundle install` or any other command that
/// writes system directories; helper registration and production Core Bundle
/// installation stay deferred (decision of 2026-09-30).
public struct VPhoneLaunchpadReadOnlyCommand: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case doctor
        case helperStatus
        case coreBundleVerify
    }

    public let kind: Kind
    public let arguments: [String]

    private init(_ kind: Kind, _ arguments: [String]) {
        self.kind = kind
        self.arguments = arguments
    }

    /// Host diagnostics for one library, as JSON (schema `vphone.diagnostics`
    /// v1). nil unless `libraryRoot` is an absolute path.
    public static func doctor(libraryRoot: String) -> Self? {
        guard isAbsolutePath(libraryRoot) else {
            return nil
        }
        return Self(.doctor, ["doctor", "--json", "--library-root", libraryRoot])
    }

    /// Signing configuration and helper protocol; never registers.
    public static let helperStatus = Self(.helperStatus, ["helper", "status"])

    /// Receipt, ownership, signature and cdhash check of one installed
    /// version. nil unless `version` is a Core Bundle store name.
    public static func coreBundleVerify(version: String) -> Self? {
        guard VPhoneLaunchpadCoreBundleVersion.isStoreName(version) else {
            return nil
        }
        return Self(.coreBundleVerify, ["core-bundle", "verify", "--version", version])
    }

    /// doctor's exit status when its worst finding is a warning (0 ok,
    /// 3 warning, 4 unknown, 5 error).
    public static let doctorWarningStatus: Int32 = 3

    /// Exit statuses Recent Commands shows as a warning rather than a
    /// failure: doctor's 3. Every other non-zero status is a failure.
    public var warningStatuses: Set<Int32> {
        kind == .doctor ? [Self.doctorWarningStatus] : []
    }

    /// True only for the exact argument shapes the factories produce.
    public static func isAllowed(_ arguments: [String]) -> Bool {
        switch arguments.count {
        case 2:
            return arguments == helperStatus.arguments
        case 4:
            if arguments[0 ..< 3] == ["doctor", "--json", "--library-root"] {
                return doctor(libraryRoot: arguments[3]) != nil
            }
            if arguments[0 ..< 3] == ["core-bundle", "verify", "--version"] {
                return coreBundleVerify(version: arguments[3]) != nil
            }
            return false
        default:
            return false
        }
    }

    private static func isAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.contains("\0") && !value.contains("\n")
    }
}

// MARK: - Running

public extension VPhoneLaunchpadCommandLine {
    /// Runs one read-only command. The argument shape is checked again here,
    /// so a value built any other way is refused before a process starts.
    func run(_ command: VPhoneLaunchpadReadOnlyCommand) async throws -> VPhoneLaunchpadCommandResult {
        guard VPhoneLaunchpadReadOnlyCommand.isAllowed(command.arguments) else {
            throw VPhoneLaunchpadError("Refused a command outside the read-only list.",
                                       detail: Self.display(command.arguments))
        }
        return try await run(command.arguments, warningStatuses: command.warningStatuses)
    }
}

// MARK: - Output

extension VPhoneLaunchpadCommandResult {
    /// The reason `vphone-cli` printed for a failure: its `Error:` lines
    /// without the prefix, or the output tail when there are none.
    public var failureReason: String {
        let errors = lines.compactMap { line -> String? in
            guard line.hasPrefix("Error: ") else {
                return nil
            }
            return String(line.dropFirst("Error: ".count))
        }
        if !errors.isEmpty {
            return errors.joined(separator: "\n")
        }
        let tail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? "exit status \(status)" : tail
    }
}
