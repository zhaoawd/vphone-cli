import ArgumentParser
import FirmwarePatcher
import Foundation
import VPhoneCore

struct VPhoneVMRollbackKernelCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rollback-kernel",
        abstract: "List, preview or publish a committed kernel target using the same verified producer",
        discussion: "The stopped VM's current disk is the starting point. Only its Preboot kernel changes. The live desired plan remains unchanged. Old bundles without rollback evidence and cross-bundle producers are refused. Recover an interrupted transaction with vm update-kernel --recover.")
    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Flag(help: "List historical selection eligibility; publication rechecks producer authority") var list = false
    @Option(help: "Explicit committed transaction UUID") var toTransaction: String?
    @Flag(help: "Validate target selection without publishing") var preview = false
    @Flag(help: "Print list or preview as JSON") var json = false
    @Option(help: .hidden) var expectedBindingSha256: String?
    @Option(help: .hidden) var expectedCoreBundle: String?

    mutating func validate() throws {
        guard list != (toTransaction != nil), !preview || toTransaction != nil, !json || list || preview else {
            throw ValidationError("Use --list or --to-transaction <uuid> [--preview]")
        }
        if let id = toTransaction, UUID(uuidString: id)?.uuidString.lowercased() != id {
            throw ValidationError("--to-transaction requires a canonical lowercase UUID")
        }
    }
    func run() throws {
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        if expectedBindingSha256 != nil || expectedCoreBundle != nil {
            guard let binding = try VPhoneMachineBinding.snapshot(bundle.url), binding.sha256 == expectedBindingSha256,
                  binding.binding.bundle == expectedCoreBundle else { throw ValidationError("VM binding changed before kernel rollback") }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if list {
            let targets = try FirmwareKernelRollback.targets(in: bundle.url)
            if json { print(String(decoding: try encoder.encode(targets), as: UTF8.self)) }
            else { print("Historical selection only; publication requires fresh verified producer qualification."); for target in targets { print("\(target.transactionID) eligible=\(target.eligible) \(target.reason ?? target.payloadSHA256 ?? "")") } }
            return
        }
        let target = try FirmwareKernelRollback.prepare(in: bundle.url, transactionID: toTransaction!)
        if preview {
            let fields = ["transactionID": target.transactionID, "targetPlanSHA256": target.targetPlanSHA256,
                "targetPayloadSHA256": target.targetPayloadSHA256, "liveDesiredSHA256": target.liveDesiredSHA256]
            if json { print(String(decoding: try encoder.encode(fields), as: UTF8.self)) }
            else { print("Kernel rollback preview: target=\(target.transactionID) plan=\(target.targetPlanSHA256) payload=\(target.targetPayloadSHA256)") }
            if !json { print("Publication revalidates the actual verified producer and current disk.") }
            return
        }
        let receipt = try FirmwareKernelRollback.publish(target)
        print("Kernel rollback committed: target=\(target.transactionID) generation=\(receipt.generationID) plan=\(receipt.planSHA256)")
        print("Offline publication verified; actual kernel boot remains unverified.")
    }
}
