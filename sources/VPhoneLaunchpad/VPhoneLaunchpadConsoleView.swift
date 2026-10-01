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
        VStack(spacing: 0) {
            HStack {
                Text("\(machine.name) Console")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, VPhoneLaunchpadTheme.sectionGap)
            .padding(.vertical, VPhoneLaunchpadTheme.padding)

            VPhoneLaunchpadLogView(url: url)
                .frame(minWidth: 820, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
                .overlay(Rectangle().strokeBorder(VPhoneLaunchpadTheme.border, lineWidth: VPhoneLaunchpadTheme.borderWidth))
                .padding(.horizontal, VPhoneLaunchpadTheme.sectionGap)

            HStack(spacing: VPhoneLaunchpadTheme.unit) {
                Text(verbatim: VPhoneLaunchpadMachineLocations.abbreviated(url))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                    .help(Text(verbatim: url.path))
                Spacer(minLength: VPhoneLaunchpadTheme.sectionGap)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .disabled(!FileManager.default.fileExists(atPath: url.path))
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, VPhoneLaunchpadTheme.sectionGap)
            .padding(.vertical, VPhoneLaunchpadTheme.padding)
        }
        .background(VPhoneLaunchpadTheme.background)
        .fontDesign(.monospaced)
    }
}
