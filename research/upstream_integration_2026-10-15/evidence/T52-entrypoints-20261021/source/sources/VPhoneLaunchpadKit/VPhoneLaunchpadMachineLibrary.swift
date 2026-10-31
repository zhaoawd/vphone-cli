import Foundation
import Observation
import VPhoneCore

/// The VM library, listed through `vphone-cli vm list --json`, started with
/// `vm launch`, stopped with `vm stop`, edited offline with `vm config`,
/// `rename`, `clone`, `delete`, `export` and `import`, and created with
/// `vm create` (`VPhoneLaunchpadCreation`). State polling takes no VM lock.
/// Changed-file disk measurements briefly hold a shared directory lease;
/// `vphone-vm` and mutation CLIs take exclusive locks.
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
    public private(set) var diskUsage: [Path: VPhoneLaunchpadDiskUsage] = [:]
    private let diskMeter = VPhoneLaunchpadDiskMeter()
    private var nextDiskMeasurement: ContinuousClock.Instant?
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
    /// Create runs and the checkpoints shown for them, by machine
    /// (`VPhoneLaunchpadCreation.swift`).
    public internal(set) var creations: [Path: VPhoneLaunchpadCreation] = [:]

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
        commandLine != nil && activities[machine] == nil && exports[machine] == nil
            && creations[machine]?.isRunning != true && state(of: machine) == .stopped
    }

    /// The command line monitoring was started with; nil until the embedded
    /// toolchain is verified.
    var currentCommandLine: VPhoneLaunchpadCommandLine? {
        commandLine
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
        if creations[machine]?.isRunning == true {
            return String(localized: "Creating…")
        }
        return nil
    }

    /// True while `vm export` runs. Older CLIs retain indeterminate progress.
    public func isExporting(_ machine: Path) -> Bool {
        exports[machine]?.isRunning == true
    }

    /// Not while a create run of this Launchpad uses the machine: its DFU
    /// and first boots are the create's own; Stop Creating ends them.
    public func canStop(_ machine: Path) -> Bool {
        commandLine != nil && activities[machine] == nil && creations[machine]?.isRunning != true
            && state(of: machine).isRunning
    }

    /// The `vm launch` child this Launchpad holds for `machine`, until it exits.
    func launchedProcess(_ machine: Path) -> VPhoneLaunchpadChildProcess? {
        launched[machine]
    }

    /// The machine's console log. Every start from Launchpad first renames
    /// the previous one to `<stem>.1.log` (`VPhoneLaunchpadConsoleLog.rotate`),
    /// then writes a new one here.
    public func consoleLog(_ machine: Path, suffix: String = "") -> URL {
        VPhoneLaunchpadMachineLocations.consoleLog(
            machine, suffix: suffix, defaultRoot: libraryRoot, logsDirectory: logsDirectory)
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
        await refreshDiskUsage()
        if lastReportedCount != machines.count {
            lastReportedCount = machines.count
            // Diagnostic line for the smoke check, written unbuffered; machine
            // names are not printed.
            Self.diagnostic("listed \(machines.count) machines from \(roots.count) libraries")
        }
    }

    private func mayMeasureDisk(_ machine: Path) -> Bool {
        VPhoneLaunchpadDiskAccess(
            isLaunched: launched[machine]?.isRunning == true,
            isHeld: runStates[machine] != .stopped,
            isBusy: activities[machine] != nil || exports[machine] != nil || creations[machine]?.isRunning == true,
            isLibraryBusy: !imports.isEmpty || globalActivity != nil || listError != nil
        ).mayOpen
    }

    private func refreshDiskUsage() async {
        let now = ContinuousClock.now
        guard nextDiskMeasurement.map({ now >= $0 }) ?? true else { return }
        nextDiskMeasurement = now + .seconds(30)
        var folders: [VPhoneLaunchpadDiskMeter.Folder] = []
        var stateFiles: [String: Set<String>] = [:]
        let paths = Dictionary(uniqueKeysWithValues: machines.map { ($0.path.url.path, $0.path) })
        for machine in machines {
            if let manifest = try? VPhoneVirtualMachineManifest.load(from: machine.path.configURL) {
                stateFiles[machine.path.url.path] = Set([manifest.diskImage, manifest.sepStorage, manifest.nvramStorage])
            }
            var allowed = mayMeasureDisk(machine.path)
            if allowed {
                let path = machine.path
                allowed = await Task.detached {
                    guard let manifest = try? VPhoneVirtualMachineManifest.load(from: path.configURL),
                          let holders = try? VPhoneLaunchpadDiskHolders.read(path.url.appendingPathComponent(manifest.diskImage)) else { return false }
                    return holders.isEmpty
                }.value
            }
            folders.append(.init(path: machine.path.url.path, mayOpen: allowed))
        }
        let measured = await diskMeter.measure(folders, mayOpenNow: { [weak self] path in
            guard let machine = paths[path] else { return false }
            return await self?.mayMeasureDiskNow(machine) == true
        }, mayMapNow: { [weak self, stateFiles] path, file in
            guard let machine = paths[path] else { return false }
            // A non-cooperating reader need not take our directory lease.
            // Recheck holders immediately before mapping a VM state file.
            if stateFiles[path]?.contains(URL(fileURLWithPath: file).lastPathComponent) != false {
                return await self?.mayMeasureDiskNow(machine) == true
            }
            return await self?.mayMeasureDisk(machine) == true
        })
        diskUsage = Dictionary(uniqueKeysWithValues: measured.compactMap { path, usage in
            paths[path].map { ($0, usage) }
        })
    }

    private func mayMeasureDiskNow(_ machine: Path) async -> Bool {
        guard mayMeasureDisk(machine) else { return false }
        let clear = await Task.detached {
            guard let manifest = try? VPhoneVirtualMachineManifest.load(from: machine.configURL),
                  let holders = try? VPhoneLaunchpadDiskHolders.read(machine.url.appendingPathComponent(manifest.diskImage)) else { return false }
            return holders.isEmpty
        }.value
        return clear && mayMeasureDisk(machine)
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
        // Keep one earlier run. A failure does not stop the start; its
        // reason opens the new log, where the console shows it.
        let others = Set(machines.map(\.path).filter { $0 != machine }.map { consoleLog($0) })
        var preamble: String?
        if case let .failed(reason) = VPhoneLaunchpadConsoleLog.rotate(log, in: logsDirectory, reserved: others) {
            preamble = VPhoneLaunchpadConsoleLog.rotationFailureLine(reason) + "\n"
        }
        panicked.remove(machine)
        do {
            let child = try commandLine.start(arguments, logFile: log, preamble: preamble, machine: machine.url) { [weak self] line in
                if VPhoneLaunchpadConsoleLog.isPanic(line) {
                    Task { @MainActor in self?.panicked.insert(machine) }
                }
            }
            launched[machine] = child
            startedAt[machine] = Date()
            Self.diagnostic("vm launch started, pid \(child.processIdentifier)")
            Task { [weak self] in
                let completion = await child.waitForCompletion()
                let status = completion.status
                Self.diagnostic("vm launch pid \(child.processIdentifier) exited with status \(status)")
                guard let self else {
                    return
                }
                if launched[machine] === child {
                    launched[machine] = nil
                    startedAt[machine] = nil
                    let line = VPhoneLaunchpadConsoleLog.exitLine(status: status)
                        + (completion.outputDrained ? "" : " (console read failed; output completeness unknown)")
                    VPhoneLaunchpadConsoleLog.append(line, to: log)
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
            } else {
                // Only cancel our launch wrapper after the CLI confirmed Stop.
                // A refusal (for example an active update) must not be bypassed.
                launched[machine]?.interrupt()
            }
        } catch {
            actionError = VPhoneLaunchpadError(
                String(localized: "Unable to Stop \(machine.name)"), detail: error.localizedDescription)
        }
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

    public func clone(_ machine: Path, as newName: String, newIdentity: Bool = false) async {
        let cloned = await perform(String(localized: "Cloning…"), on: machine,
                                   VPhoneLaunchpadEditCommand.clone(machine, as: newName, newIdentity: newIdentity),
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

    /// Rebind through the embedded CLI, which owns verification, backup and
    /// the stopped VM lock. Environment replacement uses the new binding.
    @discardableResult
    public func setBundle(
        _ machine: Path, version: String, backup: URL? = nil,
        updateEnvironment: Bool = false,
        workParent: URL? = nil,
        expectedBindingSHA256: String? = nil,
        willUpdate: (@MainActor () -> Void)? = nil
    ) async -> VPhoneLaunchpadBundleChange? {
        guard let commandLine, commandLine.acceptsNewCommands, canEdit(machine),
              let bindingArguments = VPhoneLaunchpadBundleChange.bindingArguments(machine, version: version, backup: backup, expectedSHA256: expectedBindingSHA256),
              let environmentArguments = VPhoneLaunchpadBundleChange.environmentArguments(machine, workParent: workParent) else { return nil }
        activities[machine] = String(localized: "Changing Core Bundle…")
        defer { activities[machine] = nil }
        var didBind = false
        do {
            let result = try await VPhoneLaunchpadBundleChange.perform(
                updatesEnvironment: updateEnvironment,
                diskHolders: {
                    let manifest = try VPhoneVirtualMachineManifest.load(from: machine.configURL)
                    let disk = machine.url.appendingPathComponent(manifest.diskImage)
                    return try await Task.detached { try VPhoneLaunchpadDiskHolders.read(disk) }.value
                },
                bind: {
                    let bound = try await commandLine.run(bindingArguments)
                    guard bound.succeeded else { throw VPhoneLaunchpadError("Core Bundle change refused", detail: bound.tail) }
                    didBind = true
                },
                updateEnvironment: {
                    guard let selected = try VPhoneMachineBinding.snapshot(machine.url), selected.binding.bundle == version else {
                        throw VPhoneLaunchpadError("VM binding changed after publication; inspect it before retrying")
                    }
                    let updated = try await commandLine.run(
                        environmentArguments,
                        machine: machine.url, onStart: willUpdate, expectedBindingSHA256: selected.sha256)
                    if !updated.succeeded {
                        actionError = VPhoneLaunchpadError("Unable to Update Guest Environment", detail:
                            "\(machine.name): host binding was saved as \(version), but its guest environment update did not complete.\n" + updated.tail)
                    }
                    return updated.succeeded
                })
            if case let .refused(holders) = result {
                actionError = VPhoneLaunchpadError("Core Bundle Change Refused", detail:
                    VPhoneProcessHolder.diskRefusal(holders, rerun: "change the Core Bundle again"))
            }
            await refresh()
            return result
        } catch {
            let prefix = didBind ? "\(machine.name): host binding was saved as \(version), but its guest environment update did not complete.\n" : ""
            let cause = (error as? VPhoneLaunchpadError)?.detail ?? error.localizedDescription
            actionError = VPhoneLaunchpadError("Unable to Change Core Bundle", detail: prefix + cause)
            await refresh()
            return didBind ? .boundButNotUpdated : nil
        }
    }

    // MARK: - Import

    public struct Import: Identifiable, Sendable {
        public enum State: Sendable {
            case waiting, running, cancelling
        }

        public let id = UUID()
        public let archive: URL
        public fileprivate(set) var progress: VPhoneTransferProgress?
        public fileprivate(set) var state = State.waiting
        fileprivate let selectionID: UUID
    }

    private let importQueue = VPhoneLaunchpadTransferQueue()
    private var importTasks: [UUID: Task<Bool, Never>] = [:]
    public private(set) var imports: [Import] = []

    /// Imports an archive into the default library under its own name.
    public func importArchive(_ archive: URL) async {
        await importArchives([archive])
    }

    /// Each selection runs in arrival order. Failure or caller cancellation
    /// stops its selection; cancelling one row skips only that item.
    public func importArchives(_ archives: [URL]) async {
        guard !archives.isEmpty, !Task.isCancelled, commandLine?.acceptsNewCommands == true else { return }
        let id = UUID()
        let items = archives.map { Import(archive: $0, selectionID: id) }
        imports += items
        defer { imports.removeAll { $0.selectionID == id } }
        await withTaskCancellationHandler {
            await runImports(items, selectionID: id)
        } onCancel: {
            Task { @MainActor [weak self] in
                for item in items { self?.cancelImport(item.id) }
            }
        }
    }

    private func runImports(_ items: [Import], selectionID: UUID) async {
        guard let id = await importQueue.acquire(selectionID) else { return }
        defer { importQueue.release(id) }
        for item in items {
            guard !Task.isCancelled, commandLine?.acceptsNewCommands == true else { return }
            guard let index = imports.firstIndex(where: { $0.id == item.id }) else { continue }
            imports[index].state = .running
            let task = Task {
                guard !Task.isCancelled else { return false }
                return await perform(String(localized: "Importing \(item.archive.lastPathComponent)…"), on: nil,
                                     VPhoneLaunchpadEditCommand.importArchive(item.archive, into: libraryRoot),
                                     failure: String(localized: "Unable to Import \(item.archive.lastPathComponent)"), onProgress: { [weak self] progress in
                                         guard let self, let index = self.imports.firstIndex(where: { $0.id == item.id }) else { return }
                                         self.imports[index].progress = progress
                                     })
            }
            importTasks[item.id] = task
            let succeeded = await task.value
            importTasks[item.id] = nil
            imports.removeAll { $0.id == item.id }
            // A per-item cancel skips that item; a caller cancellation or
            // failure still stops the rest of its selection.
            guard succeeded || task.isCancelled else { return }
        }
    }

    public func cancelImport(_ id: UUID) {
        guard let index = imports.firstIndex(where: { $0.id == id }) else { return }
        if let task = importTasks[id] {
            imports[index].state = .cancelling
            task.cancel()
        } else {
            let selectionID = imports.remove(at: index).selectionID
            if !imports.contains(where: { $0.selectionID == selectionID }) {
                importQueue.cancelWaiting(selectionID)
            }
        }
    }

    // MARK: - Export

    /// An export queued or under way. `task` is nil while it waits its turn.
    public struct Export {
        public let destination: URL
        public fileprivate(set) var progress: VPhoneTransferProgress?
        fileprivate let selectionID: UUID
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
    private let exportQueue = VPhoneLaunchpadTransferQueue()

    /// Exports each machine to its destination file, one at a time: each
    /// export reads a whole disk image. Existing destinations are refused,
    /// including when a legacy caller passes `replacing: true`. A save-panel
    /// confirmation cannot make an older CLI publish transactionally.
    public func export(
        _ items: [(machine: Path, destination: URL)], densest: Bool, includeIPSW: Bool, replacing _: Bool
    ) async {
        guard !Task.isCancelled, commandLine?.acceptsNewCommands == true else { return }
        let selectionID = UUID()
        var queued: [(machine: Path, destination: URL)] = []
        for item in items where exports[item.machine] == nil {
            if VPhoneLaunchpadExportOutput.exists(item.destination) {
                actionError = VPhoneLaunchpadError(
                    String(localized: "Unable to Export \(item.machine.name)"),
                    detail: String(localized: "\(item.destination.path) already exists."))
                continue
            }
            exports[item.machine] = Export(destination: item.destination, selectionID: selectionID)
            queued.append(item)
        }
        guard !queued.isEmpty else { return }
        let selection = queued
        defer { exports = exports.filter { $0.value.selectionID != selectionID } }
        await withTaskCancellationHandler {
            guard let token = await exportQueue.acquire(selectionID) else { return }
            defer { exportQueue.release(token) }
            for item in selection {
                guard !Task.isCancelled, commandLine?.acceptsNewCommands == true else { return }
                // Per-item cancellation skips this item while keeping its selection.
                guard exports[item.machine]?.selectionID == selectionID else { continue }
                let task = Task {
                    guard !Task.isCancelled else { return }
                    await runExport(item.machine, to: item.destination, densest: densest, includeIPSW: includeIPSW)
                }
                exports[item.machine]?.task = task
                exports[item.machine]?.startedAt = Date()
                await task.value
                exports[item.machine] = nil
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                for item in selection where self?.exports[item.machine]?.selectionID == selectionID {
                    self?.cancelExport(item.machine)
                }
            }
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
            if !exports.values.contains(where: { $0.selectionID == export.selectionID }) {
                exportQueue.cancelWaiting(export.selectionID)
            }
        }
    }

    public var hasActiveTransfers: Bool { !imports.isEmpty || !exports.isEmpty }

    /// Call after closing the command gate. Waiting items disappear without
    /// starting children; active tasks retain their rows until output drains.
    public func cancelTransfers() {
        for item in imports { cancelImport(item.id) }
        for machine in Array(exports.keys) { cancelExport(machine) }
    }

    private func runExport(_ machine: Path, to destination: URL, densest: Bool, includeIPSW: Bool) async {
        await perform(String(localized: "Exporting…"), on: machine,
                      VPhoneLaunchpadEditCommand.export(machine, to: destination, densest: densest, includeIPSW: includeIPSW),
                      failure: String(localized: "Unable to Export \(machine.name)"), onProgress: { [weak self] progress in
                          self?.exports[machine]?.progress = progress
                      })
        // The CLI owns its private staging cleanup. A final-path file may be
        // committed output or another writer's file; cancellation proves neither
        // ownership nor incompleteness. Keep legacy CLI leftovers as well.
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
        _ activity: String, on machine: Path?, _ command: VPhoneLaunchpadEditCommand?, failure: String,
        onProgress: (@MainActor (VPhoneTransferProgress) -> Void)? = nil
    ) async -> Bool {
        guard let commandLine else {
            return false
        }
        guard let command else {
            actionError = VPhoneLaunchpadError(failure, detail: String(localized: "Launchpad cannot pass this name or path to vphone-cli."))
            return false
        }
        if let machine, activities[machine] != nil { return false }
        if machine == nil, globalActivity != nil { return false }
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
            let result = try await commandLine.run(command, onProgress: onProgress)
            succeeded = result.succeeded && !Task.isCancelled
            if !result.succeeded, !Task.isCancelled {
                actionError = VPhoneLaunchpadError(failure, detail: result.tail)
            }
        } catch {
            if !Task.isCancelled {
                actionError = VPhoneLaunchpadError(failure, detail: error.localizedDescription)
            }
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

/// FIFO ownership spans a complete selection and the active child's output drain.
@MainActor
private final class VPhoneLaunchpadTransferQueue {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<UUID?, Never>
    }
    private var active: UUID?
    private var waiting: [Waiter] = []

    func acquire(_ id: UUID) async -> UUID? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: nil); return }
                if active == nil {
                    active = id
                    continuation.resume(returning: id)
                } else {
                    waiting.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiting(id) }
        }
    }

    func cancelWaiting(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(returning: nil)
    }

    func release(_ id: UUID) {
        guard active == id else { return }
        active = nil
        if !waiting.isEmpty {
            let next = waiting.removeFirst()
            active = next.id
            next.continuation.resume(returning: next.id)
        }
    }
}
