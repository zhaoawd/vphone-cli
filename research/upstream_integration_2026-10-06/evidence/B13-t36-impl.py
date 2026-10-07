from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
def edit(p,a,b):
 p=r/p;s=p.read_text();assert a in s,(p,a);p.write_text(s.replace(a,b))
p='sources/VPhoneCore/VPhoneVirtualMachineManifest.swift'
edit(p,'    public let hardwareKeyboardEnabled: Bool?','    public let hardwareKeyboardEnabled: Bool?\n    /// Default off for legacy configurations; affects only a new daemon instance.\n    public let unlockAtStartup: Bool?\n    public var usesStartupUnlock: Bool { unlockAtStartup ?? false }')
edit(p,'        hardwareKeyboardEnabled: Bool? = nil,','        hardwareKeyboardEnabled: Bool? = nil,\n        unlockAtStartup: Bool? = nil,')
edit(p,'        self.hardwareKeyboardEnabled = hardwareKeyboardEnabled','        self.hardwareKeyboardEnabled = hardwareKeyboardEnabled\n        self.unlockAtStartup = unlockAtStartup')
edit(p,'        hardwareKeyboardEnabled: Bool? = nil\n','        hardwareKeyboardEnabled: Bool? = nil,\n        unlockAtStartup: Bool? = nil\n')
edit(p,'            hardwareKeyboardEnabled: hardwareKeyboardEnabled ?? self.hardwareKeyboardEnabled,','            hardwareKeyboardEnabled: hardwareKeyboardEnabled ?? self.hardwareKeyboardEnabled,\n            unlockAtStartup: unlockAtStartup ?? self.unlockAtStartup,')
p='sources/VPhoneCore/VPhoneBundleOps.swift'
edit(p,'        hardwareKeyboardEnabled: Bool? = nil\n','        hardwareKeyboardEnabled: Bool? = nil,\n        unlockAtStartup: Bool? = nil\n')
edit(p,'                hardwareKeyboardEnabled: hardwareKeyboardEnabled)','                hardwareKeyboardEnabled: hardwareKeyboardEnabled,\n                unlockAtStartup: unlockAtStartup)')
p='sources/vphone-cli/VPhoneVMCLI.swift'
edit(p,'    var hardwareKeyboard: VPhoneHardwareKeyboardOption?','    var hardwareKeyboard: VPhoneHardwareKeyboardOption?\n    @Option(help: "Startup unlock: on | off (default off; requires an API listener at launch)")\n    var startupUnlock: VPhoneHardwareKeyboardOption?')
edit(p,'            hardwareKeyboardEnabled: hardwareKeyboard?.enabled)','            hardwareKeyboardEnabled: hardwareKeyboard?.enabled, unlockAtStartup: startupUnlock?.enabled)')
p='sources/vphone-cli/VPhoneVMLaunchCLI.swift'
edit(p,'        let resources = projectRoot.map','        if bundle.manifest.usesStartupUnlock && !dfu && apiListen == nil {\n            throw ValidationError("This VM enables startup unlock; supply --api-listen and VPHONE_API_TOKEN, or disable it with vm config --startup-unlock off.")\n        }\n        let resources = projectRoot.map')
edit(p,'        if dfu { args.append("--dfu") }','        if bundle.manifest.usesStartupUnlock && !dfu { args.append("--unlock-at-startup") }\n        if dfu { args.append("--dfu") }')
p='sources/vphone-cli/VPhoneAppDelegate.swift'
edit(p,'VPhoneStartupUnlock(enabled: cli.unlockAtStartup)', 'VPhoneStartupUnlock(enabled: cli.unlockAtStartup || (try VPhoneVirtualMachineManifest.load(from: options.configURL)).usesStartupUnlock)')
p='sources/VPhoneLaunchpadKit/VPhoneLaunchpadMachineEdit.swift'
edit(p,'        public var hardwareKeyboardEnabled: Bool?','        public var hardwareKeyboardEnabled: Bool?\n        public var unlockAtStartup: Bool?')
edit(p,'hardwareKeyboardEnabled: Bool? = nil) {','hardwareKeyboardEnabled: Bool? = nil, unlockAtStartup: Bool? = nil) {\n            self.unlockAtStartup = unlockAtStartup')
edit(p,'network == nil && hardwareKeyboardEnabled == nil','network == nil && hardwareKeyboardEnabled == nil && unlockAtStartup == nil')
edit(p,'        if let enabled = settings.hardwareKeyboardEnabled {','        if let enabled = settings.unlockAtStartup {\n            args += ["--startup-unlock", enabled ? "on" : "off"]\n        }\n        if let enabled = settings.hardwareKeyboardEnabled {')
# vm list uses a separately encoded description; add the persisted optional field.
p='sources/VPhoneLaunchpadKit/VPhoneLaunchpadMachine.swift'
edit(p,'    public let hardwareKeyboardEnabled: Bool?','    public let hardwareKeyboardEnabled: Bool?\n    public let unlockAtStartup: Bool?\n    public var usesStartupUnlock: Bool { unlockAtStartup ?? false }')
edit(p,'udid, hardwareKeyboardEnabled','udid, hardwareKeyboardEnabled, unlockAtStartup')
p='sources/VPhoneLaunchpad/VPhoneLaunchpadMachineSheets.swift'
edit(p,'case cpu, memory, network, hardwareKeyboard','case cpu, memory, network, hardwareKeyboard, startupUnlock')
edit(p,'    @State private var hardwareKeyboardEnabled: Bool','    @State private var unlockAtStartup: Bool\n    @State private var hardwareKeyboardEnabled: Bool')
edit(p,'        _hardwareKeyboardEnabled = State','        _unlockAtStartup = State(initialValue: first?.usesStartupUnlock ?? false)\n        _hardwareKeyboardEnabled = State')
edit(p,'hardwareKeyboardEnabled : nil\n','hardwareKeyboardEnabled : nil\n') if False else None
edit(p,'hardwareKeyboardEnabled: edited.contains(.hardwareKeyboard) ? hardwareKeyboardEnabled : nil','hardwareKeyboardEnabled: edited.contains(.hardwareKeyboard) ? hardwareKeyboardEnabled : nil,\n            unlockAtStartup: edited.contains(.startupUnlock) ? unlockAtStartup : nil')
edit(p,'                    Toggle("Hardware Keyboard",','                    Toggle("Unlock at Startup (requires API listener)", isOn: $unlockAtStartup)\n                    Toggle("Hardware Keyboard",')
edit(p,'        .onChange(of: hardwareKeyboardEnabled)','        .onChange(of: unlockAtStartup) { edited.insert(.startupUnlock) }\n        .onChange(of: hardwareKeyboardEnabled)')
