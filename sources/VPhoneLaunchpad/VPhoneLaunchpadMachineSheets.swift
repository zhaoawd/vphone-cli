import AppKit
import SwiftUI
import VPhoneLaunchpadKit

// MARK: - Settings

/// Hardware and network for one machine, or for several at once
/// (`vm config`). The fields start from the first machine; only the ones
/// edited are written, to every machine, so values the machines do not share
/// are left alone.
struct VPhoneLaunchpadMachineSettingsView: View {
    private enum Field {
        case cpu, memory, network
    }

    let machines: [VPhoneLaunchpadMachine]
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var cpu: Int
    @State private var memoryMB: Int
    @State private var network: String
    @State private var bridgeInterface: String
    @State private var edited: Set<Field> = []

    init(machines: [VPhoneLaunchpadMachine]) {
        self.machines = machines
        let first = machines.first
        _cpu = State(initialValue: first?.cpuCount ?? 8)
        _memoryMB = State(initialValue: first?.memoryMB ?? 8192)
        // `vm config --network` takes nat, bridged or none; an older
        // manifest's hostOnly is offered as none, as upstream does.
        let mode = first?.network.mode ?? "nat"
        _network = State(initialValue: VPhoneLaunchpadEditCommand.Settings.networkModes.contains(mode) ? mode : "none")
        _bridgeInterface = State(initialValue: first?.network.bridgeInterface ?? "")
    }

    private var title: Text {
        machines.count == 1 ? Text("\(machines[0].name) Settings") : Text("Settings for \(machines.count) Machines")
    }

    private var settings: VPhoneLaunchpadEditCommand.Settings {
        let network = edited.contains(.network) ? network : nil
        return VPhoneLaunchpadEditCommand.Settings(
            cpu: edited.contains(.cpu) ? cpu : nil,
            memoryMB: edited.contains(.memory) ? memoryMB : nil,
            network: network,
            bridgeInterface: network == "bridged" ? bridgeInterface.trimmingCharacters(in: .whitespaces) : nil
        )
    }

    private var commands: [VPhoneLaunchpadEditCommand?] {
        machines.map { VPhoneLaunchpadEditCommand.config($0.path, settings) }
    }

    var body: some View {
        VPhoneLaunchpadSheet(title) {
            Form {
                Section {
                    Stepper("CPU: \(cpu) cores", value: $cpu, in: 1 ... ProcessInfo.processInfo.activeProcessorCount)
                    Stepper("Memory: \(memoryMB) MB", value: $memoryMB, in: 2048 ... 65536, step: 1024)
                } header: {
                    Text("Hardware")
                }
                Section {
                    Picker("Mode", selection: $network) {
                        Text("NAT").tag("nat")
                        Text("Bridged").tag("bridged")
                        Text("None").tag("none")
                    }
                    if network == "bridged" {
                        TextField("Interface", text: $bridgeInterface, prompt: Text("First available"))
                    }
                } header: {
                    Text("Network")
                } footer: {
                    VStack(alignment: .leading, spacing: VPhoneLaunchpadTheme.unit) {
                        if machines.count > 1 {
                            Text("Only the settings you change are applied to each machine.")
                        }
                        Text("vphone-cli refuses a machine that is running or busy.")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        } accessory: {
            VPhoneLaunchpadCommandInfoButton(command: commands.compactMap { $0?.display }.joined(separator: "\n"))
        } actions: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(edited.isEmpty || commands.contains { $0 == nil })
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: cpu) { edited.insert(.cpu) }
        .onChange(of: memoryMB) { edited.insert(.memory) }
        .onChange(of: network) { edited.insert(.network) }
        .onChange(of: bridgeInterface) { edited.insert(.network) }
    }

    private func save() {
        let settings = settings
        let paths = machines.map(\.path)
        let library = model.machines
        Task { await library.configure(paths, settings) }
        dismiss()
    }
}

// MARK: - Rename and clone

/// A new name for `vm rename` or `vm clone`. The machine stays in its
/// library.
struct VPhoneLaunchpadNameSheet: View {
    enum Action {
        case rename, clone
    }

    let action: Action
    let machine: VPhoneLaunchpadMachinePath
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var command: VPhoneLaunchpadEditCommand? {
        switch action {
        case .rename: VPhoneLaunchpadEditCommand.rename(machine, to: name)
        case .clone: VPhoneLaunchpadEditCommand.clone(machine, as: name)
        }
    }

    private var fitsLocation: Bool {
        VPhoneLaunchpadMachineLocations.socketPathFits(root: machine.libraryRoot, name: name)
    }

    var body: some View {
        VPhoneLaunchpadSheet(action == .rename ? Text("Rename \(machine.name)") : Text("Clone \(machine.name)")) {
            Form {
                Section {
                    TextField("Name", text: $name)
                } footer: {
                    VStack(alignment: .leading, spacing: VPhoneLaunchpadTheme.unit) {
                        if fitsLocation {
                            Text("Use letters, numbers, periods, hyphens, and underscores.")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("The path is too long. Use a shorter name, or a location with a shorter path.")
                                .foregroundStyle(VPhoneLaunchpadTheme.failed)
                        }
                        if action == .clone {
                            Text("The clone keeps this machine's device identity (NVRAM, machine identifier, SEP storage).")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        } accessory: {
            VPhoneLaunchpadCommandInfoButton(command: command?.display ?? "")
        } actions: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button {
                confirm()
            } label: {
                action == .rename ? Text("Rename") : Text("Clone")
            }
            .keyboardShortcut(.defaultAction)
                .disabled(command == nil)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { name = action == .rename ? machine.name : "\(machine.name)-clone" }
    }

    private func confirm() {
        let library = model.machines
        let machine = machine
        let name = name
        switch action {
        case .rename: Task { await library.rename(machine, to: name) }
        case .clone: Task { await library.clone(machine, as: name) }
        }
        dismiss()
    }
}

// MARK: - Export

/// One machine offers the archive options and a save panel. Several are
/// written with the defaults, one `<name>.tzst` each, into a folder chosen
/// once; an existing file there is not replaced.
struct VPhoneLaunchpadExportView: View {
    let machines: [VPhoneLaunchpadMachinePath]
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var densest = false
    @State private var includeIPSW = false

    private var title: Text {
        machines.count == 1 ? Text("Export \(machines[0].name)") : Text("Export \(machines.count) Machines")
    }

    var body: some View {
        VPhoneLaunchpadSheet(title) {
            Form {
                if machines.count == 1 {
                    Section {
                        Toggle("Maximum compression", isOn: $densest)
                        Toggle("Include the restore IPSW directory", isOn: $includeIPSW)
                    } footer: {
                        (densest
                            ? Text("Creates a smaller .txz archive. Export takes much longer.")
                            : Text("Creates a .tzst archive."))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach(machines, id: \.self) { machine in
                            Text(verbatim: "\(machine.name).tzst")
                        }
                    } footer: {
                        Text("Creates a .tzst archive for each machine in the folder you choose. Existing files are not replaced.")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("vphone-cli reports no progress to Launchpad; the machine shows Exporting… until the archive is written. Cancel Export stops it and removes the partial archive it created.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        } actions: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Choose Location…") { choose() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func choose() {
        let library = model.machines
        if machines.count == 1 {
            let machine = machines[0]
            let panel = NSSavePanel()
            panel.title = String(localized: "Export \(machine.name)")
            panel.nameFieldStringValue = "\(machine.name).\(densest ? "txz" : "tzst")"
            let densest = densest
            let includeIPSW = includeIPSW
            panel.present { url in
                // The save panel has asked before replacing an existing file.
                Task { await library.export([(machine, url)], densest: densest, includeIPSW: includeIPSW, replacing: true) }
                dismiss()
            }
            return
        }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Export \(machines.count) Machines")
        panel.prompt = String(localized: "Export")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        let machines = machines
        panel.present { folder in
            let items = machines.map { ($0, folder.appendingPathComponent("\($0.name).tzst")) }
            Task { await library.export(items, densest: false, includeIPSW: false, replacing: false) }
            dismiss()
        }
    }
}

// MARK: - Delete

/// The confirmation before `vm delete`: the folders that go, by full path.
/// Return does not delete; only the Delete button does.
struct VPhoneLaunchpadDeleteView: View {
    let machines: [VPhoneLaunchpadMachinePath]
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var title: Text {
        machines.count == 1 ? Text("Delete \(machines[0].name)?") : Text("Delete \(machines.count) Machines?")
    }

    private var commands: [VPhoneLaunchpadEditCommand?] {
        machines.map(VPhoneLaunchpadEditCommand.delete)
    }

    var body: some View {
        VPhoneLaunchpadSheet(title) {
            VStack(alignment: .leading, spacing: VPhoneLaunchpadTheme.padding) {
                Label {
                    Text("These folders are removed with everything in them: disk, firmware, settings and device identity. This cannot be undone.")
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    VPhoneLaunchpadStatusIcon(status: .warning)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: VPhoneLaunchpadTheme.unit) {
                        ForEach(machines, id: \.self) { machine in
                            Text(verbatim: machine.url.path)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .launchpadPanel()
                }
                .frame(maxHeight: 200)
                Text("vphone-cli refuses a machine that is running or busy.")
                    .foregroundStyle(.secondary)
            }
            .padding(VPhoneLaunchpadTheme.sectionGap)
        } accessory: {
            VPhoneLaunchpadCommandInfoButton(command: commands.compactMap { $0?.display }.joined(separator: "\n"))
        } actions: {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            // The destructive role drew no red (B3 screenshot), and a tinted
            // prominent button draws grey in a window that is not key (B6
            // smoke), so the title itself is red. No keyboard shortcut:
            // Return does not delete.
            Button(role: .destructive) {
                delete()
            } label: {
                Text("Delete")
                    .foregroundStyle(VPhoneLaunchpadTheme.failed)
            }
            .disabled(commands.contains { $0 == nil })
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func delete() {
        let library = model.machines
        let machines = machines
        Task { await library.delete(machines) }
        dismiss()
    }
}
