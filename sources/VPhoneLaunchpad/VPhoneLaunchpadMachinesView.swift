import AppKit
import SwiftUI
import VPhoneLaunchpadKit

// MARK: - Machines

/// The machine list: search, column sorting and an empty state. Read-only
/// in B1; the inspector, start/stop and the actions menu arrive in B2/B3.
struct VPhoneLaunchpadMachinesView: View {
    typealias MachinePath = VPhoneLaunchpadMachinePath

    @Environment(VPhoneLaunchpadModel.self) private var model
    @State private var filter = ""
    /// Empty keeps the order `vm list` returns; a header click replaces it.
    @State private var sortOrder: [KeyPathComparator<VPhoneLaunchpadMachine>] = []
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
        // A hidden machine stays out of the selection.
        .onChange(of: filter) {
            let visible = Set(rows.map(\.path))
            library.selection.formIntersection(visible)
        }
        .toolbar { toolbar }
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
                VPhoneLaunchpadMachineStateLabel(state: library.state(of: machine.path))
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

// MARK: - State label

struct VPhoneLaunchpadMachineStateLabel: View {
    let state: VPhoneLaunchpadRunState

    var body: some View {
        let (status, text, instance): (VPhoneLaunchpadStatus, String, String?) = switch state {
        case let .running(instanceID): (.passed, String(localized: "Running"), instanceID)
        case let .dfu(instanceID): (.passed, String(localized: "Running (DFU)"), instanceID)
        case let .busy(operation): (.running, String(localized: "Busy: \(operation)"), nil)
        case .stopped: (.pending, String(localized: "Stopped"), nil)
        }
        Label {
            Text(verbatim: text).lineLimit(1)
        } icon: {
            VPhoneLaunchpadStatusIcon(status: status)
        }
        .help(Text(verbatim: instance ?? text))
    }
}
