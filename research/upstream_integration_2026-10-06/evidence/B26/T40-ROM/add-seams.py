from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
p=r/'sources/VPhoneCore/VPhoneCreateResourceSnapshot.swift'
s=p.read_text().replace('    public let manifest: Manifest\n','    public let manifest: Manifest\n    package let romSource: URL\n    package let sepromSource: URL\n',1)
old='''        try capture(resources: source, executable: cli, storage: FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-create-toolchains-\\(geteuid())"), availableBytes: availableCapacity)'''
new='''        try capture(resources: source, executable: cli,
            romSource: VPhoneBundleOps.defaultROMSource(), sepromSource: VPhoneBundleOps.defaultSEPROMSource())
    }

    package static func capture(resources source: VPhoneResources, executable cli: URL,
                                romSource: URL, sepromSource: URL) throws -> VPhoneCreateResourceSnapshot {
        try capture(resources: source, executable: cli, storage: FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-create-toolchains-\\(geteuid())"),
            romSource: romSource, sepromSource: sepromSource, availableBytes: availableCapacity)'''
assert old in s;s=s.replace(old,new,1)
s=s.replace('''    package static func capture(resources source: VPhoneResources, executable cli: URL, storage: URL,
                                availableBytes:''','''    package static func capture(resources source: VPhoneResources, executable cli: URL, storage: URL,
                                romSource: URL = VPhoneBundleOps.defaultROMSource(),
                                sepromSource: URL = VPhoneBundleOps.defaultSEPROMSource(),
                                availableBytes:''',1)
s=s.replace('return VPhoneCreateResourceSnapshot(directory: directory, source: source, manifest: manifest)','return VPhoneCreateResourceSnapshot(directory: directory, source: source, manifest: manifest, romSource: romSource, sepromSource: sepromSource)',1)
s=s.replace('private init(directory: URL, source: VPhoneResources, manifest: Manifest) {','private init(directory: URL, source: VPhoneResources, manifest: Manifest, romSource: URL, sepromSource: URL) {\n        self.romSource = romSource\n        self.sepromSource = sepromSource',1)
p.write_text(s)
p=r/'sources/vphone-cli/VPhoneCreateOrchestrator.swift'
s=p.read_text()
old='''        let spec = VPhoneBundleOps.NewBundleSpec(
            name: options.name, cpuCount: options.cpuCount, memoryMB: options.memoryMB,
            diskSizeGB: options.diskSizeGB,
            romSource: VPhoneBundleOps.defaultROMSource(), sepromSource: VPhoneBundleOps.defaultSEPROMSource())
        let bundle = try VPhoneBundleOps.create(spec, in: library)'''
assert old in s;s=s.replace(old,'        let bundle = try createBundle(options, snapshot: runner.resourceSnapshot)',1)
old='''    func makeRunner(_ runtime: VPhoneCreateRuntime) throws -> VPhoneCreateRunner {
        let snapshot = try VPhoneCreateResourceSnapshot.capture(resources: resources, executable: selfExecutable)'''
new='''    func createBundle(_ options: Options, snapshot: VPhoneCreateResourceSnapshot?) throws -> VPhoneBundle {
        guard let snapshot else { throw VPhoneMachineBindingError("Create requires a captured ROM snapshot before allocating a VM") }
        let spec = VPhoneBundleOps.NewBundleSpec(
            name: options.name, cpuCount: options.cpuCount, memoryMB: options.memoryMB,
            diskSizeGB: options.diskSizeGB, romSource: snapshot.romSource, sepromSource: snapshot.sepromSource)
        return try VPhoneBundleOps.create(spec, in: library)
    }

    func makeRunner(_ runtime: VPhoneCreateRuntime,
                    romSource: URL = VPhoneBundleOps.defaultROMSource(),
                    sepromSource: URL = VPhoneBundleOps.defaultSEPROMSource()) throws -> VPhoneCreateRunner {
        let snapshot = try VPhoneCreateResourceSnapshot.capture(resources: resources, executable: selfExecutable,
            romSource: romSource, sepromSource: sepromSource)'''
assert old in s;s=s.replace(old,new,1)
s=s.replace('''    func refreshBootROM(bundleURL: URL) throws {
        try VPhoneBundleGuard''','''    func refreshBootROM(bundleURL: URL) throws {
        guard let resourceSnapshot else { throw VPhoneMachineBindingError("Create requires a captured ROM snapshot before prepare") }
        try VPhoneBundleGuard''',1)
s=s.replace('try FileManager.default.copyItem(at: VPhoneBundleOps.defaultROMSource(), to: staged)','try FileManager.default.copyItem(at: resourceSnapshot.romSource, to: staged)',1)
p.write_text(s)
