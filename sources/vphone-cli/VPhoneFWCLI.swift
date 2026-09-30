import ArgumentParser
import Foundation
import FirmwarePatcher
import VPhoneCore

struct VPhoneFWCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fw",
        abstract: "Firmware pipeline: prepare (download/merge IPSWs) and patch",
        subcommands: [VPhoneFWCatalogCommand.self, VPhoneFWPrepareCommand.self, VPhoneFWPatchCommand.self,
                      VPhoneFWRecordCommand.self, VPhoneFWInspectCommand.self, VPhoneFWPlanCommand.self])
}

// MARK: - catalog

struct VPhoneFWCatalogCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "catalog",
        abstract: "Show the known iOS ↔ cloudOS firmware pairings (recommended per iOS build)")

    @Flag(name: .shortAndLong, help: "Emit JSON") var json = false

    func run() throws {
        let report = VPhoneFirmwareCatalog.report
        if json {
            print(String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
            return
        }
        print("Firmware catalog (\(report.device))")
        let width = report.pairings.map(\.ios.name.count).max() ?? 0
        let header = "iOS".padding(toLength: width, withPad: " ", startingAt: 0)
        print("\(header)  recommended cloudOS")
        for e in report.pairings {
            let ios = e.ios.name.padding(toLength: width, withPad: " ", startingAt: 0)
            print("\(ios)  \(e.recommendedCloudOS.name)")
        }
    }
}

// MARK: - prepare

struct VPhoneFWPrepareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prepare", abstract: "Download + merge IPSWs into a VM bundle")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(name: .shortAndLong, help: "iPhone IPSW URL or local path") var iphoneSource: String?
    @Option(name: .shortAndLong, help: "cloudOS IPSW URL or local path") var cloudosSource: String?
    @Option(help: "iPhone version to resolve to an IPSW") var iphoneVersion: String?
    @Option(help: "iPhone build to resolve to an IPSW") var iphoneBuild: String?
    @Flag(help: "List downloadable IPSWs and exit") var list = false
    @Option(name: .shortAndLong, help: "Resource base override (default: inferred from the running binary path)")
    var projectRoot: String?
    @Flag(name: .customShort("v"), help: "Increase verbosity: -v tool detail, -vv guest serial, -vvv internal trace")
    var verboseCount: Int

    func run() throws {
        let v = max(VPhoneVerbosity.info, VPhoneVerbosity(count: verboseCount))
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        let resources = projectRoot.map { VPhoneResources(base: URL(fileURLWithPath: $0)) } ?? .resolve()

        var env = ProcessInfo.processInfo.environment
        if let iphoneSource { env["IPHONE_SOURCE"] = iphoneSource }
        if let cloudosSource { env["CLOUDOS_SOURCE"] = cloudosSource }
        if let iphoneVersion { env["IPHONE_VERSION"] = iphoneVersion }
        if let iphoneBuild { env["IPHONE_BUILD"] = iphoneBuild }
        if list { env["LIST_FIRMWARES"] = "1" }

        // Redirect the three things a read-only bundle can't provide (python,
        // IPSW cache, extracted apfs_sealvolume) to the writable user cache.
        try FileManager.default.createDirectory(at: resources.ipswCacheDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources.sealVolumeCacheDir, withIntermediateDirectories: true)
        env["VPHONE_PYTHON"] = try resources.pythonExecutable().path
        env["IPSW_DIR"] = resources.ipswCacheDir.path
        env["VPHONE_SEAL_DIR"] = resources.sealVolumeCacheDir.path

        if v.tracesInternals {
            print("[trace] spawning: /bin/bash \(resources.fwPrepareScript.path) (env keys: VPHONE_PYTHON, IPSW_DIR, VPHONE_SEAL_DIR)")
        }
        // `vm create` runs the same script under scripts/vm_lock.py because the
        // lock must survive into a shell process tree it execs. Here the Swift
        // process outlives the script, so it holds the lock itself for the whole
        // download/merge; the child does not inherit the O_CLOEXEC descriptor.
        let code = try VPhoneBundleGuard.withBundleLock(
            directory: bundle.url, operation: VPhoneVMOperation.fwPrepare
        ) { _ in
            try VPhoneProcessRunner.runStreaming(
                URL(fileURLWithPath: "/bin/bash"), [resources.fwPrepareScript.path], cwd: bundle.url, env: env,
                echo: v.showsToolDetail)
        }
        throw ExitCode(code)
    }
}

// MARK: - patch

struct VPhoneFWPatchCommand: ParsableCommand {
    @Flag(help: "Recover an interrupted firmware transaction without patching")
    var recover = false

    static let configuration = CommandConfiguration(
        commandName: "patch", abstract: "Patch the boot chain (native Swift FirmwarePipeline)")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(name: [.customShort("V"), .long], help: "variant: regular | dev | jb | exp | less") var variant: PatchFirmwareCLI.VariantOption = .regular
    @Flag(name: .customLong("force-exc-guard"), help: "Force the EXC_GUARD disable patch") var forceExcGuard = false
    @Flag(name: .customLong("frida"), help: "Opt in to Frida Stalker kernel relaxations (jb/exp only)") var frida = false
    @Option(name: .customLong("ablate"), parsing: .upToNextOption,
            help: ArgumentHelp("Disable patch steps by id (repeatable, comma-separated): component / "
                + "component.Patcher / full id. An ablation run does NOT write firmware unless "
                + "--allow-ablation-output is given."))
    var ablate: [String] = []
    @Flag(name: .customLong("allow-ablation-output"), help: "Write firmware back even on an ablation run.")
    var allowAblationOutput = false
    @Option(name: .customLong("report-out"), help: "Optional path to write the structured PatchRunReport JSON.")
    var reportOut: String?
    @Option(name: .customLong("record-out"),
            help: "Write a reproducible experiment record JSON (and <name>.summary.txt) for this run, including failures.")
    var recordOut: String?
    @Flag(name: .shortAndLong, help: "Suppress per-component progress") var quiet = false

    func run() throws {
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        if recover {
            let archive = try VPhoneBundleGuard.withBundleLock(directory: bundle.url, operation: VPhoneVMOperation.fwPatch) { _ in
                try FirmwarePipeline.recoverFirmware(in: bundle.url)
            }
            print(archive.map { "[firmware] recovered; archive: \($0.path)" } ?? "[firmware] no pending transaction")
            return
        }

        let ablateIDs = PatchFirmwareCLI.parseAblation(ablate)

        // In-process pipeline (no subprocess) — CryptexFilesystemPatcher's
        // apfs_sealvolume read honors VPHONE_SEAL_DIR from *this* process's
        // environment, so set it here to agree with `fw prepare`'s write.
        let resources = VPhoneResources.resolve()
        try FileManager.default.createDirectory(at: resources.sealVolumeCacheDir, withIntermediateDirectories: true)
        setenv("VPHONE_SEAL_DIR", resources.sealVolumeCacheDir.path, 1)

        // Patching rewrites the bundle's boot chain in place — never while the
        // VM (or another offline operation) holds the bundle.
        let report = try VPhoneBundleGuard.withBundleLock(
            directory: bundle.url, operation: VPhoneVMOperation.fwPatch
        ) { _ in
            try VPhonePatchRecording.run(
                FirmwarePipeline(
                    vmDirectory: bundle.url,
                    variant: variant.pipelineVariant,
                    verbose: !quiet,
                    noBinpack: false,
                    noVphoned: false,
                    forceExcGuard: forceExcGuard,
                    enableFrida: frida),
                ablate: ablateIDs, allowOutput: allowAblationOutput, recordOut: recordOut)
        }

        if let reportOut {
            let url = URL(fileURLWithPath: reportOut)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: url)
            print("[fw patch] wrote patch run report to \(url.path)")
        }

        if report.isAblationRun {
            let mode = allowAblationOutput
                ? "firmware written (--allow-ablation-output)"
                : "firmware NOT written (pass --allow-ablation-output to write)"
            print("[fw patch] ABLATION RUN\(allowAblationOutput ? "" : " (dry)"): \(report.ablation.count) step(s) ablated; \(mode)")
        }
        print("[fw patch] applied \(report.allRecords.count) patches for \(variant.rawValue)")

        if !report.failedRequired.isEmpty {
            throw PatcherError.patchSiteNotFound(
                "required patches failed: "
                    + report.failedRequired.map(\.description).joined(separator: ", "))
        }
    }
}

// MARK: - experiment records

/// Runs the pipeline directly, or through the C5 recorder when a record path is given.
enum VPhonePatchRecording {
    static func run(_ pipeline: FirmwarePipeline, ablate: [String], allowOutput: Bool, recordOut: String?) throws -> PatchRunReport {
        guard let recordOut else { return try pipeline.patchAllStructured(ablate: ablate, allowOutput: allowOutput) }
        let url = URL(fileURLWithPath: recordOut)
        let executable = VPhoneResources.runningExecutable()
        let resources = VPhoneResources.resolve()
        // Same resolution as CryptexFilesystemPatcher: VPHONE_SEAL_DIR, else ./.tools.
        let sealDirectory = ProcessInfo.processInfo.environment["VPHONE_SEAL_DIR"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: ".tools")
        let environment = PatchExperimentEnvironment(
            buildCommit: VPhoneBuildInfo.commitHash, executable: executable,
            sourceRoot: PatchExperimentEnvironment.locateSourceRoot(from: executable),
            resourcesBase: resources.base, sealDirectory: sealDirectory,
            pythonExecutable: { try resources.pythonExecutable() })
        print("[record] experiment record: \(url.path)")
        return try PatchExperimentRecorder(recordURL: url, environment: environment)
            .run(pipeline, ablate: ablate, allowOutput: allowOutput)
    }
}

struct VPhoneFWRecordCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record", abstract: "Inspect patch experiment records written by --record-out",
        subcommands: [VPhoneFWRecordShowCommand.self, VPhoneFWRecordCompareCommand.self])
}

struct VPhoneFWRecordShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "Validate a record and print its summary")

    @Argument(help: "Record JSON path") var record: String

    func run() throws {
        print(try PatchExperimentRecord.load(from: URL(fileURLWithPath: record)).summary(), terminator: "")
    }
}

struct VPhoneFWRecordCompareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare",
        abstract: "Compare two records: conditions, patch results and artifact digests",
        discussion: "Exit status: 0 when all three results are 'same', 1 when any differs or cannot be determined, 2 when a record is invalid.")

    @Argument(help: "Left record JSON path") var left: String
    @Argument(help: "Right record JSON path") var right: String
    @Flag(help: "Emit the comparison as JSON") var json = false

    func run() throws {
        let comparison: PatchExperimentComparison
        do {
            comparison = try PatchExperimentRecord.compare(
                PatchExperimentRecord.load(from: URL(fileURLWithPath: left)),
                PatchExperimentRecord.load(from: URL(fileURLWithPath: right)))
        } catch {
            FileHandle.standardError.write(Data("[record] \(error)\n".utf8))
            throw ExitCode(2)
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(comparison), as: UTF8.self))
        } else {
            print(comparison.render(), terminator: "")
        }
        if !comparison.allSame { throw ExitCode(1) }
    }
}

// MARK: - declared variant plan (read-only, T10/T11)

/// Read-only resolver entry: prints the declared patch plan for one or all variants under a
/// modeled gate snapshot. It patches nothing and touches no VM; the gate values are supplied
/// by flags and mirror `FirmwarePipeline.gateSnapshot`.
struct VPhoneFWPlanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Resolve and print the declared patch plan for a variant (read-only; patches nothing)",
        discussion: """
        Joins the pipeline's live steps with the declaration catalog (T10) and reports, per
        variant, the selected declarations and those excluded by version, opt-in or variant,
        plus the guest-side (uncovered this round) and not-implemented declarations. Gate
        values come from --base-os / --frida / --force-exc-guard, modeling the run without a VM.
        """)

    @Option(name: [.customShort("V"), .long], help: "variant: regular | dev | jb | exp | less")
    var variant: PatchFirmwareCLI.VariantOption = .regular
    @Flag(name: .customLong("all"), help: "Resolve every variant instead of one.")
    var all = false
    @Option(name: .customLong("base-os"), help: "Modeled iPhone base major: 18 | 26 | 27 (default 26).")
    var baseOS: String = "26"
    @Flag(name: .customLong("base-unknown"), help: "Model an unreadable base ProductVersion (strict: required version-gated declarations become indeterminate).")
    var baseUnknown = false
    @Flag(name: .customLong("frida"), help: "Model the --frida opt-in (jb/exp only).")
    var frida = false
    @Flag(name: .customLong("no-cloudos-frida-capable"), help: "Model a cloudOS kernel below 26.4 (Frida steps unavailable).")
    var noCloudFridaCapable = false
    @Flag(name: .customLong("force-exc-guard"), help: "Model the forced EXC_GUARD disable.")
    var forceExcGuard = false
    @Option(name: .customLong("select"), parsing: .upToNextOption, help: "Explicitly select declaration id(s) (repeatable); unknown or not-implemented ids are refused.")
    var select: [String] = []
    @Option(name: .customLong("block"), parsing: .upToNextOption, help: "Explicitly block declaration id(s) (repeatable).")
    var block: [String] = []
    @Flag(help: "Emit JSON.") var json = false

    func gates(for pipelineVariant: FirmwarePipeline.Variant) -> PatchGateSnapshot {
        let is18 = !baseUnknown && baseOS == "18"
        let is27 = !baseUnknown && baseOS == "27"
        let cloudCapable = !noCloudFridaCapable
        let excGuardActive = pipelineVariant == .dev || is18 || forceExcGuard
        return PatchGateSnapshot(
            variant: pipelineVariant.rawValue,
            iosBaseIs18: is18, iosBaseIs27: is27,
            cloudOSIsFridaCapable: cloudCapable,
            forceExcGuard: forceExcGuard, enableFrida: frida,
            excGuardActive: excGuardActive, applyIOS27: is27,
            applyFrida: frida && cloudCapable)
    }

    func run() throws {
        let variants: [FirmwarePipeline.Variant] = all
            ? [.regular, .dev, .jb, .exp, .less]
            : [variant.pipelineVariant]
        var plans: [VariantPlanResolver.VariantPlan] = []
        for v in variants {
            let plan = try VariantPlanResolver.resolve(
                variant: v, gates: gates(for: v), baseVersionKnown: !baseUnknown,
                select: Set(select), block: Set(block))
            plans.append(plan)
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(all ? plans : [plans[0]])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        for plan in plans { printPlan(plan) }
    }

    private func printPlan(_ plan: VariantPlanResolver.VariantPlan) {
        print("== variant \(plan.variant)  (upstream \(plan.upstreamTag)) ==")
        print("   gates: \(plan.gates.summary)")
        func section(_ title: String, _ entries: [VariantPlanResolver.Entry]) {
            guard !entries.isEmpty else { return }
            print("   \(title) (\(entries.count)):")
            for entry in entries {
                let req = entry.required ? " *required" : ""
                print("     - \(entry.id)\(req)  [\(entry.reason)]")
            }
        }
        section("selected", plan.selected)
        section("excluded: version", plan.excludedByVersion)
        section("excluded: opt-in", plan.excludedByOptIn)
        section("excluded: variant", plan.excludedByVariant)
        section("guest (uncovered this round)", plan.guestUncovered)
        section("not implemented", plan.notImplemented)
        print("   selected swift steps: \(plan.enabledStepIDs.count)")
    }
}
