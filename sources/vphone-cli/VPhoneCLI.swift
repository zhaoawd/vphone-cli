import ArgumentParser
import FirmwarePatcher
import Foundation
import VPhoneCore

struct VPhoneCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vphone-cli",
        abstract: "Boot a virtual iPhone or patch firmware with the Swift pipeline",
        subcommands: [
            VPhoneBootCLI.self, PatchFirmwareCLI.self, PatchComponentCLI.self, VPhoneVMCommand.self,
            VPhoneFWCommand.self, VPhoneRestoreCommand.self, VPhoneCFWCommand.self, VPhoneSetupCommand.self,
        ],
        defaultSubcommand: VPhoneBootCLI.self
    )
}

struct VPhoneBootCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "boot",
        abstract: "Boot a virtual iPhone (PV=3)",
        discussion: """
        Creates a Virtualization.framework VM with platform version 3 (vphone)
        and boots it from a manifest plist that describes all paths and hardware.

        Requires:
          - macOS 15+ (Sequoia or later)
          - SIP/AMFI disabled
          - Signed with vphone entitlements (done automatically by wrapper script)

        Example:
          vphone-cli --config ./config.plist
        """
    )

    @Option(
        name: .shortAndLong,
        help: "Path to VM manifest plist (config.plist). Required.",
        transform: URL.init(fileURLWithPath:)
    )
    var config: URL

    @Flag(name: .shortAndLong, help: "Boot into DFU mode")
    var dfu: Bool = false

    @Flag(name: .customLong("headless"), help: "Boot without a VM window or menu bar")
    var headless: Bool = false

    @Option(help: "Kernel GDB debug stub port on host (omit for system-assigned port; valid: 6000...65535)")
    var kernelDebugPort: Int?

    @Option(help: "Path to signed vphoned binary for guest auto-update")
    var vphonedBin: String = ".vphoned.signed"

    @Option(name: [.customShort("V"), .long], help: "Firmware variant to execute.")
    var variant: PatchFirmwareCLI.VariantOption = .regular

    @Option(
        help: "Automatically install the given IPA/TIPA after the guest control channel connects. Unavailable with --dfu.",
        transform: URL.init(fileURLWithPath:)
    )
    var installIPA: URL?
    
    @Flag(name: .customLong("no-vphoned"), help: "Exclude vphoned usage (patchless-only).")
    var noVphoned: Bool = false

    @Flag(
        help: "Allow macOS idle system sleep while the VM is running. Manual and clamshell sleep are always allowed."
    )
    var allowHostIdleSleep: Bool = false

    /// DFU mode is always headless; `--headless` also disables the normal VM window.
    var noGraphics: Bool {
        dfu || headless
    }

    var installPackageURL: URL? {
        installIPA?.standardizedFileURL
    }

    mutating func validate() throws {
        if dfu, let packageURL = installPackageURL {
            throw ValidationError(
                "`--install-ipa` is unavailable with `--dfu` because DFU mode does not start the guest control channel: \(packageURL.path)"
            )
        }

        guard let packageURL = installPackageURL else { return }

        guard FileManager.default.fileExists(atPath: packageURL.path) else {
            throw ValidationError("`--install-ipa` file does not exist: \(packageURL.path)")
        }

        guard VPhoneInstallPackage.isSupportedFile(packageURL) else {
            throw ValidationError(
                "`--install-ipa` only supports .ipa or .tipa packages: \(packageURL.lastPathComponent)"
            )
        }
    }

    /// Resolve final options by merging manifest values.
    func resolveOptions() throws -> VPhoneVirtualMachine.Options {
        let manifest = try VPhoneVirtualMachineManifest.load(from: config)
        print("[vphone] Loaded VM manifest from \(config.path)")

        let vmDir = config.deletingLastPathComponent()

        return VPhoneVirtualMachine.Options(
            configURL: config,
            romURL: manifest.romImages != nil ? manifest.resolve(path: manifest.romImages!.avpBooter, in: vmDir) : nil,
            nvramURL: manifest.resolve(path: manifest.nvramStorage, in: vmDir),
            diskURL: manifest.resolve(path: manifest.diskImage, in: vmDir),
            cpuCount: Int(manifest.cpuCount),
            memorySize: manifest.memorySize,
            sepStorageURL: manifest.resolve(path: manifest.sepStorage, in: vmDir),
            sepRomURL: manifest.romImages != nil ? manifest.resolve(path: manifest.romImages!.avpSEPBooter, in: vmDir) : nil,
            screenWidth: manifest.screenConfig.width,
            screenHeight: manifest.screenConfig.height,
            screenPPI: manifest.screenConfig.pixelsPerInch,
            screenScale: manifest.screenConfig.scale,
            kernelDebugPort: kernelDebugPort,
            variant: variant.virtualMachineVariant,
            noVphoned: self.noVphoned
        )
    }

    mutating func run() throws {}
}

struct PatchFirmwareCLI: ParsableCommand {
    @Flag(help: "Recover an interrupted firmware transaction without patching")
    var recover = false

    enum VariantOption: String, CaseIterable, ExpressibleByArgument {
        case less
        case regular
        case dev
        case jb
        case exp

        var pipelineVariant: FirmwarePipeline.Variant {
            switch self {
            case .less: .less
            case .regular: .regular
            case .dev: .dev
            case .jb: .jb
            case .exp: .exp
            }
        }

        var virtualMachineVariant: VPhoneVirtualMachine.Variant {
            switch self {
            case .less: .less
            case .regular: .regular
            case .dev: .dev
            case .jb: .jb
            case .exp: .exp
            }
        }
    }

    static let configuration = CommandConfiguration(
        commandName: "patch-firmware",
        abstract: "Patch boot-chain firmware in a VM directory using the Swift pipeline "
            + "(diagnostic entry: takes a bare path instead of a VM name; `vphone-cli fw patch` "
            + "is the normal one). Both take the same VM-directory lock and refuse a busy VM."
    )

    @Option(
        name: [.customLong("vm-directory"), .customShort("d")],
        help: "Path to the VM directory that contains the *Restore* folder.",
        transform: URL.init(fileURLWithPath:)
    )
    var vmDirectory: URL

    @Option(name: [.customShort("V"), .long], help: "Firmware variant to patch.")
    var variant: VariantOption = .regular

    @Option(
        name: .customLong("records-out"),
        help: "Optional path to write emitted PatchRecord JSON."
    )
    var recordsOut: String?

    @Option(
        name: .customLong("report-out"),
        help: "Optional path to write the structured PatchRunReport JSON (results, requirements, gates, ablation)."
    )
    var reportOut: String?

    @Option(
        name: .customLong("ablate"),
        parsing: .upToNextOption,
        help: ArgumentHelp("Disable one or more patch steps by id (repeatable and comma-separated). "
            + "A value matches at component (avpbooter), patcher (avpbooter.AVPBooterPatcher), "
            + "or full-id (avpbooter.AVPBooterPatcher.patchDGSTBypass) granularity. "
            + "An ablation run does NOT write firmware unless --allow-ablation-output is given.")
    )
    var ablate: [String] = []

    @Flag(
        name: .customLong("allow-ablation-output"),
        help: "Write the (partially-patched) firmware back even on an ablation run. Off by default."
    )
    var allowAblationOutput: Bool = false

    @Flag(name: [.customShort("q"), .customLong("quiet")], help: "Suppress per-component progress output.")
    var quiet: Bool = false
    
    @Flag(name: .customLong("no-binpack"), help: "Exclude the SSH, VNC, ... binaries from being installed (patchless-only).")
    var noBinpack: Bool = false

    @Flag(name: .customLong("no-vphoned"), help: "Exclude vphoned from being installed (patchless-only).")
    var noVphoned: Bool = false

    @Flag(
        name: .customLong("force-exc-guard"),
        help: "Force-enable the EXC_GUARD (Mach port guard) disable patch on regular/jb/exp, even on bases where it isn't required to boot. Use if a third-party app's crash-reporting/RASP SDK trips a fatal GUARD_TYPE_MACH_PORT violation on launch. Always on for iOS 18 bases regardless of this flag."
    )
    var forceExcGuard: Bool = false

    @Flag(
        name: .customLong("frida"),
        help: "Opt in to Frida Stalker kernel relaxations (existing-thread follow + repeated VM_PROT_COPY). jb/exp only."
    )
    var frida: Bool = false

    mutating func run() throws {
        if recover {
            let archive = try VPhoneBundleGuard.withBundleLock(directory: vmDirectory, operation: VPhoneVMOperation.fwPatch) { _ in
                try FirmwarePipeline.recoverFirmware(in: vmDirectory)
            }
            print(archive.map { "[firmware] recovered; archive: \($0.path)" } ?? "[firmware] no pending transaction")
            return
        }

        let ablateIDs = Self.parseAblation(ablate)

        // Same protection as `fw patch`: a bare-path diagnostic entry must not
        // be a way around the VM-directory lock.
        let report = try VPhoneBundleGuard.withBundleLock(
            directory: vmDirectory, operation: VPhoneVMOperation.fwPatch
        ) { _ in
            try FirmwarePipeline(
                vmDirectory: vmDirectory,
                variant: variant.pipelineVariant,
                verbose: !quiet,
                noBinpack: noBinpack,
                noVphoned: noVphoned,
                forceExcGuard: forceExcGuard,
                enableFrida: frida
            ).patchAllStructured(ablate: ablateIDs, allowOutput: allowAblationOutput)
        }

        // --records-out keeps its original payload: the flat [PatchRecord] array.
        let records = report.allRecords
        if let recordsOut {
            let url = URL(fileURLWithPath: recordsOut)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(records).write(to: url)
            print("[patch-firmware] wrote \(records.count) patch records to \(url.path)")
        }

        if let reportOut {
            let url = URL(fileURLWithPath: reportOut)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: url)
            print("[patch-firmware] wrote patch run report to \(url.path)")
        }

        if report.isAblationRun {
            if allowAblationOutput {
                print("[patch-firmware] ABLATION RUN: \(report.ablation.count) step(s) ablated; firmware written (--allow-ablation-output)")
            } else {
                print("[patch-firmware] ABLATION RUN (dry): \(report.ablation.count) step(s) ablated; firmware NOT written (pass --allow-ablation-output to write)")
            }
        }

        if recordsOut == nil {
            print("[patch-firmware] applied \(records.count) patches for \(variant.rawValue)")
        }

        if !report.failedRequired.isEmpty {
            throw PatcherError.patchSiteNotFound(
                "required patches failed: "
                    + report.failedRequired.map(\.description).joined(separator: ", "))
        }
    }

    /// Flatten repeatable + comma-separated `--ablate` values into trimmed ids.
    static func parseAblation(_ raw: [String]) -> [String] {
        raw.flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.isEmpty }
    }
}

struct PatchComponentCLI: ParsableCommand {
    enum ComponentOption: String, CaseIterable, ExpressibleByArgument {
        case txm
        case kernelBase = "kernel-base"
        // TESTING/DIAGNOSTICS ONLY — not part of any production flow.
        // Production JB patching runs through `patch-firmware --variant jb`; this
        // standalone option exists so `tests/test_jb_kernel_patches.sh` can run the
        // JB kernel layer over a single kernelcache and dump records via --records-out.
        // (txm / kernel-base, by contrast, are standalone single-component patchers.)
        case kernelJB = "kernel-jb"
    }

    static let configuration = CommandConfiguration(
        commandName: "patch-component",
        abstract: "Patch a single firmware component payload and write the patched raw bytes"
    )

    @Option(help: "Component to patch.")
    var component: ComponentOption

    @Option(
        name: [.customShort("i"), .customLong("input")],
        help: "Path to the source firmware file (IM4P or raw).",
        transform: URL.init(fileURLWithPath:)
    )
    var input: URL

    @Option(
        name: [.customShort("o"), .customLong("output")],
        help: "Path to write the patched raw payload bytes.",
        transform: URL.init(fileURLWithPath:)
    )
    var output: URL

    @Flag(name: [.customShort("q"), .customLong("quiet")], help: "Suppress per-patch progress output.")
    var quiet: Bool = false

    @Option(
        name: .customLong("records-out"),
        help: "Optional path to write emitted PatchRecord JSON (for fast-loop validation)."
    )
    var recordsOut: String?

    @Option(
        name: .customLong("report-out"),
        help: "Optional path to write a single-component structured PatchRunReport JSON."
    )
    var reportOut: String?

    @Option(
        name: .customLong("ablate"),
        parsing: .upToNextOption,
        help: ArgumentHelp("Disable this component, patcher, or method by id (repeatable, comma-separated): the "
            + "component canonical name (e.g. kernelcache) or `<component>.<PatcherType>[.<method>]`. "
            + "An ablation run does NOT write the payload unless --allow-ablation-output is given.")
    )
    var ablate: [String] = []

    @Flag(
        name: .customLong("allow-ablation-output"),
        help: "Write the payload even on an ablation run. Off by default."
    )
    var allowAblationOutput: Bool = false

    @Option(
        name: .customLong("target-os"),
        help: "kernel-jb only: base iOS version the kernel will run under (e.g. 27.0). Gates the iOS-27-only JB patches exactly as the pipeline does. Omit to apply the full set (dev/test default)."
    )
    var targetOS: String?

    @Flag(
        name: .customLong("frida"),
        help: "kernel-jb only: opt in to the Frida Stalker kernel relaxations."
    )
    var frida: Bool = false

    /// Canonical component name and patcher type name for ablation matching.
    private var ablationTargets: (canonical: String, patcher: String) {
        switch component {
        case .txm: ("txm", "TXMPatcher")
        case .kernelBase: ("kernelcache", "KernelPatcher")
        case .kernelJB: ("kernelcache", "KernelJBPatcher")
        }
    }

    private func makePatcher(_ payload: Data) -> any StructuredPatcher {
        switch component {
        case .txm:
            return TXMPatcher(data: payload, verbose: !quiet)
        case .kernelBase:
            return KernelPatcher(data: payload, verbose: !quiet)
        case .kernelJB:
            let patcher = KernelJBPatcher(data: payload, verbose: !quiet)
            patcher.applyIOS27 = targetOS.map { $0.hasPrefix("27.") } ?? true
            patcher.applyFrida = frida
            return patcher
        }
    }

    mutating func run() throws {
        let ablateIDs = Set(PatchFirmwareCLI.parseAblation(ablate))
        let (canonical, patcherType) = ablationTargets
        if !ablateIDs.isEmpty {
            let steps = makePatcher(Data()).buildSteps()
            let known = Set([canonical, "\(canonical).\(patcherType)"] + steps.map { $0.id.description })
            let unknown = ablateIDs.subtracting(known).sorted()
            guard unknown.isEmpty else {
                throw PatcherError.invalidFormat("unknown ablation id(s): \(unknown.joined(separator: ", ")); "
                    + "known: \(known.sorted().joined(separator: ", "))")
            }
        }
        let payload = try IM4PHandler.load(contentsOf: input).payload
        let gates = PatchGateSnapshot(
            variant: "component", iosBaseIs18: false,
            iosBaseIs27: targetOS?.hasPrefix("27.") ?? (component == .kernelJB),
            cloudOSIsFridaCapable: frida, forceExcGuard: false, enableFrida: frida,
            excGuardActive: false,
            applyIOS27: targetOS?.hasPrefix("27.") ?? (component == .kernelJB),
            applyFrida: frida
        )
        let result = StructuredExecution.run(patcher: makePatcher(payload), componentName: canonical,
            gates: gates, ablate: ablateIDs, fallback: payload)
        let report = PatchRunReport(variant: "component", gates: gates,
            components: [result.report],
            ablation: result.report.results.filter { $0.outcome == .ablated }.map(\.id))
        try Self.writeReport(report, to: reportOut)
        if let recordsOut {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let url = URL(fileURLWithPath: recordsOut)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(result.report.records).write(to: url)
        }
        guard !result.report.hasRequiredFailure else {
            throw PatcherError.patchVerificationFailed("required patch failure(s): "
                + report.failedRequired.map(\.description).joined(separator: ", "))
        }
        let dry = !ablateIDs.isEmpty && !allowAblationOutput
        if !dry {
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try result.data.write(to: output)
        }
        if !quiet {
            print("[patch-component] applied \(result.report.records.count) patches for \(component.rawValue)")
            print(dry ? "[patch-component] ABLATION dry-run: payload NOT written"
                : "[patch-component] wrote patched payload to \(output.path)")
        }
    }

    static func writeReport(_ report: PatchRunReport, to path: String?) throws {
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url)
    }
}
