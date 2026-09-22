import ArgumentParser
import Foundation
import VPhoneCore

extension VPhoneCreateStage: ExpressibleByArgument {}

struct VPhoneVMCreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a VM end-to-end (prepare → patch → restore → CFW → first boot)",
        discussion: "Runs the full pipeline for a fresh VM. Needs an internet connection "
            + "(IPSW download), a non-nested macOS host, and sudo (CFW host-mount). "
            + "The 'less' (patchless) variant must itself be run with sudo — the whole "
            + "create runs as root, not just the fw-patch stage.\n\n"
            + "Progress is checkpointed in <bundle>/.create-checkpoint. After an interruption, "
            + "`vm create --resume <name>` re-verifies completed stages and continues; "
            + "`vm create-status <name>` shows the checkpoint without changing anything.")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "new VM name (with --resume: the existing VM to continue)") var name: String
    @Flag(help: "Continue an interrupted create of an existing VM from its checkpoint") var resume = false
    @Option(name: .customLong("restart-from"), help: "(with --resume) rerun from this stage: prepare | patch | restore | cfw | first_boot | jb_finalize | verification")
    var restartFrom: VPhoneCreateStage?
    @Flag(name: .customLong("accept-tool-change"), help: "(with --resume) continue although the vphone-cli executable differs from the one recorded")
    var acceptToolChange = false
    @Option(name: [.customShort("V"), .long], help: "variant: regular | dev | jb | exp | less (default regular; with --resume: must match unless no affected stage ran)") var variant: String?
    @Option(name: .shortAndLong, help: "iPhone IPSW URL or local path") var iphoneSource: String?
    @Option(name: .shortAndLong, help: "cloudOS IPSW URL or local path") var cloudosSource: String?
    @Option(name: .shortAndLong, help: "Disk size (GB, default 64; with --resume: must equal the recorded size)") var diskSize: UInt64?
    @Option(name: .shortAndLong, help: "sudo password for the CFW host-mount install (via askpass; never logged)")
    var sudoPassword: String?
    @Option(name: [.customShort("b"), .long], help: "(exp only) rewrite ProductBuildVersion to this build id") var spoofBuild: String?
    @Flag(name: .customLong("force-dsc-maxslide"), help: "Zero the dyld cache maxSlide on non-27 bases (opt-in DSC-map fit)") var forceDSCMaxSlide = false
    @Flag(name: .customLong("frida"), help: "Opt in to Frida Stalker support: install re.frida.server (latest GitHub release) + jb/exp kernel relaxations") var frida = false
    @Flag(name: .customLong("root-popup"), help: "Elevate the CFW host-mount via macOS's native authentication dialog (osascript) instead of a sudo prompt") var rootPopup = false
    @Flag(help: "Prompt at first-boot stages instead of running non-interactively") var interactive = false
    @Flag(name: .customLong("keep-artifacts"), help: "Keep intermediate build artifacts (built restore firmware, extracted base-IPSW caches, extracted CFW input dirs) instead of removing them after use. Source archives (.ipsw / .tar.zst) are always kept. Without it, the built restore firmware is removed only after every stage that may need it has finished.")
    var keepArtifacts = false
    @Option(name: .shortAndLong, help: "Resource base override (default: inferred from the running binary path)")
    var projectRoot: String?
    @Flag(name: .customShort("v"), help: "Increase verbosity: -v tool detail, -vv guest serial, -vvv internal trace")
    var verboseCount: Int

    func validate() throws {
        if !resume, restartFrom != nil || acceptToolChange {
            throw ValidationError("--restart-from and --accept-tool-change require --resume")
        }
    }

    func run() throws {
        let resources = projectRoot.map { VPhoneResources(base: URL(fileURLWithPath: $0)) } ?? .resolve()
        let selfExe = VPhoneResources.runningExecutable()
        let orchestrator = VPhoneCreateOrchestrator(
            library: lib.library, resources: resources, selfExecutable: selfExe)
        if resume {
            // Flags can only be observed when set; an unset flag keeps the recorded value.
            try orchestrator.resume(.init(
                name: name,
                overrides: .init(
                    variant: variant, iphoneSource: iphoneSource, cloudosSource: cloudosSource,
                    spoofBuild: spoofBuild, forceDscMaxSlide: forceDSCMaxSlide ? true : nil,
                    enableFrida: frida ? true : nil, diskSizeGb: diskSize),
                restartFrom: restartFrom, acceptToolChange: acceptToolChange,
                sudoPassword: sudoPassword, rootPopup: rootPopup, interactive: interactive,
                verbosity: VPhoneVerbosity(count: verboseCount), keepArtifacts: keepArtifacts))
            return
        }
        // Prompt for any firmware component not supplied on the command line.
        let sources = try VPhoneFirmwareSelection.resolve(iphone: iphoneSource, cloudos: cloudosSource)
        try orchestrator.run(.init(
            name: name, variant: variant ?? "regular",
            iphoneSource: sources.iphoneSource, cloudosSource: sources.cloudosSource,
            sudoPassword: sudoPassword, spoofBuild: spoofBuild, forceDSCMaxSlide: forceDSCMaxSlide,
            enableFrida: frida, rootPopup: rootPopup,
            interactive: interactive, diskSizeGB: diskSize ?? 64,
            verbosity: VPhoneVerbosity(count: verboseCount),
            keepArtifacts: keepArtifacts))
    }
}

// MARK: - create-status

/// Read-only view of a create checkpoint plus live facts that decide what a
/// resume would do. Takes no lock and writes nothing.
struct VPhoneVMCreateStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create-status", abstract: "Show the create checkpoint of a VM (read-only)")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Flag(name: .shortAndLong, help: "Emit JSON") var json = false

    func run() throws {
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let bundleURL = try lib.library.bundle(named: name).url
        let report = VPhoneCreateStatusReport.make(bundleURL: bundleURL)
        if json {
            print(String(decoding: try VPhoneCreateJSON.encoder.encode(report), as: UTF8.self))
        } else {
            print(report.text)
        }
        if report.checkpointError != nil { throw ExitCode(2) }
    }
}

struct VPhoneCreateStatusReport: Encodable {
    struct Live: Encodable {
        var createRunInProgress: Bool
        var bundleLockHeld: Bool
        var firmwareTransaction: VPhoneCreateRecoveryRequirement?
    }

    /// Status shown by this view: `running` while a create/resume run holds
    /// the checkpoint's run lock, otherwise the checkpoint's derived status.
    /// Only the view says `running`; resume decides from `checkpointOverallStatus`.
    static let runningStatus = "running"

    var bundle: String
    var checkpointError: String?
    var overallStatus: String?
    /// Status derived from the stored stages alone (a live run shows `interrupted`).
    var checkpointOverallStatus: VPhoneCreateOverallStatus?
    var nextStage: VPhoneCreateStage?
    var live: Live
    var checkpoint: VPhoneCreateCheckpoint?

    static func make(bundleURL: URL) -> VPhoneCreateStatusReport {
        let live = Live(
            createRunInProgress: VPhoneCreateCheckpointStore.isRunLockHeld(bundleURL: bundleURL),
            bundleLockHeld: VPhoneVMLockProbe.isLockHeld(directory: bundleURL),
            firmwareTransaction: VPhoneCreateRunner.firmwareTransactionRequirement(bundleURL: bundleURL))
        do {
            let checkpoint = try VPhoneCreateCheckpointStore.load(bundleURL: bundleURL).checkpoint
            let derived = checkpoint.overallStatus
            return .init(
                bundle: bundleURL.path, checkpointError: nil,
                overallStatus: live.createRunInProgress ? runningStatus : derived.rawValue,
                checkpointOverallStatus: derived, nextStage: checkpoint.nextStage, live: live, checkpoint: checkpoint)
        } catch {
            return .init(
                bundle: bundleURL.path, checkpointError: "\(error)", overallStatus: nil, checkpointOverallStatus: nil,
                nextStage: nil, live: live, checkpoint: nil)
        }
    }

    var text: String {
        var lines = ["bundle:   \(bundle)"]
        if let checkpointError { lines.append("checkpoint: \(checkpointError)") }
        if let checkpoint {
            if live.createRunInProgress {
                lines.append("overall:  \(Self.runningStatus) (a create/resume run holds the checkpoint; "
                    + "stored stages alone read \(checkpoint.overallStatus.rawValue))")
            } else {
                lines.append("overall:  \(checkpoint.overallStatus.rawValue)")
            }
            lines.append("variant:  \(checkpoint.effectiveOptions.variant)")
            lines.append("creation: \(checkpoint.creationId)  attempt: \(checkpoint.attemptId)  attempts: \(checkpoint.attempts.count)")
            for record in checkpoint.stages {
                var line = "  \(record.stage.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)) \(record.status.rawValue)"
                if let reason = record.reason { line += " — \(reason)" }
                if let error = record.error { line += " — \(error)" }
                if !record.history.isEmpty { line += " [\(record.history.count) earlier]" }
                lines.append(line)
            }
            for artifact in checkpoint.artifacts where artifact.availability == .removed {
                lines.append("removed:  \(artifact.relativePath) (\(artifact.name)); rebuild: \(artifact.rebuild ?? "-")")
            }
            if let requirement = checkpoint.recoveryRequired {
                lines.append("recovery: \(requirement.detail); \(requirement.action)")
            }
            if let next = checkpoint.nextStage { lines.append("next:     \(next.rawValue)") }
        }
        lines.append("bundle lock held: \(live.bundleLockHeld)")
        if let transaction = live.firmwareTransaction {
            lines.append("firmware transaction: \(transaction.detail); \(transaction.action)")
        }
        return lines.joined(separator: "\n")
    }
}
