import AppKit
import SwiftUI
import VPhoneLaunchpadKit

// MARK: - Host Setup

/// `vphone-cli doctor --json` as check rows, and `helper status` as text.
/// doctor runs when the sheet opens and on Check Again, never on a timer.
/// Nothing here changes the host: suggested actions, including the AMFI
/// one, are text to copy.
struct VPhoneLaunchpadHostSetupView: View {
    let host: VPhoneLaunchpadHostSetup
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VPhoneLaunchpadPanelFrame(Text("Host Setup")) {
            Form {
                summarySection
                helperSection
                amfiSection
                findingSections
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        } accessory: {
            Button("Check Again") {
                Task { await host.refresh() }
            }
            .help("Run vphone-cli doctor and helper status again")
            .disabled(host.isChecking)
            if host.isChecking {
                VPhoneLaunchpadStatusIcon(status: .running)
            }
        } actions: {
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(width: 680, height: 620)
        .task { await host.refresh() }
    }

    // MARK: - doctor

    /// Summary first, then the helper and AMFI notes, then every finding.
    @ViewBuilder
    private var summarySection: some View {
        switch host.doctor {
        case .notRun:
            Section {
                Label {
                    Text("Running vphone-cli doctor…")
                } icon: {
                    VPhoneLaunchpadStatusIcon(status: .running)
                }
            }
        case let .failed(reason):
            Section {
                Label {
                    Text("vphone-cli doctor did not return a report")
                } icon: {
                    VPhoneLaunchpadStatusIcon(status: .failed)
                }
                Text(verbatim: reason)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case let .report(report, status):
            Section {
                summary(report, status: status)
            } footer: {
                Text("Result of vphone-cli doctor (read-only). Suggested actions are shown as text and are never run.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var findingSections: some View {
        ForEach(host.sections) { section in
            Section {
                ForEach(section.rows) { row in
                    VPhoneLaunchpadHostCheckRowView(row: row)
                }
            } header: {
                Text(verbatim: Self.title(ofCategory: section.category))
            }
        }
    }

    private func summary(_ report: VPhoneLaunchpadDiagnosticReport, status: Int32) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: VPhoneLaunchpadTheme.unit) {
            VPhoneLaunchpadSeverityIcon(severity: report.worst)
            // doctor's own field names and values, not translated.
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "worst \(report.summary.worstSeverity) · exit \(status)")
                Text(verbatim: VPhoneLaunchpadCheckSeverity.allCases
                    .map { "\($0.rawValue) \(report.count($0))" }
                    .joined(separator: " · "))
                    .foregroundStyle(.secondary)
                Text(verbatim: "library \(report.scope.libraryRoot) · tool \(report.toolCommit ?? "-") · \(report.generatedAt)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.callout)
        }
    }

    static func title(ofCategory category: String) -> String {
        switch category {
        case "environment": String(localized: "Environment")
        case "dependency": String(localized: "Dependencies")
        case "occupancy": String(localized: "Occupancy")
        case "input": String(localized: "Inputs")
        case "patch": String(localized: "Patching")
        case "restore": String(localized: "Restore")
        case "guest_runtime": String(localized: "Guest runtime")
        case "internal": String(localized: "Checks that could not run")
        default: category
        }
    }

    // MARK: - Helper

    private var helperSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: VPhoneLaunchpadTheme.unit) {
                switch host.helper?.state {
                case let .reachable(version)?:
                    VPhoneLaunchpadStatusIcon(status: .passed)
                    Text("Helper protocol \(version)")
                case .unavailable?:
                    VPhoneLaunchpadStatusIcon(status: .pending)
                    Text("Helper not available")
                case nil:
                    VPhoneLaunchpadStatusIcon(status: host.isChecking ? .running : .pending)
                    Text("Not checked")
                }
                Spacer()
            }
            if let helper = host.helper {
                Text(verbatim: "$ vphone-cli helper status  (exit \(helper.exitStatus))\n\(helper.output)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .launchpadPanel()
            }
        } header: {
            Text("Privileged helper")
        } footer: {
            Text(verbatim: VPhoneLaunchpadDeferral.helperRegistration)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - AMFI

    private var amfiSection: some View {
        Section {
            Text("Launchpad shows the doctor conclusion only (sip_status, signing_entitlements) and has no AMFI allow action.")
                .foregroundStyle(.secondary)
        } header: {
            Text(verbatim: "AMFI")
        }
    }
}

// MARK: - Row

struct VPhoneLaunchpadHostCheckRowView: View {
    let row: VPhoneLaunchpadHostCheckRow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: VPhoneLaunchpadTheme.unit) {
                VPhoneLaunchpadSeverityIcon(severity: row.severity)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: row.message)
                    // doctor's stable finding code.
                    Text(verbatim: row.vm.map { "\(row.code) (\($0))" } ?? row.code)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if let action = row.suggestedAction {
                Text("Suggested (not run): \(action)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !row.evidence.isEmpty {
                DisclosureGroup {
                    Text(verbatim: row.evidence.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text("Evidence")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Severity

/// doctor severities in the status colours: ok green, warning amber, error
/// red, unknown (a check that could not run) an amber question mark.
struct VPhoneLaunchpadSeverityIcon: View {
    let severity: VPhoneLaunchpadCheckSeverity

    var body: some View {
        switch severity {
        case .ok:
            VPhoneLaunchpadStatusIcon(status: .passed)
        case .warning:
            VPhoneLaunchpadStatusIcon(status: .warning)
        case .error:
            VPhoneLaunchpadStatusIcon(status: .failed)
        case .unknown:
            Image(systemName: "questionmark.circle.fill")
                .foregroundStyle(VPhoneLaunchpadTheme.warning)
                .frame(width: 16, height: 16)
                .accessibilityLabel(Text(verbatim: "unknown"))
        }
    }
}
