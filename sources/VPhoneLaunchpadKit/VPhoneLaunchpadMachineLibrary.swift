import Foundation
import Observation

/// The VM library, listed through `vphone-cli vm list --json`, started with
/// `vm launch`, stopped with `vm stop`, and edited offline with `vm config`,
/// `rename`, `clone`, `delete`, `export` and `import`. Launchpad never takes
/// or probes a VM lock: `vphone-vm` holds it, and the CLI refuses
/// conflicting work itself.
///
/// Machines can live in several libraries: the default one, and folders in
/// the `VPhoneLaunchpadLibraryRoots` default. Each library is listed with its
/// own `--library-root`, and every action on a machine passes the root it was
/// listed from.
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
    /// When Launchpad started each machine it still holds a `vm launch` for.
    public private(set) var startedAt: [Path: Date] = [:]
    /// Machines whose console printed a panic line since Launchpad last
    /// started them. The text itself stays in the log file.
    public private(set) var panicked: Set<Path> = []
    /// What Launchpad is doing to a machine right now (`Stopping…`).
    public private(set) var activities: [Path: String] = [:]
    public var actionError: VPhoneLaunchpadError?

    /// The default library, canonical.
    public let libraryRoot: String
    /// Where console logs go: `~/Library/Logs/vphone-cli-launchpad`.
    public let logsDirectory: URL
    private let defaults: UserDefaults
    private let runStateReader: VPhoneLaunchpadRunStateReader
    private var commandLine: VPhoneLaunchpadCommandLine?
    /// The `vm launch` children this Launchpad started. Signals go only to
    /// these.
    private var launched: [Path: VPhoneLaunchpadChildProcess] = [:]
    private var isRefreshing = false
    private var monitor: Task<Void, Never>?
    private var lastReportedCount: Int?

    public init(
        defaults: UserDefaults = .standard,
        libraryRoot: String = VPhoneLaunchpadMachineLocations.defaultRoot,
        logsDirectory: URL = VPhoneLaunchpadIdentity.logsDirectory(),
        runStateReader: VPhoneLaunchpadRunStateReader = .live
    ) {
        self.defaults = defaults
        self.libraryRoot = libraryRoot
        self.logsDirectory = logsDirectory
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

    /// The selected machine when exactly one is selected.
    public var selected: VPhoneLaunchpadMachine? {
        let selected = selectedMachines
        return selected.count == 1 ? selected[0] : nil
    }

    /// True while machines from more than one library are listed.
    public var spansLibraries: Bool {
        Set(machines.map(\.libraryRoot)).count > 1
    }

    /// The process list's view of a machine; also running while a
    /// `vm launch` this Launchpad started has not exited, since its VM
    /// process is not up yet while `vm launch` runs the host preflight.
    public func state(of machine: Path) -> VPhoneLaunchpadRunState {
        let listed = runStates[machine] ?? .stopped
        if !listed.isRunning, launched[machine]?.isRunning == true {
            return .running(instanceID: nil)
        }
        return listed
    }

    public func canStart(_ machine: Path) -> Bool {
        commandLine != nil && activities[machine] == nil && exports[machine] == nil && state(of: machine) == .stopped
    }

    /// Settings, rename, clone, export and delete are offered for a stopped
    /// machine with nothing else under way. The CLI decides: it refuses a
    /// machine whose bundle lock is held, and that refusal is shown.
    public func canEdit(_ machine: Path) -> Bool {
        canStart(machine)
    }

    /// The text that takes the place of a machine's state: an action under
    /// way (`Stopping…`, `Exporting…`), or an export waiting its turn.
    public func activity(of machine: Path) -> String? {
        if let activity = activities[machine] {
            return activity
        }
        if exports[machine]?.isWaiting == true {
            return String(localized: "Waiting to export…")
        }
        return nil
    }

    /// True while `vm export` runs for `machine`. The CLI prints no progress
    /// lines to a pipe, so progress is shown as indeterminate.
    public func isExporting(_ machine: Path) -> Bool {
        exports[machine]?.isRunning == true
    }

    public func canStop(_ machine: Path) -> Bool {
        commandLine != nil && activities[machine] == nil && state(of: machine).isRunning
    }

    /// The `vm launch` child this Launchpad holds for `machine`, until it exits.
    func launchedProcess(_ machine: Path) -> VPhoneLaunchpadChildProcess? {
        launched[machine]
    }

    /// The machine's console log. Every start from Launchpad replaces it.
    public func consoleLog(_ machine: Path) -> URL {
        VPhoneLaunchpadMachineLocations.consoleLog(machine, defaultRoot: libraryRoot, logsDirectory: logsDirectory)
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
            Self.diagnostic("listed \(machines.count) machines from \(roots.count) libraries")
        }
    }

    // MARK: - Start and stop

    /// `vm launch <name> --library-root <root> [--headless]`, detached: the
    /// child gets its own session and writes to the machine's console log,
    /// so it keeps running after Launchpad quits. Returns at once.
    public func start(_ machine: Path, headless: Bool = false) {
        guard let commandLine, canStart(machine) else {
            return
        }
        var arguments = ["vm", "launch", machine.name] + machine.libraryArguments
        if headless {
            arguments.append("--headless")
        }
        let log = consoleLog(machine)
        panicked.remove(machine)
        do {
            let child = try commandLine.start(arguments, logFile: log) { [weak self] line in
                if VPhoneLaunchpadConsoleLog.isPanic(line) {
                    Task { @MainActor in self?.panicked.insert(machine) }
                }
            }
            launched[machine] = child
            startedAt[machine] = Date()
            Self.diagnostic("vm launch started, pid \(child.processIdentifier)")
            Task { [weak self] in
                let status = await child.wait()
                Self.diagnostic("vm launch pid \(child.processIdentifier) exited with status \(status)")
                guard let self else {
                    return
                }
                if launched[machine] === child {
                    launched[machine] = nil
                    startedAt[machine] = nil
                    VPhoneLaunchpadConsoleLog.append(VPhoneLaunchpadConsoleLog.exitLine(status: status), to: log)
                }
                await refresh()
            }
        } catch {
            actionError = VPhoneLaunchpadError(
                String(localized: "Unable to Start \(machine.name)"), detail: error.localizedDescription)
        }
    }

    /// `vm stop <name> --library-root <root>`, which finds and signals the
    /// machine's VM process itself. Afterwards, and only when a `vm launch`
    /// this Launchpad started for the machine is still running, that child
    /// gets SIGINT. No other process is signalled from here.
    public func stop(_ machine: Path) async {
        guard let commandLine, activities[machine] == nil else {
            return
        }
        activities[machine] = String(localized: "Stopping…")
        defer { activities[machine] = nil }
        do {
            let result = try await commandLine.run(["vm", "stop", machine.name] + machine.libraryArguments)
            if !result.succeeded {
                actionError = VPhoneLaunchpadError(String(localized: "Unable to Stop \(machine.name)"), detail: result.tail)
            }
        } catch {
            actionError = VPhoneLaunchpadError(
                String(localized: "Unable to Stop \(machine.name)"), detail: error.localizedDescription)
        }
        launched[machine]?.interrupt()
        await refresh()
    }

    // MARK: - Edits

    /// `vm config` for each machine, with only the edited fields, so values
    /// the machines do not share are left alone.
    public func configure(_ machines: [Path], _ settings: VPhoneLaunchpadEditCommand.Settings) async {
        for machine in machines {
            await perform(String(localized: "Saving settings…"), on: machine,
                          VPhoneLaunchpadEditCommand.config(machine, settings),
                          failure: String(localized: "Unable to Save Settings for \(machine.name)"))
        }
    }

    public func rename(_ machine: Path, to newName: String) async {
        let renamed = await perform(String(localized: "Renaming…"), on: machine,
                                    VPhoneLaunchpadEditCommand.rename(machine, to: newName),
                                    failure: String(localized: "Unable to Rename \(machine.name)"))
        if renamed {
            selection = [Path(libraryRoot: machine.libraryRoot, name: newName)]
        }
    }

    public func clone(_ machine: Path, as newName: String) async {
        let cloned = await perform(String(localized: "Cloning…"), on: machine,
                                   VPhoneLaunchpadEditCommand.clone(machine, as: newName),
                                   failure: String(localized: "Unable to Clone \(machine.name)"))
        if cloned {
            selection = [Path(libraryRoot: machine.libraryRoot, name: newName)]
        }
    }

    /// `vm delete --force` for each machine, after the confirmation sheet.
    /// Launchpad removes no file itself.
    public func delete(_ machines: [Path]) async {
        for machine in machines {
            await perform(String(localized: "Deleting…"), on: machine,
                          VPhoneLaunchpadEditCommand.delete(machine),
                          failure: String(localized: "Unable to Delete \(machine.name)"))
        }
    }

    /// Imports an archive into the default library under its own name.
    public func importArchive(_ archive: URL) async {
        await perform(String(localized: "Importing \(archive.lastPathComponent)…"), on: nil,
                      VPhoneLaunchpadEditCommand.importArchive(archive, into: libraryRoot),
                      failure: String(localized: "Unable to Import \(archive.lastPathComponent)"))
    }

    // MARK: - Export

    /// An export queued or under way. `task` is nil while it waits its turn.
    public struct Export {
        public let destination: URL
        public fileprivate(set) var startedAt: Date?
        fileprivate var task: Task<Void, Never>?

        public var isWaiting: Bool {
            task == nil
        }

        public var isRunning: Bool {
            task != nil
        }
    }

    public private(set) var exports: [Path: Export] = [:]

    /// Exports each machine to its destination file, one at a time: each
    /// export reads a whole disk image. Without `replacing`, a destination
    /// that already exists is refused for that machine (a folder chosen for
    /// several machines); with it, the user has agreed to replace the file
    /// (the save panel asked).
    public func export(
        _ items: [(machine: Path, destination: URL)], densest: Bool, includeIPSW: Bool, replacing: Bool
    ) async {
        var queued: [(machine: Path, destination: URL)] = []
        for item in items where exports[item.machine] == nil {
            if !replacing, VPhoneLaunchpadExportOutput.exists(item.destination) {
                actionError = VPhoneLaunchpadError(
                    String(localized: "Unable to Export \(item.machine.name)"),
                    detail: String(localized: "\(item.destination.path) already exists."))
                continue
            }
            exports[item.machine] = Export(destination: item.destination)
            queued.append(item)
        }
        for item in queued {
            // Cancelled while it waited.
            guard exports[item.machine] != nil else {
                continue
            }
            let task = Task {
                await runExport(item.machine, to: item.destination, densest: densest, includeIPSW: includeIPSW)
            }
            exports[item.machine]?.task = task
            exports[item.machine]?.startedAt = Date()
            await task.value
            exports[item.machine] = nil
        }
    }

    /// Stops an export under way (SIGINT to its `vm export` child), or takes
    /// a waiting one out of the queue.
    public func cancelExport(_ machine: Path) {
        guard let export = exports[machine] else {
            return
        }
        if let task = export.task {
            task.cancel()
        } else {
            exports[machine] = nil
        }
    }

    private func runExport(_ machine: Path, to destination: URL, densest: Bool, includeIPSW: Bool) async {
        let existedBefore = VPhoneLaunchpadExportOutput.exists(destination)
        await perform(String(localized: "Exporting…"), on: machine,
                      VPhoneLaunchpadEditCommand.export(machine, to: destination, densest: densest, includeIPSW: includeIPSW),
                      failure: String(localized: "Unable to Export \(machine.name)"))
        // `vm export` writes the archive in place, so a cancelled one leaves
        // a partial file behind. Only a file this export created is removed.
        if Task.isCancelled {
            VPhoneLaunchpadExportOutput.removeCancelled(destination, existedBefore: existedBefore)
        }
    }

    // MARK: - Running edits

    /// Import's activity, which belongs to no machine.
    public private(set) var globalActivity: String?

    /// Runs one edit command with `activity` shown in place of the machine's
    /// state. A failure is reported with `failure` as the title and the
    /// output's last lines, where `vphone-cli` names the reason (a held
    /// bundle lock reads `VM '<name>' is busy: ...`). A cancelled command is
    /// not reported. False unless the command ran and exited 0.
    @discardableResult
    private func perform(
        _ activity: String, on machine: Path?, _ command: VPhoneLaunchpadEditCommand?, failure: String
    ) async -> Bool {
        guard let commandLine else {
            return false
        }
        guard let command else {
            actionError = VPhoneLaunchpadError(failure, detail: String(localized: "Launchpad cannot pass this name or path to vphone-cli."))
            return false
        }
        if let machine, activities[machine] != nil {
            return false
        }
        if let machine {
            activities[machine] = activity
        } else {
            globalActivity = activity
        }
        defer {
            if let machine {
                activities[machine] = nil
            } else {
                globalActivity = nil
            }
        }
        var succeeded = false
        do {
            let result = try await commandLine.run(command)
            succeeded = result.succeeded && !Task.isCancelled
            if !result.succeeded, !Task.isCancelled {
                actionError = VPhoneLaunchpadError(failure, detail: result.tail)
            }
        } catch {
            actionError = VPhoneLaunchpadError(failure, detail: error.localizedDescription)
        }
        // A new task: a cancelled export's own cancellation would interrupt
        // the `vm list` children of this refresh.
        await Task { await self.refresh() }.value
        return succeeded
    }

    // MARK: - Diagnostics

    /// One unbuffered stdout line for smoke checks. Never carries a machine
    /// name or path.
    nonisolated static func diagnostic(_ text: String) {
        FileHandle.standardOutput.write(Data("[launchpad] \(text)\n".utf8))
    }
}
