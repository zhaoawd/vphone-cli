import AppKit
import SwiftUI
import VPhoneLaunchpadKit

// MARK: - State label

/// A machine's run state as the table and the inspector show it. An
/// activity Launchpad runs on the machine (`Stopping…`, `Exporting…`) takes
/// the place of the state; a panic line in the console turns the icon
/// amber. Transfers use a known fraction when available and an indeterminate
/// bar for older CLIs or a backend whose total is unknown.
struct VPhoneLaunchpadMachineStateLabel: View {
    let state: VPhoneLaunchpadRunState
    var activity: String?
    var panicked = false
    var indeterminate = false
    var fraction: Double?
    var bytes: Int64?

    var body: some View {
        if indeterminate, let activity {
            HStack(spacing: VPhoneLaunchpadTheme.unit) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(width: 48)
                Text(verbatim: progressText(activity)).lineLimit(1)
            }
            .help(Text(verbatim: progressText(activity)))
        } else {
            label
        }
    }

    private func progressText(_ activity: String) -> String {
        guard let bytes else { return activity }
        return activity + " " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    @ViewBuilder
    private var label: some View {
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
    let onOpenCreation: (VPhoneLaunchpadMachinePath) -> Void
    @Environment(VPhoneLaunchpadModel.self) private var model
    /// Nil while the machine has no create checkpoint.
    @State private var creation: Result<VPhoneLaunchpadCreateSummary, VPhoneLaunchpadError>?
    @State private var origins = VPhoneLaunchpadMachineOrigins(.missing)
    @State private var originsMachine: VPhoneLaunchpadMachinePath?

    private var library: VPhoneLaunchpadMachineLibrary {
        model.machines
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("State") {
                    VPhoneLaunchpadMachineStateLabel(
                        state: library.state(of: machine.path),
                        activity: library.activity(of: machine.path),
                        panicked: library.panicked.contains(machine.path),
                        indeterminate: library.isExporting(machine.path),
                        fraction: library.exports[machine.path]?.progress?.fraction,
                        bytes: library.exports[machine.path]?.progress?.bytes
                    )
                }
                if let export = library.exports[machine.path] {
                    value(LocalizedStringKey("Export to"), VPhoneLaunchpadMachineLocations.abbreviated(export.destination))
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

            Section("Recorded Origins") {
                if originsMachine == machine.path {
                    value(LocalizedStringKey("Host selection"), origins.host)
                    value(LocalizedStringKey("Guest environment"), origins.guestEnvironment)
                    value(LocalizedStringKey("Kernel"), origins.kernel)
                    value(LocalizedStringKey("Other boot chain"), origins.bootChain)
                    value(LocalizedStringKey("Actual runtime"), origins.runtime)
                    Text(verbatim: origins.notice).foregroundStyle(.secondary)
                } else {
                    Text("Reading component origins…").foregroundStyle(.secondary)
                }
            }

            Section("Hardware") {
                LabeledContent("CPU") { Text("\(machine.cpuCount) cores") }
                LabeledContent("Memory") { Text(verbatim: VPhoneLaunchpadMachinesView.memory(machine.memoryMB)) }
                LabeledContent("Disk") { Text(verbatim: VPhoneLaunchpadMachinesView.disk(machine.diskSizeBytes)) }
                if let usage = library.diskUsage[machine.path] {
                    LabeledContent("Allocated") {
                        Text(verbatim: usage.allocationKnown ? VPhoneLaunchpadDiskUsage.format(usage.allocated) : String(localized: "Unknown"))
                    }
                    LabeledContent("Exclusive") {
                        Text(verbatim: usage.exclusive.map { VPhoneLaunchpadDiskUsage.format($0) } ?? String(localized: "Unknown"))
                    }
                    .help("Blocks held by only this measured VM folder. Snapshots and unmeasured clones may retain blocks after deletion. A running or busy VM is not opened for measurement.")
                    if !usage.isCurrent { Text("Using last disk measurement").foregroundStyle(.secondary) }
                }
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
            } else if library.creations[machine.path]?.isRunning == true {
                Section("Create Checkpoint") {
                    Button("Show Creation…") { onOpenCreation(machine.path) }
                }
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
                // Every command Launchpad ran, for all machines, to copy into
                // a terminal.
                Button("Recent Commands") { model.panels.present(.commandHistory) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(VPhoneLaunchpadTheme.background)
        .task(id: machine.path) {
            // Read the checkpoint and bounded origin record off the main
            // actor. A cancelled selection must not apply its late snapshot.
            let path = machine.path
            while !Task.isCancelled {
                let snapshot = await Task.detached {
                    (VPhoneLaunchpadCreateSummary.read(path), VPhoneLaunchpadMachineBinding.load(path))
                }.value
                guard !Task.isCancelled else { return }
                creation = snapshot.0
                origins = VPhoneLaunchpadMachineOrigins(snapshot.1)
                originsMachine = path
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
                // Progress, Stop Creating and Resume (`vm create --resume`).
                Button("Show Creation…") { onOpenCreation(machine.path) }
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
