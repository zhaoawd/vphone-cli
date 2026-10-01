import AppKit
import SwiftUI
import VPhoneLaunchpadKit

// MARK: - State label

/// A machine's run state as the table and the inspector show it. An
/// activity Launchpad runs on the machine (`Stopping…`) takes the place of
/// the state; a panic line in the console turns the icon amber.
struct VPhoneLaunchpadMachineStateLabel: View {
    let state: VPhoneLaunchpadRunState
    var activity: String?
    var panicked = false

    var body: some View {
        let (status, text, instance): (VPhoneLaunchpadStatus, String, String?) = if let activity {
            (.running, activity, nil)
        } else {
            switch state {
            case let .running(instanceID): (panicked ? .warning : .passed, String(localized: "Running"), instanceID)
            case let .dfu(instanceID): (panicked ? .warning : .passed, String(localized: "Running (DFU)"), instanceID)
            case let .busy(operation): (.running, String(localized: "Busy: \(operation)"), nil)
            case .stopped: (.pending, String(localized: "Stopped"), nil)
            }
        }
        Label {
            Text(verbatim: text).lineLimit(1)
        } icon: {
            VPhoneLaunchpadStatusIcon(status: status)
        }
        .help(Text(verbatim: instance ?? text))
    }
}

// MARK: - Inspector

/// The trailing inspector for the selected machine. Values are split into
/// short rows, since the column is narrow, and long ones truncate in the
/// middle.
struct VPhoneLaunchpadMachineInspector: View {
    let machine: VPhoneLaunchpadMachine
    let onOpenConsole: (VPhoneLaunchpadMachinePath) -> Void
    @Environment(VPhoneLaunchpadModel.self) private var model
    /// Nil while the machine has no create checkpoint.
    @State private var creation: Result<VPhoneLaunchpadCreateSummary, VPhoneLaunchpadError>?

    private var library: VPhoneLaunchpadMachineLibrary {
        model.machines
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("State") {
                    VPhoneLaunchpadMachineStateLabel(
                        state: library.state(of: machine.path),
                        activity: library.activities[machine.path],
                        panicked: library.panicked.contains(machine.path)
                    )
                }
                if let started = library.startedAt[machine.path] {
                    LabeledContent("Started") {
                        Text(verbatim: started.formatted(date: .omitted, time: .standard))
                    }
                }
                if library.panicked.contains(machine.path) {
                    LabeledContent("Console") {
                        Label {
                            Text("Panic line in console")
                        } icon: {
                            VPhoneLaunchpadStatusIcon(status: .warning)
                        }
                    }
                }
            } header: {
                Text(verbatim: machine.name)
                    .font(.headline)
            }

            Section("Firmware") {
                if let info = machine.restoreInfo {
                    LabeledContent("iOS") { Text(verbatim: "\(info.ios.version) (\(info.ios.build))") }
                    LabeledContent("cloudOS") { Text(verbatim: "\(info.cloudOS.version) (\(info.cloudOS.build))") }
                    LabeledContent("Variant") { Text(verbatim: info.firmwareName) }
                } else {
                    Text("Not restored").foregroundStyle(.secondary)
                }
            }

            Section("Hardware") {
                LabeledContent("CPU") { Text("\(machine.cpuCount) cores") }
                LabeledContent("Memory") { Text(verbatim: VPhoneLaunchpadMachinesView.memory(machine.memoryMB)) }
                LabeledContent("Disk") { Text(verbatim: VPhoneLaunchpadMachinesView.disk(machine.diskSizeBytes)) }
                LabeledContent("Network") { Text(verbatim: machine.networkDescription) }
            }

            Section("Identity") {
                if let udid = machine.udid {
                    value(LocalizedStringKey("UDID"), udid)
                }
                value(LocalizedStringKey("Location"), VPhoneLaunchpadMachineLocations.abbreviated(machine.path.url))
            }

            if let creation {
                creationSection(creation)
            }

            Section("Console") {
                HStack {
                    Button("Open Console") { onOpenConsole(machine.path) }
                    Spacer()
                    Button("Show Console Log in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([library.consoleLog(machine.path)])
                    }
                }
                value(LocalizedStringKey("Log"), VPhoneLaunchpadMachineLocations.abbreviated(library.consoleLog(machine.path)))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(VPhoneLaunchpadTheme.background)
        .task(id: machine.path) {
            // The checkpoint file is small and written by rename; read it
            // off the main actor and again while the inspector shows it.
            let path = machine.path
            while !Task.isCancelled {
                creation = await Task.detached { VPhoneLaunchpadCreateSummary.read(path) }.value
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func value(_ title: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(title) {
            Text(verbatim: value)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(Text(verbatim: value))
        }
    }

    // MARK: - Create checkpoint

    @ViewBuilder
    private func creationSection(_ creation: Result<VPhoneLaunchpadCreateSummary, VPhoneLaunchpadError>) -> some View {
        Section {
            switch creation {
            case let .success(summary):
                LabeledContent("Status") {
                    Label {
                        Text(verbatim: summary.overallStatus)
                    } icon: {
                        VPhoneLaunchpadStatusIcon(status: Self.status(summary.overallStatus))
                    }
                }
                if let next = summary.nextStage {
                    LabeledContent("Next stage") { Text(verbatim: next) }
                }
                LabeledContent("Variant") { Text(verbatim: summary.variant) }
                LabeledContent("Updated") {
                    Text(verbatim: summary.updatedAt.formatted(date: .abbreviated, time: .standard))
                }
                ForEach(summary.stages, id: \.name) { stage in
                    LabeledContent {
                        Text(verbatim: stage.status)
                    } label: {
                        Text(verbatim: stage.name)
                    }
                }
                if let recovery = summary.recovery {
                    Text(verbatim: recovery)
                        .foregroundStyle(VPhoneLaunchpadTheme.failed)
                        .textSelection(.enabled)
                }
            case let .failure(error):
                Label {
                    Text(verbatim: error.message)
                        .textSelection(.enabled)
                } icon: {
                    VPhoneLaunchpadStatusIcon(status: .failed)
                }
            }
        } header: {
            Text("Create Checkpoint")
        } footer: {
            Text("Read from the checkpoint file without a lock. A create that is still running reads as interrupted.")
                .foregroundStyle(.secondary)
        }
    }

    /// Statuses keep their checkpoint spelling; only the icon colour maps
    /// them. Nothing but `succeeded` is shown as passed.
    static func status(_ overall: String) -> VPhoneLaunchpadStatus {
        switch overall {
        case "succeeded": .passed
        case "completed_unverified", "incomplete", "interrupted": .warning
        default: .failed
        }
    }
}
