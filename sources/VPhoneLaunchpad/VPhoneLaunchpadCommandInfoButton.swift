import AppKit
import SwiftUI

/// An (i) button that keeps a command out of the row and shows it, with a
/// copy button, in a popover. The sheets use it for the exact `vphone-cli`
/// command they will run.
struct VPhoneLaunchpadCommandInfoButton: View {
    let command: String
    @State private var isShown = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help("Show the command")
        .accessibilityLabel(Text("Show the command"))
        .popover(isPresented: $isShown, arrowEdge: .trailing) {
            HStack(alignment: .firstTextBaseline, spacing: VPhoneLaunchpadTheme.unit) {
                Text(verbatim: command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 480, alignment: .leading)
                Button("Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
            }
            .padding(VPhoneLaunchpadTheme.padding)
            .fontDesign(.monospaced)
        }
        .disabled(command.isEmpty)
    }
}
