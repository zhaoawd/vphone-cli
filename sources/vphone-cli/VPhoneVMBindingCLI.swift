import ArgumentParser
import Foundation
import VPhoneCore
import VPhoneBundleStore

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
        let machine = try lib.library.bundle(named: name).url
        let expected = try VPhoneMachineBinding.snapshot(machine)
        guard VPhoneCoreBundleVersion.supportsTargetFeatures(version) else {
            throw ValidationError("Bound execution requires Core Bundle 2.6.0 or later")
        }
        try VPhoneCoreBundleStore().withVerifiedExecutable(version: version, executable: .vm) { _ in
            try VPhoneMachineBinding.persistHost(version, machine: machine, expected: expected,
                firstMigrationBackup: backup.map { URL(fileURLWithPath: $0) })
        }
        print("\(name): host Core Bundle bound to \(version); guest, kernel and boot-chain origins preserved")
    }
}
