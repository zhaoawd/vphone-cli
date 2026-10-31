import Darwin
import Foundation
import VPhoneCore

/// The binding is retained if the environment update fails after publication.
public enum VPhoneLaunchpadBundleChange: Equatable, Sendable {
    case bound
    case updated
    case boundButNotUpdated
    case refused([VPhoneProcessHolder])

    public static func bindingArguments(_ machine: VPhoneLaunchpadMachinePath, version: String, backup: URL?, expectedSHA256: String? = nil) -> [String]? {
        guard VPhoneLaunchpadMachineName.isPassable(machine.name),
              machine.libraryRoot.hasPrefix("/"), !machine.libraryRoot.contains("\0"),
              VPhoneCoreBundleVersion.supportsTargetFeatures(version),
              expectedSHA256.map({ $0 == "missing" || ($0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) }) }) ?? true,
              backup.map({ $0.isFileURL && $0.path.hasPrefix("/") && !$0.path.contains("\0") }) ?? true else { return nil }
        var args = ["vm", "bind-core-bundle", machine.name, "--version", version] + machine.libraryArguments
        if let backup { args += ["--backup", backup.path] }
        if let expectedSHA256 { args += ["--expected-binding-sha256", expectedSHA256] }
        return args
    }

    public static func environmentArguments(_ machine: VPhoneLaunchpadMachinePath, workParent: URL? = nil) -> [String]? {
        guard VPhoneLaunchpadMachineName.isPassable(machine.name),
              machine.libraryRoot.hasPrefix("/"), !machine.libraryRoot.contains("\0"),
              workParent.map({ $0.isFileURL && $0.path.hasPrefix("/") && !$0.path.contains("\0") }) ?? true else { return nil }
        var args = ["cfw", "update-environment", machine.name] + machine.libraryArguments
        args.append("--root-popup")
        if let workParent { args += ["--work-parent", workParent.path] }
        return args
    }

    @MainActor
    static func perform(
        updatesEnvironment: Bool,
        diskHolders: () async throws -> [VPhoneProcessHolder],
        bind: () async throws -> Void,
        updateEnvironment: () async throws -> Bool
    ) async throws -> Self {
        try Task.checkCancellation()
        if updatesEnvironment {
            let holders = try await diskHolders()
            guard holders.isEmpty else { return .refused(holders) }
        }
        try Task.checkCancellation()
        try await bind()
        guard updatesEnvironment else { return .bound }
        try Task.checkCancellation()
        return try await updateEnvironment() ? .updated : .boundButNotUpdated
    }
}

/// lsof's process and filename records retain the owning pid across file rows.
/// Launchpad's own short-lived readers do not make it an external holder.
enum VPhoneLaunchpadDiskHolders {
    static func parse(_ output: String, excluding ownPID: pid_t = getpid()) -> [pid_t] {
        var pid: pid_t?
        var found = Set<pid_t>()
        for line in output.split(whereSeparator: \.isNewline) {
            if line.first == "p" { pid = Int32(line.dropFirst()) }
            if line.first == "n", let pid, pid > 0, pid != ownPID { found.insert(pid) }
        }
        return found.sorted()
    }

    static func read(_ disk: URL) throws -> [VPhoneProcessHolder] {
        guard FileManager.default.fileExists(atPath: disk.path) else {
            throw VPhoneLaunchpadError("Cannot inspect missing VM disk: \(disk.path)")
        }
        let result = try VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: "/usr/sbin/lsof"),
            ["-nP", "-F", "pn", "--", disk.path], timeout: 5)
        guard !result.timedOut, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (result.exitCode == 0 && !result.stdout.isEmpty) || (result.exitCode == 1 && result.stdout.isEmpty) else {
            throw VPhoneLaunchpadError("VM disk holder inspection failed", detail: result.stderr)
        }
        return parse(result.stdout).map { VPhoneProcessHolder(pid: $0) }
    }
}
