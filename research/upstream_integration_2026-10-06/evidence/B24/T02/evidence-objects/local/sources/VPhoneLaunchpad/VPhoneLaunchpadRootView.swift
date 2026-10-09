import SwiftUI
import VPhoneLaunchpadKit

// MARK: - Root

struct VPhoneLaunchpadRootView: View {
    @Environment(VPhoneLaunchpadModel.self) private var model
    /// The machine list's minimum width (B6), at least 720.
    @State private var minimumWidth: CGFloat = 720

    var body: some View {
        @Bindable var panels = model.panels
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VPhoneLaunchpadToolchainBar(state: model.toolchain)
        }
        .frame(minWidth: minimumWidth, minHeight: 360)
        .onPreferenceChange(VPhoneLaunchpadMinimumWidthKey.self) { width in
            minimumWidth = max(720, width)
        }
        .background(VPhoneLaunchpadTheme.background)
        .fontDesign(.monospaced)
        .navigationTitle("Machines")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                panelButton(.hostSetup, title: String(localized: "Host Setup"), systemImage: "checklist")
                panelButton(.coreBundle, title: String(localized: "Core Bundle"), systemImage: "shippingbox")
            }
        }
        .sheet(item: $panels.current, onDismiss: model.panels.didDismiss) { panel in
            panelView(panel)
        }
        .task { await model.start() }
    }

    // MARK: - Panels (B5)

    /// Enabled once the embedded toolchain is verified: both panels run it.
    private func panelButton(_ panel: VPhoneLaunchpadPanel, title: String, systemImage: String) -> some View {
        Button {
            model.panels.present(panel)
        } label: {
            Label(title: { Text(verbatim: title) }, icon: { Image(systemName: systemImage) })
        }
        .help(Text(verbatim: title))
        .disabled(model.host == nil)
    }

    @ViewBuilder
    private func panelView(_ panel: VPhoneLaunchpadPanel) -> some View {
        switch (panel, model.toolchain) {
        case (.hostSetup, _):
            if let host = model.host {
                VPhoneLaunchpadHostSetupView(host: host)
            }
        case let (.coreBundle, .verified(toolchain)):
            if let bundles = model.coreBundle {
                VPhoneLaunchpadCoreBundleView(toolchain: toolchain, bundles: bundles)
            }
        case (.coreBundle, _):
            EmptyView()
        case (.commandHistory, _):
            VPhoneLaunchpadCommandHistoryView(history: model.history)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.toolchain {
        case .checking:
            ContentUnavailableView {
                Label {
                    Text("Checking Embedded Toolchain")
                } icon: {
                    VPhoneLaunchpadSpinner()
                }
            }
        case .verified:
            VPhoneLaunchpadMachinesView()
        case let .failed(failure):
            VPhoneLaunchpadToolchainFailureView(failure: failure)
        }
    }
}

// MARK: - Toolchain

extension VPhoneLaunchpadToolchain.Step {
    var title: String {
        switch self {
        case .layout: String(localized: "Bundle layout")
        case .nestedSignature: String(localized: "Embedded app signature")
        case .outerSignature: String(localized: "Launchpad signature")
        case .manifest: String(localized: "Toolchain manifest")
        case .cdhash: String(localized: "Executable cdhash")
        }
    }
}

/// Shown in place of the machine list when the embedded toolchain is
/// rejected. No command runs in that state.
struct VPhoneLaunchpadToolchainFailureView: View {
    let failure: VPhoneLaunchpadToolchain.Failure

    var body: some View {
        VStack(alignment: .leading, spacing: VPhoneLaunchpadTheme.unit) {
            Label {
                Text("Embedded Toolchain Rejected")
                    .font(.headline)
            } icon: {
                VPhoneLaunchpadStatusIcon(status: .failed)
            }
            Text("Failed step: \(failure.step.title)")
            Text(verbatim: failure.reason)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Launchpad runs only the vphone-cli.app embedded in its own bundle. Rebuild it with make launchpad.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .launchpadPanel()
        .padding(VPhoneLaunchpadTheme.sectionGap)
    }
}

/// One line under the list: the toolchain every command runs.
struct VPhoneLaunchpadToolchainBar: View {
    let state: VPhoneLaunchpadModel.ToolchainState

    var body: some View {
        HStack(spacing: VPhoneLaunchpadTheme.unit) {
            switch state {
            case .checking:
                VPhoneLaunchpadStatusIcon(status: .running)
                Text("Checking Embedded Toolchain")
                Spacer(minLength: 0)
            case let .verified(toolchain):
                VPhoneLaunchpadStatusIcon(status: .passed)
                Text("Embedded toolchain")
                Text(verbatim: "build \(toolchain.manifest.gitHash)")
                    .foregroundStyle(.secondary)
                Text(verbatim: "vphone-cli \(toolchain.manifest.vphoneCLI.cdhash.prefix(12))")
                    .foregroundStyle(.secondary)
                Text(verbatim: "vphone-vm \(toolchain.manifest.vphoneVM.cdhash.prefix(12))")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(verbatim: VPhoneLaunchpadMachineLocations.abbreviated(toolchain.helperApp))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(Text(verbatim: toolchain.helperApp.path))
            case let .failed(failure):
                VPhoneLaunchpadStatusIcon(status: .failed)
                Text("Embedded Toolchain Rejected")
                Text(verbatim: failure.step.rawValue)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .font(.callout)
        .padding(.horizontal, VPhoneLaunchpadTheme.padding)
        .padding(.vertical, VPhoneLaunchpadTheme.unit)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(VPhoneLaunchpadTheme.border)
                .frame(height: VPhoneLaunchpadTheme.borderWidth)
        }
    }
}
