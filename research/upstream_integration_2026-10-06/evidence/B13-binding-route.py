from pathlib import Path
r=Path('/Users/qcz3840/.codex/worktrees/upstream-2d21d21-integration/vphone-cli')
p=r/'Package.swift';s=p.read_text();needle='                "VPhoneHelperKit",\n';assert s.count(needle)==1;s=s.replace(needle,needle+'                "VPhoneLaunchpadKit",\n');p.write_text(s)
p=r/'sources/vphone-cli/VPhoneVMLaunchCLI.swift';s=p.read_text().replace('import VPhoneCore','import VPhoneCore\nimport VPhoneBundleStore\nimport VPhoneLaunchpadKit',1)
a='        let resources = projectRoot.map { VPhoneResources(base: URL(fileURLWithPath: $0)) } ?? .resolve()\n        let layout = VPhoneLaunchLayout(resources: resources)\n\n        let bootBinary = VPhoneResources.vmExecutable()'
b='''        let machine = VPhoneLaunchpadMachinePath(libraryRoot: lib.library.root.path, name: name)
        let binding = try VPhoneLaunchpadMachineBinding.snapshot(machine)
        if let binding {
            guard projectRoot == nil else { throw ValidationError("A bound VM uses its verified Core Bundle resources; --project-root is refused.") }
            guard VPhoneLaunchpadCoreBundleVersion.supportsTargetFeatures(binding.binding.bundle) else {
                throw ValidationError("Bound VM execution requires Core Bundle 2.6.0 or later; select and verify a compatible bundle with vm bind-core-bundle.")
            }
            return try VPhoneCoreBundleStore().withVerifiedExecutable(version: binding.binding.bundle, executable: .vm) { binary in
                try launch(bundle: bundle, name: name, v: v, bootBinary: binary,
                    resources: .resolve(executablePath: binary.path), binding: binding, machine: machine)
            }
        }
        try launch(bundle: bundle, name: name, v: v, bootBinary: VPhoneResources.vmExecutable(),
            resources: projectRoot.map { VPhoneResources(base: URL(fileURLWithPath: $0)) } ?? .resolve(),
            binding: nil, machine: machine)
    }

    private func launch(bundle: VPhoneBundle, name: String, v: VPhoneVerbosity, bootBinary: URL,
                        resources: VPhoneResources, binding: VPhoneLaunchpadMachineBinding.Snapshot?,
                        machine: VPhoneLaunchpadMachinePath) throws {
        let layout = VPhoneLaunchLayout(resources: resources)'''
assert a in s;s=s.replace(a,b)
s=s.replace('        if dfu { args.append("--dfu") }','''        if let binding {
            guard binding.matches(machine) else { throw ValidationError("VM binding changed during launch; no VM was started.") }
            args += ["--binding-sha256", binding.sha256]
        }
        if dfu { args.append("--dfu") }''',1);p.write_text(s)
p=r/'sources/vphone-cli/VPhoneCLI.swift';s=p.read_text();i=s.index('    var unlockAtStartup = false');s=s[:i]+s[i:].replace('    var unlockAtStartup = false','    var unlockAtStartup = false\n    @Option(help: "Expected launchpad.json digest, checked after acquiring the VM lock")\n    var bindingSha256: String?',1);p.write_text(s)
p=r/'sources/vphone-cli/VPhoneAppDelegate.swift';s=p.read_text();s='import VPhoneLaunchpadKit\n'+s;s=s.replace('        FileHandle.standardOutput.write(Data("[vphone] VM lock acquired\\n".utf8))','''        if let digest = cli.bindingSha256 {
            let directory = cli.config.resolvingSymlinksInPath().deletingLastPathComponent()
            let machine = VPhoneLaunchpadMachinePath(libraryRoot: directory.deletingLastPathComponent().path,
                                                    name: directory.lastPathComponent)
            guard let binding = try VPhoneLaunchpadMachineBinding.snapshot(machine), binding.sha256 == digest else {
                throw VPhoneLaunchpadError("VM binding differs from the launch selection; no VM was started")
            }
        }
        FileHandle.standardOutput.write(Data("[vphone] VM lock acquired\\n".utf8))''',1);p.write_text(s)
p=r/'sources/vphone-cli/VPhoneVMCLI.swift';s=p.read_text();s=s.replace('VPhoneVMConfigCommand.self,','VPhoneVMConfigCommand.self, VPhoneVMBindCoreBundleCommand.self,',1);p.write_text(s)
(r/'sources/vphone-cli/VPhoneVMBindingCLI.swift').write_text('''import ArgumentParser
import Foundation
import VPhoneCore
import VPhoneBundleStore
import VPhoneLaunchpadKit

struct VPhoneVMBindCoreBundleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "bind-core-bundle",
        abstract: "Select a verified host Core Bundle for a stopped VM; guest/component origins are preserved")
    @OptionGroup var lib: VPhoneLibraryOption
    @Argument var name: String?
    @Option var version: String
    @Option(help: "New complete backup directory, required for first legacy binding") var backup: String?

    func run() throws {
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        _ = try lib.library.bundle(named: name)
        let machine = VPhoneLaunchpadMachinePath(libraryRoot: lib.library.root.path, name: name)
        let expected = try VPhoneLaunchpadMachineBinding.snapshot(machine)
        guard VPhoneLaunchpadCoreBundleVersion.supportsTargetFeatures(version) else {
            throw ValidationError("Bound execution requires Core Bundle 2.6.0 or later")
        }
        try VPhoneCoreBundleStore().withVerifiedExecutable(version: version, executable: .vm) { _ in
            try VPhoneLaunchpadMachineBinding.persistHost(version, machine: machine, expected: expected,
                firstMigrationBackup: backup.map { URL(fileURLWithPath: $0) })
        }
        print("\\(name): host Core Bundle bound to \\(version); guest, kernel and boot-chain origins preserved")
    }
}
''')
p=r/'sources/VPhoneLaunchpadKit/VPhoneLaunchpadMachineOrigins.swift';s=p.read_text().replace('binding execution is pending integration. Actual runtime and applied component versions are unknown.','launch uses the verified bound host Core Bundle. Actual applied component versions require guest/runtime receipts.');p.write_text(s)
