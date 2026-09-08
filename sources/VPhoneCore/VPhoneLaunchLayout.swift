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
    public func stageVphoned(into bundle: VPhoneBundle) throws -> Bool {
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

/// Locates the vphone-cli boot process of a bundle from `ps -axo pid=,command=`
/// output.
///
/// The bundle's disk image is opened by the Virtualization.framework helper
/// process, not by vphone-cli, so a file holder lookup (`lsof Disk.img`) names
/// the helper and never the process that owns the VM lifecycle. The boot process
/// is instead identified by its own command line: it is always spawned as
/// `<vphone-cli binary> --config <bundle>/config.plist [...]`.
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

    public static func parsePIDs(_ psOutput: String, configPaths: [String]) -> [Int32] {
        let wanted = Set(configPaths.filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return [] }

        var seen = Set<Int32>()
        var pids: [Int32] = []
        for line in psOutput.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, let pid = Int32(fields[0]), pid > 0 else { continue }
            let argv = Array(fields.dropFirst())
            guard isVPhoneCLIExecutable(argv[0]), hasConfigArgument(argv, in: wanted) else { continue }
            guard seen.insert(pid).inserted else { continue }
            pids.append(pid)
        }
        return pids.sorted()
    }

    /// True for both the dev binary (`.build/release/vphone-cli`) and the
    /// bundled one (`vPhone.app/Contents/MacOS/vphone-cli`).
    static func isVPhoneCLIExecutable(_ token: String) -> Bool {
        token.split(separator: "/").last.map(String.init) == "vphone-cli"
    }

    /// Requires an exact `--config <path>` (or `--config=<path>`) token pair, so
    /// a process that merely mentions the path elsewhere does not match.
    static func hasConfigArgument(_ argv: [String], in wanted: Set<String>) -> Bool {
        for (index, token) in argv.enumerated() {
            if token == "--config" {
                if index + 1 < argv.count, wanted.contains(argv[index + 1]) { return true }
            } else if token.hasPrefix("--config="),
                      wanted.contains(String(token.dropFirst("--config=".count))) {
                return true
            }
        }
        return false
    }
}
