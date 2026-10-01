import SwiftUI
import VPhoneLaunchpadKit

// MARK: - Core Bundle

/// Read-only: the embedded toolchain every command runs, and the versions in
/// the root-owned store as `core-bundle verify` reports them. Install entries
/// are shown disabled with the reason; nothing is installed, removed or
/// selected.
struct VPhoneLaunchpadCoreBundleView: View {
    let toolchain: VPhoneLaunchpadToolchain
    let bundles: VPhoneLaunchpadCoreBundle
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VPhoneLaunchpadPanelFrame(Text("Core Bundle")) {
            Form {
                toolchainSection
                installSection
                installedSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        } accessory: {
            Button("Verify Again") {
                Task { await bundles.refresh() }
            }
            .help("List the store and run vphone-cli core-bundle verify again")
            .disabled(bundles.isChecking)
            if bundles.isChecking {
                VPhoneLaunchpadStatusIcon(status: .running)
            }
        } actions: {
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(width: 680, height: 620)
        .task { await bundles.refresh() }
    }

    // MARK: - Embedded toolchain

    private var toolchainSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: VPhoneLaunchpadTheme.unit) {
                VPhoneLaunchpadStatusIcon(status: .passed)
                Text("Signature and cdhashes verified")
                Spacer()
            }
            details([
                ("path", toolchain.helperApp.path),
                ("build", toolchain.manifest.gitHash),
                ("vphone-cli cdhash", toolchain.manifest.vphoneCLI.cdhash),
                ("vphone-vm cdhash", toolchain.manifest.vphoneVM.cdhash),
            ])
        } header: {
            Text("Embedded toolchain")
        } footer: {
            Text("Every command runs this vphone-cli. Launchpad does not switch to an installed Core Bundle.")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Store

    private var installedSection: some View {
        Section {
            switch bundles.store {
            case .notChecked:
                Label {
                    Text("Checking…")
                } icon: {
                    VPhoneLaunchpadStatusIcon(status: .running)
                }
            case .absent:
                Label {
                    Text("No Core Bundle store at \(bundles.storeRoot.path).")
                } icon: {
                    VPhoneLaunchpadStatusIcon(status: .pending)
                }
            case let .unreadable(reason):
                Label {
                    Text("The store at \(bundles.storeRoot.path) could not be read: \(reason)")
                } icon: {
                    VPhoneLaunchpadStatusIcon(status: .failed)
                }
            case let .listed(installed) where installed.isEmpty:
                Label {
                    Text("No Core Bundle is installed.")
                } icon: {
                    VPhoneLaunchpadStatusIcon(status: .pending)
                }
            case let .listed(installed):
                ForEach(installed) { bundle in
                    row(bundle)
                }
            }
        } header: {
            Text("Installed")
        } footer: {
            Text("Checked with vphone-cli core-bundle verify (read-only). Minimum supported version: \(VPhoneLaunchpadCoreBundleVersion.minimum).")
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ bundle: VPhoneLaunchpadInstalledCoreBundle) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: VPhoneLaunchpadTheme.unit) {
                switch bundle.check {
                case .verified:
                    VPhoneLaunchpadStatusIcon(status: .passed)
                case .failed:
                    VPhoneLaunchpadStatusIcon(status: .failed)
                case .notAVersion:
                    VPhoneLaunchpadStatusIcon(status: .warning)
                }
                Text(verbatim: "VPhone.bundle \(bundle.name)")
                Spacer()
            }
            switch bundle.check {
            case let .verified(receipt):
                details([
                    ("installedAt", receipt.installedAt.formatted(.iso8601)),
                    ("sha256", receipt.sha256),
                ] + receipt.cdhashes.sorted { $0.key < $1.key }.map { ("\($0.key) cdhash", $0.value) })
            case let .failed(reason):
                Text(verbatim: reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            case .notAVersion:
                Text("Not a Core Bundle version name; not verified.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Install

    private var installSection: some View {
        Section {
            HStack(spacing: VPhoneLaunchpadTheme.unit) {
                Button("Download and Install") {}
                    .disabled(true)
                Button("Install Local Build…") {}
                    .disabled(true)
                Spacer()
            }
            .help(Text(verbatim: VPhoneLaunchpadDeferral.coreBundleInstall))
            Text(verbatim: VPhoneLaunchpadDeferral.coreBundleInstall)
                .foregroundStyle(.secondary)
        } header: {
            Text("Install")
        }
    }

    // MARK: - Formatting

    /// Field names stay as the receipt and manifest spell them.
    private func details(_ pairs: [(String, String)]) -> some View {
        Text(verbatim: pairs.map { "\($0.0): \($0.1)" }.joined(separator: "\n"))
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
