import ArgumentParser
import FirmwarePatcher
import Foundation
import VPhoneCore

struct VPhoneFWGenerationPrepareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "generation-prepare",
        abstract: "Prepare verified originals and an initial desired plan for a stopped existing VM",
        discussion: "Requires two local IPSWs and an independent boot ROM. Installed ROM, Restore and Disk.img are not replaced. Existing desired plans are refused. If desired-plan publication is uncertain, use fw desired-plan --readback; retained generations are evidence, not an installed-firmware receipt.")
    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(help: "Explicit local iPhone IPSW path") var iphoneSource: String
    @Option(help: "Explicit local cloudOS IPSW path") var cloudosSource: String
    @Option(help: "Independent original boot ROM path outside the VM") var bootRomSource: String
    @Option(name: [.customShort("V"), .long], help: "variant: regular | dev | jb | exp")
    var variant: PatchFirmwareCLI.VariantOption = .regular
    @Flag(help: "Opt in to Frida kernel relaxations") var frida = false
    @Flag(help: "Force the EXC_GUARD disable patch") var forceExcGuard = false

    func run() throws {
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        let sources = try FirmwarePreparation.localSources(iphoneSource: iphoneSource,
            cloudosSource: cloudosSource, isLess: variant.pipelineVariant == .less)
        let record = try FirmwareGenerationPreparation.prepare(in: bundle.url, iPhone: sources.iphone,
            cloudOS: sources.cloudos, bootROMSource: URL(fileURLWithPath: bootRomSource),
            variant: variant.pipelineVariant, enableFrida: frida, forceExcGuard: forceExcGuard)
        print("Verified generation prepared: generation=\(record.generationID) plan=\(record.planSHA256)")
        print("Installed firmware was not changed; kernel update and actual boot remain unverified.")
    }
}
