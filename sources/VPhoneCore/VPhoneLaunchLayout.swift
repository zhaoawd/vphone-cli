import Darwin
import Foundation

// MARK: - VPhoneLaunchLayout

public struct VPhoneLaunchLayout: Sendable {
    public let resources: VPhoneResources

    public init(resources: VPhoneResources) { self.resources = resources }
    public init(projectRoot: URL) { self.init(resources: VPhoneResources(base: projectRoot)) }

    public var preflightScript: URL { resources.preflightScript }
    public var fwPrepareScript: URL { resources.fwPrepareScript }
    public var cfwInstallHostScript: URL { resources.cfwInstallHostScript }
    public var pmd3Bridge: URL { resources.pmd3Bridge }
    public var vphoned: URL { resources.vphoned }

    public func python() throws -> URL { try resources.pythonExecutable() }

    /// Copy the built vphoned into the bundle if present and different.
    @discardableResult
    public func stageVphoned(into bundle: VPhoneBundle, less: Bool = false) throws -> Bool {
        let vphoned = less ? resources.vphonedLess : resources.vphoned
        let fm = FileManager.default
        guard fm.fileExists(atPath: vphoned.path) else { return false }
        let dst = bundle.url.appendingPathComponent(".vphoned.signed")
        if fm.fileExists(atPath: dst.path),
           let a = try? Data(contentsOf: vphoned),
           let b = try? Data(contentsOf: dst), a == b {
            return false
        }
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.copyItem(at: vphoned, to: dst)
        return true
    }
}

// MARK: - VPhoneLsof

public enum VPhoneLsof {
    /// A failed inspection is not evidence that a file is unused.
    public static func holders(of file: URL) throws -> [Int32] {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw NSError(domain: "VPhoneFileUse", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot inspect missing VM disk: \(file.path)"])
        }
        let result = try VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: "/usr/sbin/lsof"),
            ["-nP", "-t", "--", file.path], timeout: 5)
        let holders = parsePIDs(result.stdout)
        guard !result.timedOut, result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (result.exitCode == 0 && !holders.isEmpty) || (result.exitCode == 1 && result.stdout.isEmpty) else {
            throw NSError(domain: "VPhoneFileUse", code: 2, userInfo: [NSLocalizedDescriptionKey: "VM disk holder inspection failed (exit \(result.exitCode)): \(result.stderr)"])
        }
        return holders
    }

    public static func parsePIDs(_ output: String) -> [Int32] {
        var seen = Set<Int32>()
        var pids: [Int32] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let pid = Int32(trimmed), !seen.contains(pid) else { continue }
            seen.insert(pid)
            pids.append(pid)
        }
        return pids.sorted()
    }
}

// MARK: - VPhoneBootProcessLocator

/// Locates the vphone-vm or legacy vphone-cli boot process of a bundle from `ps -axo pid=,command=`
/// output.
///
/// The bundle's disk image is opened by the Virtualization.framework helper
/// process, not by vphone-cli, so a file holder lookup (`lsof Disk.img`) names
/// the helper and never the process that owns the VM lifecycle. The boot process
/// is instead identified by its own command line: it is always spawned as
/// `<VM binary> --config <bundle>/config.plist [...]`.
///
/// Pure string-in / PIDs-out so it can be unit-tested like `VPhoneLsof.parsePIDs`.
public enum VPhoneBootProcessLocator {
    /// Accepted spellings of one bundle's config path: as given, standardized,
    /// and symlink-resolved (the boot process is spawned with the path the
    /// launcher held, which may differ from the resolved one).
    public static func configPathVariants(for configURL: URL) -> [String] {
        var variants: [String] = []
        // The parent is resolved separately: `resolvingSymlinksInPath()` leaves a
        // path untouched when its last component does not exist on disk.
        let resolvedParent = configURL.deletingLastPathComponent()
            .resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent(configURL.lastPathComponent)
        for candidate in [
            configURL.path,
            configURL.standardizedFileURL.path,
            configURL.resolvingSymlinksInPath().standardizedFileURL.path,
            resolvedParent.path,
        ] where !candidate.isEmpty && !variants.contains(candidate) {
            variants.append(candidate)
        }
        return variants
    }

    public static func parsePIDs(_ psOutput: String, configURL: URL) -> [Int32] {
        parsePIDs(psOutput, configPaths: configPathVariants(for: configURL))
    }

    /// For live processes, `ps` supplies only candidate PIDs. Kernel argv
    /// preserves spaces and argument boundaries; flattened text is not trusted.
    public static func livePIDs(_ psOutput: String, configURL: URL) -> [Int32] {
        let wanted = Set(configPathVariants(for: configURL))
        let canonical = Set(wanted.map(canonicalConfigPath))
        let candidates = Set(psOutput.split(whereSeparator: \.isNewline).compactMap {
            line -> Int32? in
            guard line.contains("vphone-cli") || line.contains("vphone-vm") else { return nil }
            return line.split(whereSeparator: \.isWhitespace).first.flatMap { Int32($0) }
        })
        return candidates.filter { pid in
            guard pid > 0, let argv = VPhoneProcessInfo.arguments(of: pid), let first = argv.first,
                  isVPhoneBootExecutable(first) else { return false }
            return hasConfigArgument(argv, matching: { wanted.contains($0) || canonical.contains(canonicalConfigPath($0)) })
        }.sorted()
    }

    /// Matches `--config` arguments against `configPaths` by exact spelling or
    /// by canonical path (`canonicalConfigPath`), so a launcher that passed
    /// `/a/../vms/x/config.plist` or a symlinked directory still matches. Paths
    /// are compared whole: `/vms/x` never matches `/vms/x-2`.
    public static func parsePIDs(_ psOutput: String, configPaths: [String]) -> [Int32] {
        let wanted = Set(configPaths.filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return [] }
        let canonical = Set(wanted.map(canonicalConfigPath))

        var seen = Set<Int32>()
        var pids: [Int32] = []
        for line in psOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, let pid = Int32(fields[0]), pid > 0 else { continue }
            let argv = Array(fields.dropFirst())
            guard isVPhoneBootExecutable(argv[0]),
                  hasConfigArgument(argv, matching: { wanted.contains($0) || canonical.contains(canonicalConfigPath($0)) })
            else { continue }
            guard seen.insert(pid).inserted else { continue }
            pids.append(pid)
        }
        return pids.sorted()
    }

    /// Absolute path whose parent directory is resolved by `realpath(3)` (`.`,
    /// `..` and symlinks resolved as the kernel resolves them) when it exists,
    /// otherwise the lexically standardized path. A relative path is returned
    /// unchanged: the working directory of the process that received it is unknown.
    public static func canonicalConfigPath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        let url = URL(fileURLWithPath: path)
        let last = url.lastPathComponent
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        if last != "/", last != ".", last != "..", realpath(url.deletingLastPathComponent().path, &buffer) != nil {
            return URL(fileURLWithPath: String(cString: buffer), isDirectory: true).appendingPathComponent(last).path
        }
        return url.standardizedFileURL.path
    }

    /// Accept the paired runtime and the legacy CLI boot executable.
    static func isVPhoneBootExecutable(_ token: String) -> Bool {
        guard let name = token.split(separator: "/").last.map(String.init) else { return false }
        return name == "vphone-cli" || name == "vphone-vm"
    }

    /// Requires an exact `--config <path>` (or `--config=<path>`) token pair, so
    /// a process that merely mentions the path elsewhere does not match.
    static func hasConfigArgument(_ argv: [String], matching matches: (String) -> Bool) -> Bool {
        for (index, token) in argv.enumerated() {
            if token == "--config" {
                if index + 1 < argv.count, matches(argv[index + 1]) { return true }
            } else if token.hasPrefix("--config="), matches(String(token.dropFirst("--config=".count))) {
                return true
            }
        }
        return false
    }
}

// MARK: - VPhoneProcessHolder

/// A process that has one of a machine's files open, and what it is, judged
/// by its executable.
public struct VPhoneProcessHolder: Equatable, Sendable, CustomStringConvertible {
    public enum Kind: Equatable, Sendable {
        /// `vphone-vm`, which runs the machine.
        case virtualMachine
        /// `com.apple.Virtualization.VirtualMachine`, the XPC service that
        /// holds the machine's disk for its `vphone-vm`.
        case virtualizationService
        /// Anything else that has the file open.
        case other
    }

    public var pid: pid_t
    /// From `proc_pidpath`; nil for a process that is gone or cannot be
    /// inspected.
    public var executablePath: String?

    public init(pid: pid_t, executablePath: String?) {
        self.pid = pid
        self.executablePath = executablePath
    }

    public init(pid: pid_t) {
        self.init(pid: pid, executablePath: Self.executablePath(of: pid))
    }

    public var kind: Kind {
        Self.kind(executablePath: executablePath)
    }

    public var runsMachine: Bool {
        kind != .other
    }

    public var name: String {
        executablePath.map { ($0 as NSString).lastPathComponent } ?? "unknown"
    }

    public var description: String {
        "\(pid) \(name)"
    }

    static let virtualizationServiceName = "com.apple.Virtualization.VirtualMachine"

    public static func kind(executablePath: String?) -> Kind {
        guard let executablePath, !executablePath.isEmpty else { return .other }
        let components = (executablePath as NSString).pathComponents
        switch components.last {
        case "vphone-vm":
            return .virtualMachine
        case virtualizationServiceName where components.contains("Virtualization.framework"):
            return .virtualizationService
        default:
            return .other
        }
    }

    public static func classify(_ holders: [VPhoneProcessHolder]) -> (machine: [VPhoneProcessHolder], others: [VPhoneProcessHolder]) {
        let sorted = holders.sorted { $0.pid < $1.pid }
        return (sorted.filter(\.runsMachine), sorted.filter { !$0.runsMachine })
    }

    public static func describe(_ holders: [VPhoneProcessHolder]) -> String {
        holders.map(\.description).joined(separator: ", ")
    }

    public static func diskRefusal(_ holders: [VPhoneProcessHolder], rerun: String) -> String? {
        guard !holders.isEmpty else { return nil }
        let (machine, others) = classify(holders)
        if !machine.isEmpty {
            return "The VM is running (process \(describe(machine + others))). Stop the VM, then \(rerun)."
        }
        return "The VM disk is open in process \(describe(others)), which does not run the VM. "
            + "Wait for it to close the disk, then \(rerun)."
    }

    public static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

// MARK: - VPhoneGuestProcesses

public enum VPhoneGuestProcesses {
    static func allPIDs() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let filled = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled))).filter { $0 > 0 }
    }
}
