import AppKit
import SwiftUI
import VPhoneLaunchpadKit

// MARK: - Machines

/// The machine list: search, column sorting, an empty state, the inspector,
/// start and stop, and the console. Settings, rename, clone, export, import
/// and delete arrive in B3.
struct VPhoneLaunchpadMachinesView: View {
    typealias MachinePath = VPhoneLaunchpadMachinePath

    /// The console sheet's machine.
    struct ConsoleSheet: Identifiable {
        let machine: MachinePath
        var id: MachinePath { machine }
    }

    @Environment(VPhoneLaunchpadModel.self) private var model
    @State private var filter = ""
    /// Empty keeps the order `vm list` returns; a header click replaces it.
    @State private var sortOrder: [KeyPathComparator<VPhoneLaunchpadMachine>] = []
    @State private var showsInspector = true
    @State private var console: ConsoleSheet?
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
                        console = ConsoleSheet(machine: path)
                    }
                } else if library.selection.count > 1 {
                    ContentUnavailableView("\(library.selection.count) Machines Selected", systemImage: "iphone")
                } else {
                    ContentUnavailableView("No Selection", systemImage: "iphone")
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
            .fontDesign(.monospaced)
            // The toggle belongs to the inspector's own toolbar section.
            .toolbar { inspectorToolbar }
        }
        .toolbar { toolbar }
        .sheet(item: $console) { sheet in
            VPhoneLaunchpadConsoleView(machine: sheet.machine, url: library.consoleLog(sheet.machine))
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
    @ViewBuilder
    private func machineActions(_ machines: [VPhoneLaunchpadMachine]) -> some View {
        let startable = machines.filter { library.canStart($0.path) }
        let stoppable = machines.filter { library.canStop($0.path) }
        Button("Start") { start(startable) }
            .disabled(startable.isEmpty)
        Button("Start Headless") { start(startable, headless: true) }
            .disabled(startable.isEmpty)
        Button("Stop") { stop(stoppable) }
            .disabled(stoppable.isEmpty)
        Divider()
        if machines.count == 1, let machine = machines.first {
            Button("Open Console") { console = ConsoleSheet(machine: machine.path) }
            Button("Show Console Log in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([library.consoleLog(machine.path)])
            }
            .disabled(!FileManager.default.fileExists(atPath: library.consoleLog(machine.path).path))
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(machines.map(\.path.url))
        }
    }

    // MARK: - Table

    private func table(selection: Binding<Set<MachinePath>>) -> some View {
        Table(rows, selection: selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name)
                .width(min: 90, ideal: 110)
            if library.spansLibraries {
                TableColumn("Location", value: \.libraryRoot) { machine in
                    Text(verbatim: VPhoneLaunchpadMachineLocations.volumeName(machine.libraryRoot))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(Text(verbatim: VPhoneLaunchpadMachineLocations.abbreviated(
                            URL(fileURLWithPath: machine.libraryRoot, isDirectory: true))))
                }
                .width(min: 80, ideal: 110)
            }
            TableColumn("iOS", value: \.iosVersion) { machine in
                Text(verbatim: machine.restoreInfo.map { "\($0.ios.version) (\($0.ios.build))" } ?? "—")
            }
            .width(min: 110, ideal: 120)
            TableColumn("State") { machine in
                VPhoneLaunchpadMachineStateLabel(
                    state: library.state(of: machine.path),
                    activity: library.activities[machine.path],
                    panicked: library.panicked.contains(machine.path)
                )
            }
            .width(min: 150, ideal: 160)
            TableColumn("CPU", value: \.cpuCount) { machine in
                Text(verbatim: "\(machine.cpuCount)").monospacedDigit()
            }
            .width(40)
            TableColumn("Memory", value: \.memoryMB) { machine in
                Text(verbatim: Self.memory(machine.memoryMB)).monospacedDigit()
            }
            .width(72)
            TableColumn("Disk", value: \.diskSizeBytes) { machine in
                Text(verbatim: Self.disk(machine.diskSizeBytes)).monospacedDigit()
            }
            .width(72)
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
            }
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
