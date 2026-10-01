import Foundation
import VPhoneCore

// MARK: - Variants

/// The local `vm create --variant` values. Launchpad offers four of them.
public enum VPhoneLaunchpadCreateVariant: String, CaseIterable, Sendable {
    case regular
    case dev
    case jb
    case exp
    case less

    /// `less` needs the whole `vm create` to run as root (its help says so);
    /// Launchpad runs the CLI as the user and elevates only the CFW stage
    /// through `--root-popup`, so it does not offer `less`.
    public var isAvailable: Bool {
        self != .less
    }
}

// MARK: - Request

/// What New Machine asks for. CPU, memory and network are not options of
/// `vm create`: it creates the bundle with 8 cores, 8192 MB and NAT, which
/// Settings changes afterwards.
public struct VPhoneLaunchpadCreateRequest: Equatable, Sendable {
    public enum PrepareBackend: String, CaseIterable, Sendable {
        case script
        case native
    }

    public enum RestoreBackend: String, CaseIterable, Sendable {
        case python
        case native
    }

    public static let defaultDiskSizeGB = 64
    public static let diskSizeRange = 32 ... 512

    public var name: String
    public var libraryRoot: String
    public var variant: VPhoneLaunchpadCreateVariant
    public var iphoneSource: String
    public var cloudosSource: String
    public var diskSizeGB: Int
    public var keepArtifacts: Bool
    public var frida: Bool
    /// Only for `exp`.
    public var spoofBuild: String
    /// Nil leaves the CLI default (`script`); only Advanced sets it.
    public var prepareBackend: PrepareBackend?
    /// Nil leaves the CLI default (`python`); only Advanced sets it.
    public var restoreBackend: RestoreBackend?

    public init(
        name: String, libraryRoot: String, variant: VPhoneLaunchpadCreateVariant = .regular,
        iphoneSource: String, cloudosSource: String, diskSizeGB: Int = Self.defaultDiskSizeGB,
        keepArtifacts: Bool = false, frida: Bool = false, spoofBuild: String = "",
        prepareBackend: PrepareBackend? = nil, restoreBackend: RestoreBackend? = nil
    ) {
        self.name = name
        self.libraryRoot = libraryRoot
        self.variant = variant
        self.iphoneSource = iphoneSource
        self.cloudosSource = cloudosSource
        self.diskSizeGB = diskSizeGB
        self.keepArtifacts = keepArtifacts
        self.frida = frida
        self.spoofBuild = spoofBuild
        self.prepareBackend = prepareBackend
        self.restoreBackend = restoreBackend
    }

    public var machine: VPhoneLaunchpadMachinePath {
        VPhoneLaunchpadMachinePath(libraryRoot: libraryRoot, name: name)
    }
}

// MARK: - Commands

/// The commands of New Machine and the creation view (T26 B4): the firmware
/// catalog, `vm create`, `vm create --resume` and one `vm create-status`
/// after a create run has exited. A value exists only through the factories
/// below.
///
/// `vm create` and `--resume` always carry `--root-popup`: the CFW stage
/// elevates through the macOS authentication dialog, and Launchpad never
/// sees or passes a password. They never carry `--interactive`: the child's
/// stdin is /dev/null.
public struct VPhoneLaunchpadCreateCommand: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case catalog
        case create
        case resume
        case status
    }

    public let kind: Kind
    public let arguments: [String]

    private init(_ kind: Kind, _ arguments: [String]) {
        self.kind = kind
        self.arguments = arguments
    }

    /// `fw catalog --json`: the iOS and cloudOS pairings compiled into the
    /// embedded CLI. Reads nothing from the network.
    public static let catalog = Self(.catalog, ["fw", "catalog", "--json"])

    /// `vm create <name> --library-root <root> --variant <v> --iphone-source
    /// <s> --cloudos-source <s> --disk-size <GB> --root-popup [--keep-artifacts]
    /// [--frida] [--spoof-build <id>] [--prepare-backend <b>]
    /// [--restore-backend <b>]`. nil for `less`, a name or path Launchpad
    /// cannot pass, an empty source, or an option the CLI would reject.
    public static func create(_ request: VPhoneLaunchpadCreateRequest) -> Self? {
        refusal(request) == nil ? Self(.create, arguments(request)) : nil
    }

    /// Why `create(_:)` returns nil, for the New Machine footer.
    public static func refusal(_ request: VPhoneLaunchpadCreateRequest) -> Refusal? {
        guard request.variant.isAvailable else {
            return .variantUnavailable
        }
        guard VPhoneLaunchpadMachineName.isValidNewName(request.name) else {
            return .name
        }
        guard isAbsolutePath(request.libraryRoot),
              VPhoneLaunchpadMachineLocations.socketPathFits(root: request.libraryRoot, name: request.name)
        else {
            return .location
        }
        guard isSource(request.iphoneSource), isSource(request.cloudosSource) else {
            return .source
        }
        guard VPhoneLaunchpadCreateRequest.diskSizeRange.contains(request.diskSizeGB) else {
            return .diskSize
        }
        let spoof = request.spoofBuild.trimmingCharacters(in: .whitespaces)
        if !spoof.isEmpty {
            guard request.variant == .exp, spoof.range(of: "^[0-9A-Za-z]{1,16}$", options: .regularExpression) != nil else {
                return .spoofBuild
            }
        }
        // Native prepare reads two local IPSW files and nothing else
        // (`VPhoneNativeFirmwarePreparer.localSources`).
        if request.prepareBackend == .native {
            guard isAbsolutePath(request.iphoneSource), isAbsolutePath(request.cloudosSource) else {
                return .nativePrepareNeedsFiles
            }
        }
        return nil
    }

    public enum Refusal: Equatable, Sendable {
        case variantUnavailable
        case name
        case location
        case source
        case diskSize
        case spoofBuild
        case nativePrepareNeedsFiles
    }

    private static func arguments(_ request: VPhoneLaunchpadCreateRequest) -> [String] {
        var arguments = ["vm", "create", request.name] + request.machine.libraryArguments
        arguments += ["--variant", request.variant.rawValue]
        arguments += ["--iphone-source", request.iphoneSource, "--cloudos-source", request.cloudosSource]
        arguments += ["--disk-size", String(request.diskSizeGB)]
        arguments.append("--root-popup")
        if request.keepArtifacts {
            arguments.append("--keep-artifacts")
        }
        if request.frida {
            arguments.append("--frida")
        }
        let spoof = request.spoofBuild.trimmingCharacters(in: .whitespaces)
        if !spoof.isEmpty {
            arguments += ["--spoof-build", spoof]
        }
        if let backend = request.prepareBackend {
            arguments += ["--prepare-backend", backend.rawValue]
        }
        if let backend = request.restoreBackend {
            arguments += ["--restore-backend", backend.rawValue]
        }
        return arguments
    }

    /// `vm create <name> --resume --library-root <root> --root-popup
    /// [--restart-from <stage>] [--accept-tool-change] [--keep-artifacts]`.
    /// `variant` is the checkpoint's; nil for `less`, for an unknown variant,
    /// and for a name Launchpad cannot pass. `--accept-tool-change` is set
    /// only after the user has confirmed the change the CLI reported.
    public static func resume(
        _ machine: VPhoneLaunchpadMachinePath, variant: String, restartFrom: VPhoneCreateStage? = nil,
        acceptToolChange: Bool = false, keepArtifacts: Bool = false
    ) -> Self? {
        guard let variant = VPhoneLaunchpadCreateVariant(rawValue: variant), variant.isAvailable,
              isPassable(machine)
        else {
            return nil
        }
        var arguments = ["vm", "create", machine.name, "--resume"] + machine.libraryArguments
        arguments.append("--root-popup")
        if let restartFrom {
            arguments += ["--restart-from", restartFrom.rawValue]
        }
        if acceptToolChange {
            arguments.append("--accept-tool-change")
        }
        if keepArtifacts {
            arguments.append("--keep-artifacts")
        }
        return Self(.resume, arguments)
    }

    /// `vm create-status <name> --json --library-root <root>`. It probes the
    /// run lock and the bundle lock, so Launchpad runs it once after its own
    /// create run has exited, never on a timer.
    public static func status(_ machine: VPhoneLaunchpadMachinePath) -> Self? {
        guard isPassable(machine) else {
            return nil
        }
        return Self(.status, ["vm", "create-status", machine.name, "--json"] + machine.libraryArguments)
    }

    /// The command as the history shows it, for copying into a terminal.
    public var display: String {
        VPhoneLaunchpadCommandLine.display(arguments)
    }

    // MARK: Checks

    private static func isPassable(_ machine: VPhoneLaunchpadMachinePath) -> Bool {
        VPhoneLaunchpadMachineName.isPassable(machine.name) && isAbsolutePath(machine.libraryRoot)
    }

    /// A URL or an absolute path, never read as an option.
    private static func isSource(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && !value.contains("\0") && !value.contains("\n")
            && value == value.trimmingCharacters(in: .whitespaces)
            && (value.hasPrefix("/") || URL(string: value)?.scheme.map { ["http", "https"].contains($0.lowercased()) } == true)
    }

    private static func isAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.contains("\0") && !value.contains("\n")
    }
}

// MARK: - Running

public extension VPhoneLaunchpadCommandLine {
    /// Runs the catalog or the status command to completion.
    func run(_ command: VPhoneLaunchpadCreateCommand, recordInHistory: Bool = true) async throws -> VPhoneLaunchpadCommandResult {
        try await run(command.arguments, recordInHistory: recordInHistory)
    }

    /// Starts `vm create` or `--resume` detached, in its own session and
    /// process group, writing to `logFile`. Returns at once.
    func start(
        _ command: VPhoneLaunchpadCreateCommand, logFile: URL, appendingToLog: Bool,
        onLine: @escaping @Sendable (String) -> Void
    ) throws -> VPhoneLaunchpadChildProcess {
        let entry = history.record(command.display)
        let child = try VPhoneLaunchpadChildProcess(
            executable: executable, arguments: command.arguments, logFile: logFile,
            appendingToLog: appendingToLog, onLine: onLine)
        let history = history
        Task {
            let status = await child.wait()
            history.finish(entry, status: status)
        }
        return child
    }
}

// MARK: - Firmware catalog

/// `fw catalog --json`, decoded with the CLI's own report type.
public struct VPhoneLaunchpadFirmwareCatalog: Equatable, Sendable {
    public struct Pairing: Equatable, Identifiable, Sendable {
        public let iosName: String
        public let iosURL: String
        public let cloudOSName: String
        public let cloudOSURL: String

        public var id: String {
            iosURL
        }

        /// The build from an IPSW name such as `iPhone17,3_26.1_23B85_Restore.ipsw`.
        public var build: String {
            let fields = (iosURL as NSString).lastPathComponent.split(separator: "_")
            return fields.count >= 4 ? String(fields[2]) : ""
        }
    }

    public let device: String
    public let pairings: [Pairing]

    public static func decode(_ result: VPhoneLaunchpadCommandResult) throws -> Self {
        guard result.succeeded, let data = result.jsonData else {
            throw VPhoneLaunchpadError(String(localized: "Unable to read the firmware catalog."), detail: result.tail)
        }
        let report = try JSONDecoder().decode(VPhoneFirmwareCatalogReport.self, from: data)
        return Self(device: report.device, pairings: report.pairings.map {
            Pairing(iosName: $0.ios.name, iosURL: $0.ios.url,
                    cloudOSName: $0.recommendedCloudOS.name, cloudOSURL: $0.recommendedCloudOS.url)
        })
    }
}
