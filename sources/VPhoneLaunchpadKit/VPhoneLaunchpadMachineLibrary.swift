import Foundation
import Observation

/// The VM library, listed through `vphone-cli vm list --json`. B1 is
/// read-only: it lists machines and shows their run state, and runs no
/// command that changes a machine.
///
/// Machines can live in several libraries: the default one, and folders in
/// the `VPhoneLaunchpadLibraryRoots` default. Each library is listed with its
/// own `--library-root`.
@MainActor
@Observable
public final class VPhoneLaunchpadMachineLibrary {
    public typealias Path = VPhoneLaunchpadMachinePath

    public static let addedRootsKey = "VPhoneLaunchpadLibraryRoots"
    public static let refreshInterval: Duration = .seconds(5)

    public private(set) var machines: [VPhoneLaunchpadMachine] = []
    public private(set) var listError: String?
    /// False until the first `vm list` answers, so the window does not show
    /// "No Machines" before it knows.
    public private(set) var hasListed = false
    public private(set) var runStates: [Path: VPhoneLaunchpadRunState] = [:]
    /// Further libraries, in the order they were added. The default library
    /// is not among them.
    public private(set) var addedRoots: [String]
    public var selection: Set<Path> = []

    /// The default library, canonical.
    public let libraryRoot: String
    private let defaults: UserDefaults
    private let runStateReader: VPhoneLaunchpadRunStateReader
    private var commandLine: VPhoneLaunchpadCommandLine?
    private var isRefreshing = false
    private var monitor: Task<Void, Never>?
    private var lastReportedCount: Int?

    public init(
        defaults: UserDefaults = .standard,
        libraryRoot: String = VPhoneLaunchpadMachineLocations.defaultRoot,
        runStateReader: VPhoneLaunchpadRunStateReader = .live
    ) {
        self.defaults = defaults
        self.libraryRoot = libraryRoot
        self.runStateReader = runStateReader
        addedRoots = VPhoneLaunchpadMachineLocations.addedRoots(
            from: defaults.stringArray(forKey: Self.addedRootsKey) ?? [],
            defaultRoot: libraryRoot
        )
    }

    /// Every library, the default one first.
    public var roots: [String] {
        [libraryRoot] + addedRoots
    }

    /// The selected machines, in list order.
    public var selectedMachines: [VPhoneLaunchpadMachine] {
        machines.filter { selection.contains($0.id) }
    }

    /// True while machines from more than one library are listed.
    public var spansLibraries: Bool {
        Set(machines.map(\.libraryRoot)).count > 1
    }

    public func state(of machine: Path) -> VPhoneLaunchpadRunState {
        runStates[machine] ?? .stopped
    }

    // MARK: - Locations

    /// Remembers a folder so its machines are listed with the others.
    public func addLocation(_ root: String) {
        let canonical = VPhoneLaunchpadMachineLocations.canonical(URL(fileURLWithPath: root, isDirectory: true))
        guard canonical.hasPrefix("/"), canonical != libraryRoot, !addedRoots.contains(canonical) else {
            return
        }
        addedRoots.append(canonical)
        defaults.set(addedRoots, forKey: Self.addedRootsKey)
    }

    // MARK: - Refresh

    /// Starts listing with `commandLine`, then again every
    /// `refreshInterval`. Each pass runs `vm list --json` per library and
    /// one `ps` snapshot; nothing else.
    public func startMonitoring(with commandLine: VPhoneLaunchpadCommandLine) {
        self.commandLine = commandLine
        guard monitor == nil else {
            return
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    public func stopMonitoring() {
        monitor?.cancel()
        monitor = nil
    }

    public func refresh() async {
        guard let commandLine, !isRefreshing else {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        var found: [VPhoneLaunchpadMachine] = []
        var errors: [String] = []
        for root in roots {
            // vm list reports an empty library for a missing default root; a
            // missing added folder is skipped, and its machines go with it.
            guard root == libraryRoot || VPhoneLaunchpadMachineLocations.isAvailable(root) else {
                continue
            }
            do {
                let result = try await commandLine.run(["vm", "list", "--json", "--library-root", root], recordInHistory: false)
                if result.succeeded, let data = result.jsonData {
                    found += try VPhoneLaunchpadMachine.decodeList(data, libraryRoot: root)
                    continue
                }
                errors.append(result.tail)
            } catch {
                errors.append(error.localizedDescription)
            }
            // Keep what this library listed last time.
            found += machines.filter { $0.libraryRoot == root }
        }
        machines = found
        listError = errors.first
        hasListed = true
        selection.formIntersection(machines.map(\.id))
        if selection.isEmpty, let first = machines.first {
            selection = [first.id]
        }
        let paths = machines.map(\.path)
        let reader = runStateReader
        runStates = await Task.detached {
            guard let processList = VPhoneLaunchpadRunStateReader.processList() else {
                return [:]
            }
            return reader.states(processList: processList, machines: paths)
        }.value
        if lastReportedCount != machines.count {
            lastReportedCount = machines.count
            // Diagnostic line for the smoke check, written unbuffered; machine
            // names are not printed.
            let line = "[launchpad] listed \(machines.count) machines from \(roots.count) libraries\n"
            FileHandle.standardOutput.write(Data(line.utf8))
        }
    }
}
