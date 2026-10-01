import AppKit
import SwiftUI
import VPhoneLaunchpadKit

/// The commands Launchpad ran, newest first, in a sheet. Each line is the
/// command as it can be pasted into a terminal; the periodic `vm list` is
/// not recorded.
struct VPhoneLaunchpadCommandHistoryView: View {
    let history: VPhoneLaunchpadCommandHistory
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<UUID> = []

    private var entries: [VPhoneLaunchpadCommandHistory.Entry] {
        history.entries.reversed()
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("Recent Commands")) {
            if entries.isEmpty {
                ContentUnavailableView("Commands that Launchpad runs appear here.", systemImage: "terminal")
            } else {
                table
            }
        } accessory: {
            Button("Copy") { copy(selection) }
                .disabled(selection.isEmpty)
        } actions: {
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(width: 760, height: 460)
    }

    /// The icon and time keep fixed widths, so the command gets the rest.
    private var table: some View {
        Table(entries, selection: $selection) {
            TableColumn(Text(verbatim: "")) { entry in
                VPhoneLaunchpadStatusIcon(status: entry.status.map { $0 == 0 ? .passed : .failed } ?? .running)
                    .help(entry.status.map { Text("Exit status \($0)") } ?? Text("Running"))
            }
            .width(16)
            TableColumn("Started") { entry in
                Text(verbatim: entry.date.formatted(date: .omitted, time: .standard))
                    .monospacedDigit()
            }
            .width(80)
            TableColumn("Command") { entry in
                Text(verbatim: entry.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Text(verbatim: entry.text))
            }
        }
        .scrollContentBackground(.hidden)
        .background(VPhoneLaunchpadTheme.background)
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Copy Command") { copy(ids) }
                .disabled(ids.isEmpty)
        }
        .onCopyCommand {
            let text = commands(selection)
            return text.isEmpty ? [] : [NSItemProvider(object: text as NSString)]
        }
    }

    /// The selected commands, one per line, in the order the table shows them.
    private func commands(_ ids: Set<UUID>) -> String {
        entries.filter { ids.contains($0.id) }.map(\.text).joined(separator: "\n")
    }

    private func copy(_ ids: Set<UUID>) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commands(ids), forType: .string)
    }
}
