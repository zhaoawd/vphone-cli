import Darwin
import Foundation

// MARK: - Machine names

/// Names Launchpad passes to `vphone-cli vm` as positional arguments.
public enum VPhoneLaunchpadMachineName {
    /// A name Launchpad offers for rename and clone: the upstream pattern, a
    /// subset of what `vphone-cli` accepts (non-empty, no `/`, no leading
    /// `.`). It starts with a letter or digit, so it is never read as an
    /// option.
    public static func isValidNewName(_ value: String) -> Bool {
        value.range(of: "^[0-9A-Za-z][0-9A-Za-z._-]{0,63}$", options: .regularExpression) != nil
            && !value.contains("..")
    }

    /// An existing machine's name, as `vm list` reported it, that can be
    /// passed as a positional argument. `vphone-cli` lists any folder with a
    /// `config.plist`; a name starting with `-` would be parsed as an option.
    public static func isPassable(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && !value.hasPrefix(".")
            && !value.contains("/") && !value.contains("\0") && !value.contains("\n")
    }
}

// MARK: - Edit commands

/// The `vphone-cli vm` commands that change a stopped machine or the library
/// (T26 B3): `config`, `rename`, `clone`, `delete`, `export` and `import`.
/// A value exists only through the factories below. Every one names its
/// library with `--library-root`.
///
/// Launchpad takes no VM lock for these. Each command takes the bundle lock
/// itself and refuses a machine that is running or busy; that refusal is
/// what Launchpad shows.
public struct VPhoneLaunchpadEditCommand: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case config
        case rename
        case clone
        case delete
        case export
        case importArchive
    }

    /// `vm config` fields. Nil fields are left as they are.
    public struct Settings: Equatable, Sendable {
        public static let networkModes = ["nat", "bridged", "none"]

        public var cpu: Int?
        public var memoryMB: Int?
        /// `nat`, `bridged` or `none`.
        public var network: String?
        /// Only with `bridged`; empty lets `vphone-cli` pick the first
        /// interface.
        public var bridgeInterface: String?

        public init(cpu: Int? = nil, memoryMB: Int? = nil, network: String? = nil, bridgeInterface: String? = nil) {
            self.cpu = cpu
            self.memoryMB = memoryMB
            self.network = network
            self.bridgeInterface = bridgeInterface
        }

        public var isEmpty: Bool {
            cpu == nil && memoryMB == nil && network == nil
        }
    }

    public let kind: Kind
    public let arguments: [String]

    private init(_ kind: Kind, _ arguments: [String]) {
        self.kind = kind
        self.arguments = arguments
    }

    /// `vm config <name> --library-root <root> [--cpu N] [--memory MB]
    /// [--network mode [--bridge-interface if]]`. nil for an empty edit or
    /// a value `vm config` would reject.
    public static func config(_ machine: VPhoneLaunchpadMachinePath, _ settings: Settings) -> Self? {
        guard isPassable(machine), !settings.isEmpty else {
            return nil
        }
        var arguments = ["vm", "config", machine.name] + machine.libraryArguments
        if let cpu = settings.cpu {
            guard cpu >= 1 else { return nil }
            arguments += ["--cpu", String(cpu)]
        }
        if let memoryMB = settings.memoryMB {
            guard memoryMB >= 1 else { return nil }
            arguments += ["--memory", String(memoryMB)]
        }
        let interface = settings.bridgeInterface ?? ""
        if let network = settings.network {
            guard Settings.networkModes.contains(network) else { return nil }
            arguments += ["--network", network]
            if network == "bridged", !interface.isEmpty {
                guard isInterfaceName(interface) else { return nil }
                arguments += ["--bridge-interface", interface]
            }
        }
        guard interface.isEmpty || settings.network == "bridged" else {
            return nil
        }
        return Self(.config, arguments)
    }

    /// `vm rename <name> <new name> --library-root <root>`. The machine stays
    /// in its library.
    public static func rename(_ machine: VPhoneLaunchpadMachinePath, to newName: String) -> Self? {
        guard isPassable(machine), isAcceptedNewName(newName, for: machine) else {
            return nil
        }
        return Self(.rename, ["vm", "rename", machine.name, newName] + machine.libraryArguments)
    }

    /// `vm clone <name> <new name> --library-root <root>`, into the same
    /// library.
    public static func clone(_ machine: VPhoneLaunchpadMachinePath, as newName: String) -> Self? {
        guard isPassable(machine), isAcceptedNewName(newName, for: machine) else {
            return nil
        }
        return Self(.clone, ["vm", "clone", machine.name, newName] + machine.libraryArguments)
    }

    /// `vm delete <name> --force --library-root <root>`. `--force` only skips
    /// the CLI's own stdin prompt, which reads `/dev/null` here and would
    /// abort; Launchpad asks first (`VPhoneLaunchpadDeleteView`).
    public static func delete(_ machine: VPhoneLaunchpadMachinePath) -> Self? {
        guard isPassable(machine) else {
            return nil
        }
        return Self(.delete, ["vm", "delete", machine.name, "--force"] + machine.libraryArguments)
    }

    /// `vm export <name> --out <file> --library-root <root> [--max]
    /// [--include-ipsw]`. `destination` is an absolute file path.
    public static func export(
        _ machine: VPhoneLaunchpadMachinePath, to destination: URL, densest: Bool, includeIPSW: Bool
    ) -> Self? {
        guard isPassable(machine), destination.isFileURL, isAbsolutePath(destination.path) else {
            return nil
        }
        var arguments = ["vm", "export", machine.name, "--out", destination.path] + machine.libraryArguments
        if densest {
            arguments.append("--max")
        }
        if includeIPSW {
            arguments.append("--include-ipsw")
        }
        return Self(.export, arguments)
    }

    /// `vm import <archive> --library-root <root>`. The machine keeps the
    /// archive's own name.
    public static func importArchive(_ archive: URL, into libraryRoot: String) -> Self? {
        guard archive.isFileURL, isAbsolutePath(archive.path), isAbsolutePath(libraryRoot) else {
            return nil
        }
        return Self(.importArchive, ["vm", "import", archive.path, "--library-root", libraryRoot])
    }

    /// The command as the history shows it, for copying into a terminal.
    public var display: String {
        VPhoneLaunchpadCommandLine.display(arguments)
    }

    // MARK: Checks

    private static func isPassable(_ machine: VPhoneLaunchpadMachinePath) -> Bool {
        VPhoneLaunchpadMachineName.isPassable(machine.name) && isAbsolutePath(machine.libraryRoot)
    }

    private static func isAcceptedNewName(_ name: String, for machine: VPhoneLaunchpadMachinePath) -> Bool {
        VPhoneLaunchpadMachineName.isValidNewName(name) && name != machine.name
            && VPhoneLaunchpadMachineLocations.socketPathFits(root: machine.libraryRoot, name: name)
    }

    private static func isInterfaceName(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$", options: .regularExpression) != nil
    }

    private static func isAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.contains("\0") && !value.contains("\n")
    }
}

// MARK: - Running

public extension VPhoneLaunchpadCommandLine {
    /// Runs one edit command, recorded in the history. Cancelling the
    /// calling task sends SIGINT to this child only.
    func run(_ command: VPhoneLaunchpadEditCommand) async throws -> VPhoneLaunchpadCommandResult {
        try await run(command.arguments)
    }
}

// MARK: - Export output

/// The archive file an export writes. Launchpad removes a file only after
/// cancelling the export that created it: the path held nothing when the
/// export started, and now holds a regular file (not a link, not a folder).
/// Nothing else in Launchpad removes files; machines are deleted only by
/// `vphone-cli vm delete`.
public enum VPhoneLaunchpadExportOutput {
    /// True when anything, even a dangling link, is at `url`.
    public static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    /// Removes the partial archive a cancelled export left at `url`. Call
    /// only when `exists(url)` was false before that export started. False
    /// when nothing was removed.
    @discardableResult
    public static func removeCancelled(_ url: URL, existedBefore: Bool) -> Bool {
        var info = stat()
        guard !existedBefore, lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            return false
        }
        return unlink(url.path) == 0
    }
}
