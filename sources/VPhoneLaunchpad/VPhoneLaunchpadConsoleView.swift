import AppKit
import SwiftUI
import VPhoneLaunchpadKit

/// A sheet for a machine's console log, which `vm launch` writes. Read only;
/// the log stays on disk after the sheet closes.
struct VPhoneLaunchpadConsoleView: View {
    let machine: VPhoneLaunchpadMachinePath
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VPhoneLaunchpadSheet(Text("\(machine.name) Console")) {
            VPhoneLaunchpadLogView(url: url)
                .frame(minWidth: 820, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
                .overlay(Rectangle().strokeBorder(VPhoneLaunchpadTheme.border, lineWidth: VPhoneLaunchpadTheme.borderWidth))
                .padding(VPhoneLaunchpadTheme.sectionGap)
        } accessory: {
            Text(verbatim: VPhoneLaunchpadMachineLocations.abbreviated(url))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
                .help(Text(verbatim: url.path))
        } actions: {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .disabled(!FileManager.default.fileExists(atPath: url.path))
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }
}
