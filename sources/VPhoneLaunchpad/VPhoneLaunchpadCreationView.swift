import AppKit
import SwiftUI
import VPhoneCore
import VPhoneLaunchpadKit

// MARK: - Creation

/// A machine's `vm create` run and checkpoint. The run keeps going when
/// this sheet closes. Stages show their checkpoint status as written;
/// `unverified`, `not_applicable` and `recovery_required` keep their names.
/// Stop Creating sends SIGINT to the run's process group; Resume runs
/// `vm create --resume`, and a changed toolchain is resumed only after the
/// user confirms the digests.
struct VPhoneLaunchpadCreationView: View {
    let creation: VPhoneLaunchpadCreation
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var showsLog = false
    @State private var showsResume = false
    @State private var confirmsStop = false

    private var library: VPhoneLaunchpadMachineLibrary {
        model.machines
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("\(creation.machine.name) Creation")) {
            Form {
                overview
                stages
                if let recovery = progress?.recovery {
                    Section("Recovery Required") {
                        Text(verbatim: "\(recovery.kind)\(recovery.stage.map { " · \($0)" } ?? "")")
                        Text(verbatim: recovery.detail).textSelection(.enabled)
                        Text(verbatim: recovery.action)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                outcome
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        } accessory: {
            HStack(spacing: VPhoneLaunchpadTheme.unit) {
                VPhoneLaunchpadCommandInfoButton(command: creation.command?.display ?? "")
                Button("Open Log") { showsLog = true }
                    .disabled(!FileManager.default.fileExists(atPath: creation.logFile.path))
            }
        } actions: {
            if creation.isRunning {
                Button("Stop Creating…", role: .destructive) { confirmsStop = true }
                    .disabled(creation.cancelRequested)
            } else if canOfferResume {
                Button("Resume…") { showsResume = true }
                    .disabled(!library.canResume(creation.machine))
            }
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .frame(width: 720)
        .frame(minHeight: 520)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showsLog) {
            VPhoneLaunchpadConsoleView(title: Text("\(creation.machine.name) Creation Log"), url: creation.logFile)
        }
        .sheet(isPresented: $showsResume) {
            if case let .success(progress)? = creation.progress {
                VPhoneLaunchpadResumeView(creation: creation, progress: progress)
            }
        }
        .confirmationDialog(
            Text("Stop Creating \(creation.machine.name)?"), isPresented: $confirmsStop
        ) {
            Button("Stop Creating", role: .destructive) { creation.cancel() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sends SIGINT to the vm create process group. The stage under way stays running in the checkpoint, which then reads interrupted. Resume continues from the checkpoint.")
        }
        .alert(
            Text("The vphone-cli toolchain changed"),
            isPresented: Binding(get: { creation.toolChange != nil && !creation.isRunning }, set: { _ in }),
            presenting: creation.toolChange
        ) { change in
            Button("Resume with This Build") { acceptToolChange(change) }
            Button("Cancel", role: .cancel) { dismissToolChange() }
        } message: { change in
            Text(verbatim: toolChangeMessage(change))
        }
        .task(id: creation.machine) {
            // A run this Launchpad holds reloads the checkpoint itself; one
            // shown for a machine created elsewhere is read here.
            while !Task.isCancelled {
                if !creation.isRunning {
                    await creation.reloadProgress()
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onAppear {
            // `-VPhoneLaunchpadOpenSheet resumeSheet` (smoke check).
            let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            if arguments["VPhoneLaunchpadOpenSheet"] as? String == "resumeSheet" {
                Task {
                    await creation.reloadProgress()
                    showsResume = true
                }
            }
        }
    }

    private var progress: VPhoneLaunchpadCreateProgress? {
        if case let .success(progress)? = creation.progress {
            return progress
        }
        return nil
    }

    /// Resume is offered for a checkpoint that is not finished, with a
    /// variant Launchpad runs.
    private var canOfferResume: Bool {
        guard let progress else {
            return false
        }
        return progress.overallStatus != "succeeded"
            && VPhoneLaunchpadCreateVariant(rawValue: progress.variant)?.isAvailable == true
    }

    // MARK: - Sections

    @ViewBuilder
    private var overview: some View {
        Section {
            switch creation.progress {
            case let .success(progress)?:
                LabeledContent("Status") {
                    Label {
                        Text(verbatim: progress.overallStatus)
                    } icon: {
                        VPhoneLaunchpadStatusIcon(status: .init(progress.overallTone))
                    }
                }
                LabeledContent("Variant") { Text(verbatim: progress.variant) }
                if let next = progress.nextStage {
                    LabeledContent("Next stage") { Text(verbatim: next.rawValue) }
                }
                LabeledContent("Updated") {
                    Text(verbatim: progress.updatedAt.formatted(date: .abbreviated, time: .standard))
                }
                LabeledContent("Attempts") { Text(verbatim: "\(progress.attempts)") }
                if VPhoneLaunchpadCreateVariant(rawValue: progress.variant)?.isAvailable == false {
                    Text(verbatim: VPhoneLaunchpadNewMachineView.lessReason)
                        .foregroundStyle(.secondary)
                }
            case let .failure(error)?:
                Label {
                    Text(verbatim: error.message).textSelection(.enabled)
                } icon: {
                    VPhoneLaunchpadStatusIcon(status: .failed)
                }
            case nil:
                Label {
                    if creation.isRunning {
                        Text("Waiting for the create checkpoint…")
                    } else {
                        Text("No create checkpoint")
                    }
                } icon: {
                    VPhoneLaunchpadStatusIcon(status: creation.isRunning ? .running : .pending)
                }
            }
            if creation.isRunning, let started = creation.startedAt {
                LabeledContent("Started") {
                    Text(verbatim: started.formatted(date: .omitted, time: .standard))
                }
            }
            if creation.cancelRequested {
                Text("SIGINT sent to the vm create process group.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Create Checkpoint")
        } footer: {
            Text("Read from the checkpoint file without a lock, every second while this Launchpad's vm create runs.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var stages: some View {
        if let progress {
            Section("Stages") {
                ForEach(progress.stages) { stage in
                    LabeledContent {
                        HStack(spacing: VPhoneLaunchpadTheme.unit) {
                            if let duration = Self.duration(stage) {
                                Text(verbatim: duration)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            Text(verbatim: stage.status)
                        }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: stage.name)
                                if let note = stage.note {
                                    Text(verbatim: note)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .help(Text(verbatim: note))
                                }
                            }
                        } icon: {
                            VPhoneLaunchpadStatusIcon(status: .init(stage.tone))
                        }
                    }
                }
            }
        }
    }

    /// The exit status, the last output lines on failure, and the one
    /// `vm create-status --json` run after the child exited.
    @ViewBuilder
    private var outcome: some View {
        if let error = creation.startError {
            Section("Result") {
                Text(verbatim: error.message)
                Text(verbatim: error.detail ?? "").foregroundStyle(.secondary).textSelection(.enabled)
            }
        } else if let code = creation.exitStatus {
            Section {
                LabeledContent("Exit status") { Text(verbatim: "\(code)") }
                if code != 0, !creation.outputTail.isEmpty {
                    Text(verbatim: creation.outputTail.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                switch creation.status {
                case let .success(status)?:
                    LabeledContent("Run lock held") { Text(verbatim: "\(status.live.createRunInProgress)") }
                    LabeledContent("Bundle lock held") { Text(verbatim: "\(status.live.bundleLockHeld)") }
                    if let transaction = status.live.firmwareTransaction {
                        Text(verbatim: "\(transaction.detail); \(transaction.action)")
                            .foregroundStyle(VPhoneLaunchpadTheme.failed)
                            .textSelection(.enabled)
                    }
                    if let error = status.checkpointError {
                        Text(verbatim: error).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                case let .failure(error)?:
                    Text(verbatim: [error.message, error.detail].compactMap(\.self).joined(separator: "\n"))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                case nil:
                    EmptyView()
                }
            } header: {
                Text("Result")
            } footer: {
                Text("vm create-status ran once after vm create exited.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Tool change

    private func toolChangeMessage(_ change: VPhoneLaunchpadToolChange) -> String {
        var lines = [
            String(localized: "vm create --resume refused: the toolchain digest differs from the one in the checkpoint."),
            String(localized: "Checkpoint: \(change.recorded)"),
            String(localized: "This build: \(change.current)"),
        ]
        if let file = progress?.toolchainSha256, file != change.recorded {
            lines.append(String(localized: "Checkpoint file now records: \(file)"))
        }
        lines.append(String(localized: "Resuming with this build adds --accept-tool-change. Stages already done are verified again before anything runs."))
        return lines.joined(separator: "\n\n")
    }

    private func acceptToolChange(_ change: VPhoneLaunchpadToolChange) {
        let previous = creation.lastResume
        creation.dismissToolChange()
        library.resume(
            creation.machine, restartFrom: previous?.restartFrom, acceptToolChange: true,
            keepArtifacts: previous?.keepArtifacts ?? false)
    }

    private func dismissToolChange() {
        creation.dismissToolChange()
    }

    // MARK: - Formatting

    static func duration(_ stage: VPhoneLaunchpadCreateProgress.Stage) -> String? {
        guard let start = stage.startedAt else {
            return nil
        }
        let interval = (stage.finishedAt ?? Date()).timeIntervalSince(start)
        guard interval >= 0 else {
            return nil
        }
        return Duration.seconds(interval).formatted(.time(pattern: interval >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

// MARK: - Resume

/// `vm create --resume` options: continue from the next unfinished stage,
/// or restart from an earlier one (`--restart-from`).
struct VPhoneLaunchpadResumeView: View {
    let creation: VPhoneLaunchpadCreation
    let progress: VPhoneLaunchpadCreateProgress
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Nil continues from the next unfinished stage.
    @State private var restartFrom: VPhoneCreateStage?
    @State private var keepArtifacts = false

    private var command: VPhoneLaunchpadCreateCommand? {
        VPhoneLaunchpadCreateCommand.resume(
            creation.machine, variant: progress.variant, restartFrom: restartFrom, keepArtifacts: keepArtifacts)
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("Resume \(creation.machine.name)")) {
            Form {
                Section {
                    Picker("Start at", selection: $restartFrom) {
                        if let next = progress.nextStage {
                            Text("Next unfinished stage (\(next.rawValue))").tag(VPhoneCreateStage?.none)
                        }
                        ForEach(progress.restartableStages, id: \.self) { stage in
                            Text("Restart from \(stage.rawValue)").tag(Optional(stage))
                        }
                    }
                    Toggle("Keep prepared restore files", isOn: $keepArtifacts)
                } footer: {
                    Text("vm create --resume verifies the stages it skips and refuses when they no longer pass, when options or the toolchain changed, or while another run holds the checkpoint. A refusal is shown with the CLI's reason.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        } accessory: {
            VPhoneLaunchpadCommandInfoButton(command: command?.display ?? "")
        } actions: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Resume") { resume() }
                .keyboardShortcut(.defaultAction)
                .disabled(command == nil || !model.machines.canResume(creation.machine))
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            if progress.nextStage == nil {
                restartFrom = progress.restartableStages.first
            }
        }
    }

    private func resume() {
        model.machines.resume(creation.machine, restartFrom: restartFrom, keepArtifacts: keepArtifacts)
        dismiss()
    }
}

// MARK: - Status

extension VPhoneLaunchpadStatus {
    /// Checkpoint tones to icons. `notApplicable` shows as pending: a stage
    /// that does not apply is neither passed nor failed.
    init(_ tone: VPhoneLaunchpadCreateProgress.Tone) {
        switch tone {
        case .passed: self = .passed
        case .warning: self = .warning
        case .failed: self = .failed
        case .running: self = .running
        case .pending, .notApplicable: self = .pending
        }
    }
}
