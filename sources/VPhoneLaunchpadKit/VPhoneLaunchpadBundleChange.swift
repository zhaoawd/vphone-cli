import Darwin
import Foundation
import VPhoneCore

/// The binding is retained if the environment update fails after publication.
public enum VPhoneLaunchpadBundleChange: Equatable, Sendable {
    case bound
    case updated
    case boundButNotUpdated
    case refused([VPhoneProcessHolder])

    @MainActor
    static func perform(
        updatesEnvironment: Bool,
        diskHolders: () async throws -> [VPhoneProcessHolder],
        bind: () async throws -> Void,
        updateEnvironment: () async throws -> Bool
    ) async throws -> Self {
        if updatesEnvironment {
            let holders = try await diskHolders()
            guard holders.isEmpty else { return .refused(holders) }
        }
        try await bind()
        guard updatesEnvironment else { return .bound }
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
