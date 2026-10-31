import AppKit
import SwiftUI
import VPhoneCore
import VPhoneLaunchpadKit

struct VPhoneLaunchpadBundleChangeView: View {
    let machine: VPhoneLaunchpadMachinePath
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var binding: VPhoneLaunchpadMachineBinding.Read = .missing
    @State private var bindingLoaded = false
    @State private var expectedBindingSHA256: String?
    @State private var version = ""
    @State private var backupPath = ""
    @State private var workParentPath = ""
    @State private var updatesEnvironment = false
    @State private var isWorking = false
    @State private var phase = ""
    @State private var operation: Task<Void, Never>?

    private var versions: [String] {
        guard let bundles = model.coreBundle, case let .listed(items) = bundles.store else { return [] }
        return items.filter { $0.isVerified && VPhoneLaunchpadCoreBundleVersion.supportsTargetFeatures($0.name) }.map(\.name)
    }

    private var needsBackup: Bool {
        if case .missing = binding { return true }
        return false
    }

    private var bindingIsValid: Bool {
        if case .invalid = binding { return false }
        return bindingLoaded
    }

    private var canApply: Bool {
        bindingIsValid && !isWorking && versions.contains(version)
            && model.machines.canEdit(machine)
            && (!needsBackup || backupPath.hasPrefix("/"))
            && (!updatesEnvironment || workParentPath.isEmpty || workParentPath.hasPrefix("/"))
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("Core Bundle Binding")) {
            Form {
                Section {
                    LabeledContent("Machine") { Text(verbatim: machine.name) }
                    switch binding {
                    case let .loaded(value):
                        LabeledContent("Host selection") { Text(verbatim: value.bundle) }
                    case .missing:
                        Text("This machine has no recorded Core Bundle binding.")
                    case let .invalid(reason):
                        Text(verbatim: reason).foregroundStyle(.red)
                    }
                    if versions.isEmpty {
                        Text("No verified compatible Core Bundle is installed.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Core Bundle", selection: $version) {
                            ForEach(versions, id: \.self) { Text(verbatim: $0).tag($0) }
                        }
                    }
                    Button("Refresh Verified Bundles") { Task { await refresh() } }
                        .disabled(isWorking || model.coreBundle?.isChecking == true)
                }
                if needsBackup {
                    Section {
                        TextField("New Backup Directory", text: $backupPath)
                        Button("Choose Backup Parent…") { chooseBackupParent() }
                    } footer: {
                        Text("The first binding requires a complete verified backup outside the machine directory.")
                    }
                }
                Section {
                    Toggle("Update Guest Environment After Binding", isOn: $updatesEnvironment)
                    if updatesEnvironment {
                        TextField("Work Parent (optional)", text: $workParentPath)
                        Text("Environment replacement requires the selected Bundle protocol and administrator authentication. Unsupported or incompatible environments are refused.")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Changing the host binding preserves recorded component origins. If the environment update fails or is cancelled after binding, the new host binding remains.")
                }
                if isWorking {
                    HStack { ProgressView().controlSize(.small); Text(verbatim: phase) }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .disabled(isWorking)
        } accessory: {
            EmptyView()
        } actions: {
            Button("Cancel") {
                if isWorking { operation?.cancel() } else { dismiss() }
            }
            .keyboardShortcut(.cancelAction)
            Button("Apply") { apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canApply)
        }
        .frame(width: 580, height: needsBackup ? 590 : 470)
        .interactiveDismissDisabled(isWorking)
        .task { await refresh() }
        .onDisappear { operation?.cancel() }
    }

    private func refresh() async {
        let path = machine
        let read = await Task.detached { () -> (VPhoneLaunchpadMachineBinding.Read, String?) in
            do {
                guard let snapshot = try VPhoneLaunchpadMachineBinding.snapshot(path) else { return (.missing, "missing") }
                return (.loaded(snapshot.binding), snapshot.sha256)
            } catch { return (.invalid(error.localizedDescription), nil) }
        }.value
        guard !Task.isCancelled else { return }
        binding = read.0
        expectedBindingSHA256 = read.1
        bindingLoaded = true
        await model.coreBundle?.refresh()
        guard !Task.isCancelled else { return }
        if !versions.contains(version) {
            if case let .loaded(value) = binding, versions.contains(value.bundle) { version = value.bundle }
            else { version = versions.first ?? "" }
        }
    }

    private func chooseBackupParent() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.present { parent in
            backupPath = parent.appendingPathComponent("\(machine.name)-backup-\(UUID().uuidString)").path
        }
    }

    private func apply() {
        guard canApply else { return }
        isWorking = true
        phase = String(localized: "Changing Core Bundle…")
        let backup = needsBackup ? URL(fileURLWithPath: backupPath) : nil
        let work = updatesEnvironment && !workParentPath.isEmpty ? URL(fileURLWithPath: workParentPath) : nil
        operation = Task { @MainActor in
            _ = await model.machines.setBundle(machine, version: version, backup: backup,
                updateEnvironment: updatesEnvironment, workParent: work,
                expectedBindingSHA256: expectedBindingSHA256,
                willUpdate: { phase = String(localized: "Updating Guest Environment…") })
            isWorking = false
            dismiss()
        }
    }
}
