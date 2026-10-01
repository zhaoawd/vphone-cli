import AppKit
import SwiftUI
import VPhoneLaunchpadKit

// MARK: - Machines

/// The machine list: search, column sorting, an empty state, the inspector,
/// start and stop, the console, the offline edits of B3 (settings, rename,
/// clone, export, import and delete), and New Machine with its creation view
/// (B4), each through `vphone-cli`.
struct VPhoneLaunchpadMachinesView: View {
    typealias MachinePath = VPhoneLaunchpadMachinePath

    enum Sheet: Identifiable {
        case settings([VPhoneLaunchpadMachine])
        case rename(MachinePath)
        case clone(MachinePath)
        case export([MachinePath])
        case delete([MachinePath])
        case console(MachinePath)
        case newMachine
        case creation(MachinePath)

        var id: String {
            switch self {
            case let .settings(machines): "settings-\(machines.map(\.path.url.path).joined(separator: "|"))"
            case let .rename(machine): "rename-\(machine.url.path)"
            case let .clone(machine): "clone-\(machine.url.path)"
            case let .export(machines): "export-\(machines.map(\.url.path).joined(separator: "|"))"
            case let .delete(machines): "delete-\(machines.map(\.url.path).joined(separator: "|"))"
            case let .console(machine): "console-\(machine.url.path)"
            case .newMachine: "new-machine"
            case let .creation(machine): "creation-\(machine.url.path)"
            }
        }
    }

    @Environment(VPhoneLaunchpadModel.self) private var model
    @State private var filter = ""
    /// Empty keeps the order `vm list` returns; a header click replaces it.
    @State private var sortOrder: [KeyPathComparator<VPhoneLaunchpadMachine>] = []
    @State private var showsInspector = true
    @State private var sheet: Sheet?
    /// Opened after the current sheet has gone (New Machine hands off to the
    /// creation view), on the next turn of the main actor, as the panel
    /// queue does (upstream `ded81cb`).
    @State private var nextSheet: Sheet?
    /// The table appears only once `vm list` returns, after the window has
    /// picked its first responder, so nothing focuses it by itself.
    @FocusState private var tableIsFocused: Bool

    private var library: VPhoneLaunchpadMachineLibrary {
        model.machines
    }

    /// The machines the table shows: those matching the search, in the
    /// header's order.
    private var rows: [VPhoneLaunchpadMachine] {
        let needle = filter.trimmingCharacters(in: .whitespaces)
        let matching = needle.isEmpty ? library.machines : library.machines.filter { Self.matches($0, needle) }
        return matching.sorted(using: sortOrder)
    }

    private var minimumWidth: CGFloat {
        Column.tableWidth(spansLibraries: library.spansLibraries) + (showsInspector ? Column.inspector : 0)
    }

    var body: some View {
        @Bindable var library = library
        Group {
            if library.machines.isEmpty {
                emptyState
            } else if rows.isEmpty {
                ContentUnavailableView.search(text: filter)
            } else {
                table(selection: $library.selection)
            }
        }
        // At least as wide as the columns (B2: with the inspector open the
        // table scrolled sideways and cut off Disk).
        .frame(minWidth: Column.tableWidth(spansLibraries: library.spansLibraries))
        // A hidden machine stays out of the selection, so Start, Stop and the
        // inspector act only on rows the table shows.
        .onChange(of: filter) {
            let visible = Set(rows.map(\.path))
            library.selection.formIntersection(visible)
        }
        .inspector(isPresented: $showsInspector) {
            Group {
                if let machine = library.selected {
                    VPhoneLaunchpadMachineInspector(machine: machine) { path in
                        sheet = .console(path)
                    } onOpenCreation: { path in
                        sheet = .creation(path)
                    }
                } else if library.selection.count > 1 {
                    ContentUnavailableView("\(library.selection.count) Machines Selected", systemImage: "iphone")
                } else {
                    ContentUnavailableView("No Selection", systemImage: "iphone")
                }
            }
            .inspectorColumnWidth(min: Column.inspector, ideal: 360, max: 520)
            .fontDesign(.monospaced)
            // The toggle belongs to the inspector's own toolbar section.
            .toolbar { inspectorToolbar }
        }
        // The window's minimum is the columns plus the inspector, and a
        // narrower window grows to it.
        .preference(key: VPhoneLaunchpadMinimumWidthKey.self, value: minimumWidth)
        .background(VPhoneLaunchpadWindowMinimumWidth(width: minimumWidth))
        .toolbar { toolbar }
        .sheet(item: $sheet, onDismiss: sheetDidDismiss) { sheet in
            sheetContent(sheet)
                .environment(model)
        }
        .task(id: library.hasListed) {
            openRequestedSheet()
        }
        .alert(
            library.actionError?.message ?? "",
            isPresented: Binding(get: { library.actionError != nil }, set: {
                if !$0 {
                    library.actionError = nil
                }
            }),
            presenting: library.actionError
        ) { _ in
            Button("OK") {}
        } message: { error in
            Text(verbatim: error.detail ?? "")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Spacer()
        }
        if let activity = library.globalActivity {
            ToolbarItem(placement: .automatic) {
                Label {
                    Text(verbatim: activity)
                } icon: {
                    VPhoneLaunchpadStatusIcon(status: .running)
                }
                .labelStyle(.titleAndIcon)
            }
        }
        ToolbarItem(placement: .automatic) {
            Button {
                sheet = .newMachine
            } label: {
                Label("New Machine…", systemImage: "plus")
            }
            .help("Create a machine with vphone-cli vm create")
        }
        ToolbarItem(placement: .automatic) {
            Button {
                chooseImport()
            } label: {
                Label("Import…", systemImage: "square.and.arrow.down")
            }
            .help("Import a machine archive into the default library")
            .disabled(library.globalActivity != nil)
        }
        ToolbarItem(placement: .automatic) {
            VPhoneLaunchpadSearchField(text: $filter, prompt: String(localized: "Search machines"))
                .frame(width: 200)
        }
    }

    /// The inspector toggle, then Start or Stop for the selection beside the
    /// actions menu. Those two go away with the inspector; the context menu
    /// and a double-click still reach them.
    @ToolbarContentBuilder
    private var inspectorToolbar: some ToolbarContent {
        let selected = library.selectedMachines
        let startable = selected.filter { library.canStart($0.path) }
        let stoppable = selected.filter { library.canStop($0.path) }
        ToolbarItem(placement: .automatic) {
            Button {
                showsInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help(showsInspector ? Text("Hide the inspector") : Text("Show the inspector"))
        }
        if showsInspector {
            ToolbarItem(placement: .automatic) {
                Spacer()
            }
            ToolbarItemGroup(placement: .automatic) {
                if startable.isEmpty, !stoppable.isEmpty {
                    Button {
                        stop(stoppable)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help("Stop the selected machine")
                } else {
                    Button {
                        start(startable)
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .help("Start the selected machine")
                    .disabled(startable.isEmpty)
                }
                Menu {
                    machineActions(selected)
                } label: {
                    Label("Actions", systemImage: "ellipsis")
                }
                .disabled(selected.isEmpty)
                .menuIndicator(.hidden)
            }
        }
    }

    private func start(_ machines: [VPhoneLaunchpadMachine], headless: Bool = false) {
        for machine in machines {
            library.start(machine.path, headless: headless)
        }
    }

    private func stop(_ machines: [VPhoneLaunchpadMachine]) {
        let library = library
        Task {
            await withTaskGroup(of: Void.self) { group in
                for machine in machines {
                    group.addTask { await library.stop(machine.path) }
                }
            }
        }
    }

    /// The same actions in the toolbar menu and the table's context menu.
    /// Settings, export and delete take several machines, and need every one
    /// of them stopped and idle; rename and clone take one. The CLI still
    /// decides: a machine whose bundle lock is held is refused, and the
    /// refusal is shown.
    @ViewBuilder
    private func machineActions(_ machines: [VPhoneLaunchpadMachine]) -> some View {
        let startable = machines.filter { library.canStart($0.path) }
        let stoppable = machines.filter { library.canStop($0.path) }
        let editable = !machines.isEmpty && machines.allSatisfy { library.canEdit($0.path) }
        // Only while one of them is exporting or waiting to.
        let exporting = machines.filter { library.exports[$0.path] != nil }
        if !exporting.isEmpty {
            Button("Cancel Export") {
                for machine in exporting {
                    library.cancelExport(machine.path)
                }
            }
            Divider()
        }
        Button("Start") { start(startable) }
            .disabled(startable.isEmpty)
        Button("Start Headless") { start(startable, headless: true) }
            .disabled(startable.isEmpty)
        Button("Stop") { stop(stoppable) }
            .disabled(stoppable.isEmpty)
        Divider()
        Button("Settings…") { sheet = .settings(machines) }
            .disabled(!editable)
        if machines.count == 1, let machine = machines.first {
            Button("Rename…") { sheet = .rename(machine.path) }
                .disabled(!editable)
            Button("Clone…") { sheet = .clone(machine.path) }
                .disabled(!editable)
        }
        Button("Export…") { sheet = .export(machines.map(\.path)) }
            .disabled(!editable)
        if machines.count == 1, let machine = machines.first, library.creations[machine.path] != nil {
            Button("Show Creation…") { sheet = .creation(machine.path) }
        }
        Divider()
        if machines.count == 1, let machine = machines.first {
            Button("Open Console") { sheet = .console(machine.path) }
            Button("Show Console Log in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([library.consoleLog(machine.path)])
            }
            .disabled(!FileManager.default.fileExists(atPath: library.consoleLog(machine.path).path))
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(machines.map(\.path.url))
        }
        Divider()
        Button("Delete…", role: .destructive) { sheet = .delete(machines.map(\.path)) }
            .disabled(!editable)
    }

    // MARK: - Table

    private func table(selection: Binding<Set<MachinePath>>) -> some View {
        Table(rows, selection: selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name)
                .width(min: 80, ideal: Column.name)
            if library.spansLibraries {
                TableColumn("Location", value: \.libraryRoot) { machine in
                    Text(verbatim: VPhoneLaunchpadMachineLocations.volumeName(machine.libraryRoot))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(Text(verbatim: VPhoneLaunchpadMachineLocations.abbreviated(
                            URL(fileURLWithPath: machine.libraryRoot, isDirectory: true))))
                }
                .width(min: 70, ideal: Column.location)
            }
            TableColumn("iOS", value: \.iosVersion) { machine in
                Text(verbatim: machine.restoreInfo.map { "\($0.ios.version) (\($0.ios.build))" } ?? "—")
            }
            .width(min: 100, ideal: Column.ios)
            TableColumn("State") { machine in
                VPhoneLaunchpadMachineStateLabel(
                    state: library.state(of: machine.path),
                    activity: library.activity(of: machine.path),
                    panicked: library.panicked.contains(machine.path),
                    indeterminate: library.isExporting(machine.path)
                )
            }
            .width(min: 120, ideal: Column.state)
            TableColumn("CPU", value: \.cpuCount) { machine in
                Text(verbatim: "\(machine.cpuCount)").monospacedDigit()
            }
            .width(Column.cpu)
            TableColumn("Memory", value: \.memoryMB) { machine in
                Text(verbatim: Self.memory(machine.memoryMB)).monospacedDigit()
            }
            .width(Column.memory)
            TableColumn("Disk", value: \.diskSizeBytes) { machine in
                Text(verbatim: Self.disk(machine.diskSizeBytes)).monospacedDigit()
            }
            .width(Column.disk)
        }
        .contextMenu(forSelectionType: MachinePath.self) { paths in
            machineActions(library.machines.filter { paths.contains($0.path) })
        } primaryAction: { paths in
            start(library.machines.filter { paths.contains($0.path) && library.canStart($0.path) })
        }
        .scrollContentBackground(.hidden)
        .background(VPhoneLaunchpadTheme.background)
        .focused($tableIsFocused)
        .onAppear {
            // The table comes back when a search matches again; the search
            // field keeps the keyboard then.
            if !(NSApp.keyWindow?.firstResponder is NSText) {
                tableIsFocused = true
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !library.hasListed {
            Color.clear
        } else {
            ContentUnavailableView {
                Label("No Machines", systemImage: "iphone")
            } description: {
                Text(library.listError ?? String(localized: "Machines in \(VPhoneLaunchpadMachineLocations.abbreviated(URL(fileURLWithPath: library.libraryRoot, isDirectory: true))) appear here."))
            } actions: {
                Button("New Machine…") { sheet = .newMachine }
                Button("Import…") { chooseImport() }
                    .disabled(library.globalActivity != nil)
            }
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: Sheet) -> some View {
        switch sheet {
        case let .settings(machines):
            VPhoneLaunchpadMachineSettingsView(machines: machines)
        case let .rename(path):
            VPhoneLaunchpadNameSheet(action: .rename, machine: path)
        case let .clone(path):
            VPhoneLaunchpadNameSheet(action: .clone, machine: path)
        case let .export(paths):
            VPhoneLaunchpadExportView(machines: paths)
        case let .delete(paths):
            VPhoneLaunchpadDeleteView(machines: paths)
        case let .console(path):
            VPhoneLaunchpadConsoleView(machine: path, url: library.consoleLog(path))
        case .newMachine:
            VPhoneLaunchpadNewMachineView { path in
                nextSheet = .creation(path)
            }
        case let .creation(path):
            VPhoneLaunchpadCreationView(creation: library.creation(for: path))
        }
    }

    private func sheetDidDismiss() {
        guard let next = nextSheet else {
            return
        }
        nextSheet = nil
        Task { @MainActor in
            sheet = next
        }
    }

    /// `vm import <archive> --library-root <default library>`; the machine
    /// keeps the archive's own name.
    private func chooseImport() {
        let library = library
        let panel = NSOpenPanel()
        panel.title = String(localized: "Import Machine")
        panel.message = String(localized: "Choose an exported machine archive (.tzst or .txz). It is imported into \(VPhoneLaunchpadMachineLocations.abbreviated(URL(fileURLWithPath: library.libraryRoot, isDirectory: true))).")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.present { url in
            Task { await library.importArchive(url) }
        }
    }

    /// Opens a sheet named on the command line (`-VPhoneLaunchpadOpenSheet
    /// settingsSheet|renameSheet|cloneSheet|exportSheet|deleteSheet|
    /// creationSheet|resumeSheet` for the first machine, `settingsAll`,
    /// `exportAll`, `deleteAll` for every listed machine, or `newMachine`,
    /// `newMachineAdvanced`) once machines are listed, for the UI smoke check.
    /// Only the arguments domain is read, so nothing persists. Opening a
    /// sheet starts no create: New Machine runs only `fw catalog --json`, and
    /// the creation view only reads the checkpoint file.
    private func openRequestedSheet() {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        guard library.hasListed, sheet == nil, let name = arguments["VPhoneLaunchpadOpenSheet"] as? String else {
            return
        }
        if name == "newMachine" || name == "newMachineAdvanced" {
            sheet = .newMachine
            return
        }
        guard let first = library.selected ?? library.machines.first else {
            return
        }
        let all = library.machines
        switch name {
        case "settingsSheet": sheet = .settings([first])
        case "renameSheet": sheet = .rename(first.path)
        case "cloneSheet": sheet = .clone(first.path)
        case "exportSheet": sheet = .export([first.path])
        case "deleteSheet": sheet = .delete([first.path])
        case "settingsAll": sheet = .settings(all)
        case "exportAll": sheet = .export(all.map(\.path))
        case "deleteAll": sheet = .delete(all.map(\.path))
        case "creationSheet", "resumeSheet": sheet = .creation(first.path)
        default: break
        }
    }

    // MARK: - Column widths

    /// The table lays its columns out at their ideal widths and scrolls
    /// sideways rather than shrink them (B2 screenshot at 1100 pt, B6
    /// baseline at 900 pt with the inspector open). The list therefore asks
    /// for at least the sum of those widths, and the window's minimum adds
    /// the inspector's, so the window grows instead of the table scrolling.
    enum Column {
        static let name: CGFloat = 110
        static let location: CGFloat = 90
        static let ios: CGFloat = 110
        static let state: CGFloat = 140
        static let cpu: CGFloat = 40
        static let memory: CGFloat = 72
        static let disk: CGFloat = 72
        /// The inspector column's minimum.
        static let inspector: CGFloat = 300
        /// Per column: the cell spacing measured in the B6 baseline
        /// screenshot (header text 127 pt apart for 110 pt columns).
        static let spacing: CGFloat = 17
        /// Leading and trailing inset around the columns.
        static let inset: CGFloat = 24

        static func tableWidth(spansLibraries: Bool) -> CGFloat {
            let widths = [name, ios, state, cpu, memory, disk] + (spansLibraries ? [location] : [])
            return widths.reduce(0, +) + spacing * CGFloat(widths.count) + inset
        }
    }

    // MARK: - Search

    private static func matches(_ machine: VPhoneLaunchpadMachine, _ needle: String) -> Bool {
        [
            machine.name,
            machine.restoreInfo?.ios.version,
            machine.restoreInfo?.ios.build,
            machine.udid,
            VPhoneLaunchpadMachineLocations.volumeName(machine.libraryRoot),
        ]
        .compactMap(\.self)
        .contains { $0.localizedCaseInsensitiveContains(needle) }
    }

    // MARK: - Formatting

    static func memory(_ megabytes: Int) -> String {
        megabytes % 1024 == 0 ? "\(megabytes / 1024) GB" : "\(megabytes) MB"
    }

    static func disk(_ bytes: Int64) -> String {
        // Decimal, as iOS and the creation stepper count it.
        "\(bytes / 1_000_000_000) GB"
    }
}
