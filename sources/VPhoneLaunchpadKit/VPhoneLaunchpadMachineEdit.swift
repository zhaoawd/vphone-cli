import Darwin
import Foundation
import VPhoneCore

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

        public var hardwareKeyboardEnabled: Bool?
        public var unlockAtStartup: Bool?
        public var cpu: Int?
        public var memoryMB: Int?
        /// `nat`, `bridged` or `none`.
        public var network: String?
        /// Only with `bridged`; empty lets `vphone-cli` pick the first
        /// interface.
        public var bridgeInterface: String?

        public init(cpu: Int? = nil, memoryMB: Int? = nil, network: String? = nil, bridgeInterface: String? = nil, hardwareKeyboardEnabled: Bool? = nil, unlockAtStartup: Bool? = nil) {
            self.unlockAtStartup = unlockAtStartup
            self.hardwareKeyboardEnabled = hardwareKeyboardEnabled
            self.cpu = cpu
            self.memoryMB = memoryMB
            self.network = network
            self.bridgeInterface = bridgeInterface
        }

        public var isEmpty: Bool {
            cpu == nil && memoryMB == nil && network == nil && hardwareKeyboardEnabled == nil && unlockAtStartup == nil
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
        if let enabled = settings.unlockAtStartup {
            arguments += ["--startup-unlock", enabled ? "on" : "off"]
        }
        if let enabled = settings.hardwareKeyboardEnabled {
            arguments += ["--hardware-keyboard", enabled ? "on" : "off"]
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
    public static func clone(
        _ machine: VPhoneLaunchpadMachinePath,
        as newName: String,
        newIdentity: Bool = false
    ) -> Self? {
        guard isPassable(machine), isAcceptedNewName(newName, for: machine) else {
            return nil
        }
        return Self(.clone, machine.cloneArguments(as: newName, newIdentity: newIdentity))
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
    func run(_ command: VPhoneLaunchpadEditCommand,
             onProgress: (@MainActor (VPhoneTransferProgress) -> Void)? = nil) async throws -> VPhoneLaunchpadCommandResult {
        let direction: VPhoneTransferProgress.Direction? = switch command.kind {
        case .importArchive: .importArchive
        case .export: .exportArchive
        default: nil
        }
        return try await run(command.arguments, transferDirection: direction, onTransferProgress: onProgress)
    }
}

// MARK: - Export output

/// Checks destination occupancy without following the final path component.
public enum VPhoneLaunchpadExportOutput {
    /// True when anything, even a dangling link, is at `url`.
    public static func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }
}

// MARK: - vm snapshot list

/// One entry of `vphone-cli vm snapshot list <vm> --json`: a copy of the
/// machine's disk, SEP storage and NVRAM taken while it was stopped. The list
/// comes oldest first.
public struct VPhoneLaunchpadMachineSnapshot: Decodable, Hashable, Identifiable, Sendable {
    public let name: String
    public let created: Date
    public let note: String?

    public var id: String {
        name
    }

    /// Decodes the array `vm snapshot list --json` prints, whose `created`
    /// is written with JSONEncoder's `.iso8601`.
    public static func list(from data: Data) throws -> [Self] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([Self].self, from: data)
    }

    /// The name Take Snapshot offers: the local date and time to the minute,
    /// `2026-10-06-2230`, with `-2`, `-3`… when that is taken. It follows the
    /// machine name rules, which snapshot names share.
    public static func defaultName(at date: Date, taken: Set<String>, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let base = String(
            format: "%04d-%02d-%02d-%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0
        )
        var name = base
        var counter = 2
        while taken.contains(name) {
            name = "\(base)-\(counter)"
            counter += 1
        }
        return name
    }
}

// MARK: - Arguments

/// The `vphone-cli` arguments for clone and snapshots, kept apart from the
/// library so they can be checked without running anything.
public extension VPhoneLaunchpadMachinePath {
    /// `--new-identity` gives the clone its own ECID, UDID and MAC, so it can
    /// run beside this machine.
    func cloneArguments(as newName: String, newIdentity: Bool) -> [String] {
        ["vm", "clone", name, newName] + (newIdentity ? ["--new-identity"] : []) + libraryArguments
    }

    var snapshotListArguments: [String] {
        ["vm", "snapshot", "list", name, "--json"] + libraryArguments
    }

    /// A blank note is left out. The note is joined to its option, so one
    /// that starts with a hyphen is not read as another option.
    func snapshotCreateArguments(_ snapshot: String, note: String?) -> [String] {
        var arguments = ["vm", "snapshot", "create", name, snapshot]
        if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            arguments.append("--note=\(note)")
        }
        return arguments + libraryArguments
    }

    func snapshotRevertArguments(_ snapshot: String) -> [String] {
        ["vm", "snapshot", "revert", name, snapshot, "--force"] + libraryArguments
    }

    func snapshotDeleteArguments(_ snapshot: String) -> [String] {
        ["vm", "snapshot", "delete", name, snapshot, "--force"] + libraryArguments
    }
}
