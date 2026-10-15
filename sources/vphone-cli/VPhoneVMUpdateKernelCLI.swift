import ArgumentParser
import FirmwarePatcher
import Foundation
import VPhoneCore

struct VPhoneVMUpdateKernelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "update-kernel",
        abstract: "Update a stopped VM kernel from its frozen desired plan, or recover an interrupted update",
        discussion: "Run the CLI from the VM's verified Core Bundle. The VM must be stopped and Disk.img detached. The update preserves the Preboot IM4M and refuses an incompatible installed DSC. Recovery reads the existing journal without rerunning patches.")
    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Flag(help: "Recover the pending kernel transaction without rerunning its producer") var recover = false
    @Option(help: .hidden) var expectedBindingSha256: String?
    @Option(help: .hidden) var expectedCoreBundle: String?

    func run() throws {
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        if !recover, expectedBindingSha256 != nil || expectedCoreBundle != nil {
            guard let binding = try VPhoneMachineBinding.snapshot(bundle.url), binding.sha256 == expectedBindingSha256,
                  binding.binding.bundle == expectedCoreBundle else {
                throw ValidationError("VM binding changed before kernel update")
            }
        }
        if recover {
            let archive = try FirmwareKernelUpdate.recover(in: bundle.url)
            print(archive.map { "Kernel transaction recovered: \($0.path)" } ?? "No pending kernel transaction")
            return
        }
        guard case .ready(let desired) = try FirmwareDesiredPlanStore.read(in: bundle.url) else {
            throw ValidationError("Kernel update requires an explicitly saved desired firmware plan")
        }
        let generation = try FirmwareGeneration.loadVerified(in: bundle.url, id: desired.generationID)
        let prepared = try FirmwareKernelUpdate.prepare(in: bundle.url, plan: desired.plan, generation: generation)
        let receipt = try FirmwareKernelUpdate.publish(prepared)
        print("Kernel update committed: generation=\(receipt.generationID) plan=\(receipt.planSHA256)")
        print("Offline publication verified; actual kernel boot remains unverified.")
    }
}
