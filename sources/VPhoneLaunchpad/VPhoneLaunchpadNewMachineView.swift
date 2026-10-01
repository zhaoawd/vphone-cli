import AppKit
import SwiftUI
import VPhoneCore
import VPhoneLaunchpadKit

// MARK: - New Machine

/// Name, location, firmware sources from `fw catalog --json` or custom
/// IPSWs, variant and disk size. Create starts `vphone-cli vm create` and
/// hands off to the creation view. CPU, memory and network are not options
/// of `vm create`; Settings changes them once the machine exists.
struct VPhoneLaunchpadNewMachineView: View {
    let onCreate: (VPhoneLaunchpadMachinePath) -> Void
    @Environment(VPhoneLaunchpadModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    /// The canonical library the machine is created in.
    @State private var location = ""
    /// A folder chosen with Other… that is not one of the library's locations.
    @State private var chosenLocation: String?
    @State private var catalog: VPhoneLaunchpadFirmwareCatalog?
    @State private var catalogError: String?
    @State private var pairing: String?
    @State private var usesCustomSources = false
    @State private var iphoneSource = ""
    @State private var cloudOSSource = ""
    @State private var variant = VPhoneLaunchpadCreateVariant.regular
    @State private var diskSizeGB = VPhoneLaunchpadCreateRequest.defaultDiskSizeGB
    @State private var advanced = VPhoneLaunchpadNewMachineAdvancedView.Options()
    @State private var showsAdvanced = false

    private var library: VPhoneLaunchpadMachineLibrary {
        model.machines
    }

    private var selectedPairing: VPhoneLaunchpadFirmwareCatalog.Pairing? {
        catalog?.pairings.first { $0.id == pairing }
    }

    private var sources: (iphone: String, cloudOS: String)? {
        if usesCustomSources {
            let iphone = iphoneSource.trimmingCharacters(in: .whitespaces)
            let cloudOS = cloudOSSource.trimmingCharacters(in: .whitespaces)
            return iphone.isEmpty || cloudOS.isEmpty ? nil : (iphone, cloudOS)
        }
        return selectedPairing.map { ($0.iosURL, $0.cloudOSURL) }
    }

    private var effectiveName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var machine: VPhoneLaunchpadMachinePath {
        VPhoneLaunchpadMachinePath(libraryRoot: location, name: effectiveName)
    }

    private var request: VPhoneLaunchpadCreateRequest {
        VPhoneLaunchpadCreateRequest(
            name: effectiveName, libraryRoot: location, variant: variant,
            iphoneSource: sources?.iphone ?? "", cloudosSource: sources?.cloudOS ?? "",
            diskSizeGB: diskSizeGB, keepArtifacts: advanced.keepArtifacts, frida: advanced.frida,
            spoofBuild: variant == .exp ? advanced.spoofBuild : "",
            prepareBackend: advanced.prepareBackend, restoreBackend: advanced.restoreBackend)
    }

    private var command: VPhoneLaunchpadCreateCommand? {
        VPhoneLaunchpadCreateCommand.create(request)
    }

    /// The first `pcc-research-NN` free in `root`, filled in when the sheet opens.
    private func suggestedName(in root: String) -> String {
        let names = (1 ... 99).lazy.map { String(format: "pcc-research-%02d", $0) }
        return names.first { !library.isTaken(VPhoneLaunchpadMachinePath(libraryRoot: root, name: $0)) } ?? "pcc-research"
    }

    private var nameProblem: String? {
        if !VPhoneLaunchpadMachineName.isValidNewName(effectiveName) {
            return String(localized: "Use letters, numbers, periods, hyphens, and underscores.")
        }
        if library.machines.contains(where: { $0.path == machine }) || library.creations[machine]?.isRunning == true {
            return String(localized: "A machine with this name already exists.")
        }
        if library.isTaken(machine) {
            return String(localized: "A folder with this name already exists in this location.")
        }
        if !VPhoneLaunchpadMachineLocations.socketPathFits(root: location, name: effectiveName) {
            return String(localized: "The path is too long. Use a shorter name, or a location with a shorter path.")
        }
        return nil
    }

    private var locationProblem: String? {
        location.isEmpty ? nil : VPhoneLaunchpadMachineLocations.problem(with: location)
    }

    /// The reason Create is unavailable once name and location are fine.
    private var requestProblem: String? {
        switch VPhoneLaunchpadCreateCommand.refusal(request) {
        case .variantUnavailable?: VPhoneLaunchpadNewMachineView.lessReason
        case .source?: sources == nil ? nil : String(localized: "Firmware sources must be http(s) URLs or absolute paths.")
        case .spoofBuild?: String(localized: "The spoofed build must be letters and digits, for exp only.")
        case .nativePrepareNeedsFiles?: String(localized: "Native preparation needs two local IPSW files.")
        case .diskSize?, .name?, .location?, nil: nil
        }
    }

    static var lessReason: String {
        String(localized: "less is not available here: vm create must run as root for less, and Launchpad runs vphone-cli as your user.")
    }

    private var canCreate: Bool {
        nameProblem == nil && locationProblem == nil && command != nil
    }

    var body: some View {
        VPhoneLaunchpadSheet(Text("New Machine")) {
            Form {
                Section {
                    TextField("Name", text: $name)
                    locationPicker
                } footer: {
                    if let problem = nameProblem ?? locationProblem {
                        Text(verbatim: problem).foregroundStyle(VPhoneLaunchpadTheme.failed)
                    }
                }

                firmware

                Section {
                    Picker("Variant", selection: $variant) {
                        ForEach(VPhoneLaunchpadCreateVariant.allCases, id: \.self) { variant in
                            Text(verbatim: variant.rawValue)
                                .tag(variant)
                                .disabled(!variant.isAvailable)
                        }
                    }
                    Stepper("Disk: \(diskSizeGB) GB", value: $diskSizeGB, in: VPhoneLaunchpadCreateRequest.diskSizeRange, step: 16)
                } header: {
                    Text("Machine")
                } footer: {
                    VStack(alignment: .leading, spacing: VPhoneLaunchpadTheme.unit) {
                        if variant == .less {
                            Text(verbatim: Self.lessReason).foregroundStyle(VPhoneLaunchpadTheme.failed)
                        }
                        Text("vm create sets 8 CPU cores, 8192 MB and NAT. Change them in Settings once the machine exists.")
                        Text(verbatim: spaceNote)
                    }
                    .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("Advanced") {
                        HStack(spacing: VPhoneLaunchpadTheme.unit) {
                            Text(verbatim: advanced.summary(variant: variant))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Button("Edit…") { showsAdvanced = true }
                        }
                    }
                } footer: {
                    VStack(alignment: .leading, spacing: VPhoneLaunchpadTheme.unit) {
                        Text("The CFW stage asks for an administrator password in the macOS authentication dialog. Launchpad does not handle the password.")
                        if let problem = requestProblem, variant != .less {
                            Text(verbatim: problem).foregroundStyle(VPhoneLaunchpadTheme.failed)
                        }
                    }
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
            Button("Create") { create() }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
        }
        .frame(width: 600)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showsAdvanced) {
            VPhoneLaunchpadNewMachineAdvancedView(options: $advanced, variant: variant)
        }
        .task { await loadCatalog() }
        .onAppear {
            location = library.libraryRoot
            name = suggestedName(in: location)
            // `-VPhoneLaunchpadOpenSheet newMachineAdvanced` (smoke check).
            let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            if arguments["VPhoneLaunchpadOpenSheet"] as? String == "newMachineAdvanced" {
                showsAdvanced = true
            }
        }
    }

    // MARK: - Location

    /// The library's locations that are mounted, the default one first, and
    /// a folder chosen with Other….
    private var locations: [String] {
        var roots = library.roots.filter { $0 == library.libraryRoot || VPhoneLaunchpadMachineLocations.isAvailable($0) }
        for root in [chosenLocation, location].compactMap(\.self) where !root.isEmpty && !roots.contains(root) {
            roots.append(root)
        }
        return roots
    }

    private var locationPicker: some View {
        Picker("Location", selection: Binding(
            get: { location },
            set: { root in
                if root.isEmpty {
                    // Let the menu close before the open panel runs.
                    Task { @MainActor in chooseLocation() }
                } else {
                    location = root
                }
            }
        )) {
            ForEach(locations, id: \.self) { root in
                Text(verbatim: VPhoneLaunchpadMachineLocations.abbreviated(URL(fileURLWithPath: root, isDirectory: true)))
                    .tag(root)
            }
            Divider()
            // Library roots are absolute, so an empty tag cannot be one.
            Text("Other…").tag("")
        }
        .help(Text(verbatim: location))
    }

    private func chooseLocation() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a Location")
        panel.message = String(localized: "The machine is created in a folder with its name inside the folder you choose.")
        panel.prompt = String(localized: "Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: location, isDirectory: true)
        panel.present { url in
            let root = VPhoneLaunchpadMachineLocations.canonical(url)
            if !library.roots.contains(root) {
                chosenLocation = root
            }
            location = root
            // Machines already in the folder join the list; a folder that
            // cannot hold machines is only shown here, with the reason.
            if VPhoneLaunchpadMachineLocations.problem(with: root) == nil {
                library.addLocation(root)
            }
        }
    }

    // MARK: - Firmware

    private var firmware: some View {
        Section {
            Picker("Source", selection: $usesCustomSources) {
                Text("Catalog").tag(false)
                Text("Custom IPSWs").tag(true)
            }
            .pickerStyle(.segmented)

            if usesCustomSources {
                sourceField("iPhone IPSW", $iphoneSource)
                sourceField("cloudOS IPSW", $cloudOSSource)
            } else if let catalog {
                Picker("iOS", selection: $pairing) {
                    ForEach(catalog.pairings.reversed()) { pairing in
                        Text(verbatim: "\(pairing.iosName) (\(pairing.build))").tag(Optional(pairing.id))
                    }
                }
                LabeledContent("cloudOS") { Text(verbatim: selectedPairing?.cloudOSName ?? "—") }
            } else if let catalogError {
                Label {
                    Text(verbatim: catalogError).textSelection(.enabled)
                } icon: {
                    VPhoneLaunchpadStatusIcon(status: .warning)
                }
            } else {
                Label {
                    Text("Loading firmware catalog…").foregroundStyle(.secondary)
                } icon: {
                    VPhoneLaunchpadStatusIcon(status: .running)
                }
            }
        } header: {
            Text("Firmware")
        } footer: {
            if !usesCustomSources, let catalog {
                Text("Recommended firmware pairings for \(catalog.device). vm create downloads them.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func isIPSWFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return path.hasPrefix("/") && path.lowercased().hasSuffix(".ipsw")
            && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    private func sourceField(_ title: LocalizedStringKey, _ text: Binding<String>) -> some View {
        LabeledContent(title) {
            HStack {
                // A chosen file shows only its name; a URL or a path still
                // being typed stays editable.
                if Self.isIPSWFile(text.wrappedValue) {
                    Text(verbatim: URL(fileURLWithPath: text.wrappedValue).lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(Text(verbatim: text.wrappedValue))
                    Button {
                        text.wrappedValue = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Clear")
                } else {
                    TextField(title, text: text, prompt: Text("URL or path"))
                        .labelsHidden()
                }
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.present { url in
                        text.wrappedValue = url.path
                    }
                }
            }
        }
    }

    /// Disk plus roughly 20 GB of IPSWs and the prepared restore tree (upstream),
    /// in the stepper's unit (VPhoneDiskSize).
    private var spaceNote: String {
        let free = VPhoneDiskSize.gigabytes(bytes: VPhoneLaunchpadMachineLocations.availableBytes(location) ?? 0)
        return String(localized: "Needs about \(diskSizeGB + 20) GB; \(free) GB free.")
    }

    // MARK: - Actions

    private func loadCatalog() async {
        guard catalog == nil, let commandLine = model.commandLine else {
            return
        }
        do {
            let catalog = try VPhoneLaunchpadFirmwareCatalog.decode(
                try await commandLine.run(VPhoneLaunchpadCreateCommand.catalog, recordInHistory: false))
            self.catalog = catalog
            pairing = catalog.pairings.last?.id
        } catch {
            catalogError = (error as? VPhoneLaunchpadError).map { [$0.message, $0.detail].compactMap(\.self).joined(separator: "\n") }
                ?? error.localizedDescription
        }
    }

    private func create() {
        guard canCreate, let creation = library.create(request) else {
            return
        }
        onCreate(creation.machine)
        dismiss()
    }
}

// MARK: - Advanced

/// New Machine's second page. It edits New Machine's own state, so Done
/// only closes it. The backends stay unset (the CLI defaults, `script` and
/// `python`) unless chosen here.
struct VPhoneLaunchpadNewMachineAdvancedView: View {
    struct Options: Equatable {
        var keepArtifacts = false
        var frida = false
        var spoofBuild = ""
        var prepareBackend: VPhoneLaunchpadCreateRequest.PrepareBackend?
        var restoreBackend: VPhoneLaunchpadCreateRequest.RestoreBackend?

        func summary(variant: VPhoneLaunchpadCreateVariant) -> String {
            var parts = [
                "prepare \(prepareBackend?.rawValue ?? "script")",
                "restore \(restoreBackend?.rawValue ?? "python")",
            ]
            if keepArtifacts {
                parts.append("keep artifacts")
            }
            if frida {
                parts.append("frida")
            }
            if variant == .exp, !spoofBuild.isEmpty {
                parts.append("spoof \(spoofBuild)")
            }
            return parts.joined(separator: " · ")
        }
    }

    @Binding var options: Options
    let variant: VPhoneLaunchpadCreateVariant
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VPhoneLaunchpadSheet(Text("Advanced Options")) {
            Form {
                Section {
                    Picker("Preparation", selection: $options.prepareBackend) {
                        Text("Default (script)").tag(VPhoneLaunchpadCreateRequest.PrepareBackend?.none)
                        Text(verbatim: "script").tag(Optional(VPhoneLaunchpadCreateRequest.PrepareBackend.script))
                        Text("native (experimental)").tag(Optional(VPhoneLaunchpadCreateRequest.PrepareBackend.native))
                    }
                    Picker("Restore", selection: $options.restoreBackend) {
                        Text("Default (python)").tag(VPhoneLaunchpadCreateRequest.RestoreBackend?.none)
                        Text(verbatim: "python").tag(Optional(VPhoneLaunchpadCreateRequest.RestoreBackend.python))
                        Text("native (experimental)").tag(Optional(VPhoneLaunchpadCreateRequest.RestoreBackend.native))
                    }
                } header: {
                    Text("Backends")
                } footer: {
                    Text("Default passes no option, so vm create uses its own default. Native preparation reads two local IPSW files only. A resume keeps the backends the checkpoint records.")
                        .foregroundStyle(.secondary)
                }

                Section("Options") {
                    Toggle("Keep prepared restore files", isOn: $options.keepArtifacts)
                    Toggle("Frida support", isOn: $options.frida)
                    if variant == .exp {
                        TextField("Spoofed build", text: $options.spoofBuild, prompt: Text("None"))
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        } actions: {
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}
