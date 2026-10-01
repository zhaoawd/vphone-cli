import Darwin
import Foundation
import Testing
import VPhoneCore
@testable import VPhoneLaunchpadKit

// MARK: - Checkpoint fixtures

/// Checkpoints made with `VPhoneCreateCheckpoint` and encoded with
/// `VPhoneCreateJSON.encoder`, the CLI's own writer. Every fixture passes
/// `VPhoneCreateCheckpointStore.load`, which validates it.
enum CheckpointFixture {
    static let start = Date(timeIntervalSince1970: 1_790_000_000)

    static func make(variant: String = "regular", tool: String? = "aaa",
                     _ edit: (inout VPhoneCreateCheckpoint) throws -> Void = { _ in }) rethrows -> VPhoneCreateCheckpoint {
        let options = VPhoneCreateEffectiveOptions(
            variant: variant, iphoneSource: "https://updates.example.invalid/iPhone.ipsw",
            cloudosSource: "/fixture/cloudOS.ipsw", spoofBuild: nil, forceDscMaxSlide: false, enableFrida: false,
            cpuCount: 8, memoryMb: 8192, diskSizeGb: 64)
        var checkpoint = VPhoneCreateCheckpoint(
            identity: .init(name: "m", path: "/fixture/m", directoryId: "1:2"), options: options,
            tool: .init(executableSha256: tool, stageContractVersion: VPhoneCreateCheckpoint.stageContractVersion),
            now: start)
        try edit(&checkpoint)
        return checkpoint
    }

    private static func index(_ checkpoint: VPhoneCreateCheckpoint, _ stage: VPhoneCreateStage) -> Int {
        checkpoint.stages.firstIndex { $0.stage == stage }!
    }

    /// A stage the executor completed and the verifier accepted, or (with a
    /// reason) one recorded as `unverified`.
    static func done(_ checkpoint: inout VPhoneCreateCheckpoint, _ stages: VPhoneCreateStage..., unverified reason: String? = nil) {
        for stage in stages {
            let i = index(checkpoint, stage)
            checkpoint.stages[i].status = reason == nil ? .succeeded : .unverified
            checkpoint.stages[i].reason = reason
            checkpoint.stages[i].attemptId = checkpoint.attemptId
            checkpoint.stages[i].executorResult = "completed"
            checkpoint.stages[i].verifierVersion = "1"
            checkpoint.stages[i].startedAt = start.addingTimeInterval(Double(i) * 60)
            checkpoint.stages[i].finishedAt = start.addingTimeInterval(Double(i) * 60 + 59)
        }
    }

    static func began(_ checkpoint: inout VPhoneCreateCheckpoint, _ stage: VPhoneCreateStage,
                      _ status: VPhoneCreateStageStatus, error: String? = nil) {
        let i = index(checkpoint, stage)
        checkpoint.stages[i].status = status
        checkpoint.stages[i].attemptId = checkpoint.attemptId
        checkpoint.stages[i].startedAt = start.addingTimeInterval(Double(i) * 60)
        checkpoint.stages[i].error = error
        if status != .running {
            checkpoint.stages[i].finishedAt = start.addingTimeInterval(Double(i) * 60 + 30)
        }
    }

    /// Every applicable stage done.
    static func finished(variant: String = "regular") -> VPhoneCreateCheckpoint {
        make(variant: variant) { checkpoint in
            let applicable = checkpoint.stages.filter { $0.status != .notApplicable }.map(\.stage)
            for stage in applicable {
                done(&checkpoint, stage)
            }
        }
    }

    static func recovery(_ json: String) throws -> VPhoneCreateRecoveryRequirement {
        try VPhoneCreateJSON.decoder.decode(VPhoneCreateRecoveryRequirement.self, from: Data(json.utf8))
    }

    static func data(_ checkpoint: VPhoneCreateCheckpoint) throws -> Data {
        try checkpoint.validate()
        return try VPhoneCreateJSON.encoder.encode(checkpoint)
    }

    /// Writes `<bundle>/.create-checkpoint/checkpoint.json`.
    static func write(_ checkpoint: VPhoneCreateCheckpoint, to bundle: URL) throws {
        let directory = bundle.appendingPathComponent(VPhoneCreateCheckpointStore.directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data(checkpoint).write(to: directory.appendingPathComponent(VPhoneCreateCheckpointStore.fileName))
    }
}

/// The JSON `vm create-status --json` prints: the same fields as
/// `VPhoneCreateStatusReport` (`sources/vphone-cli/VPhoneVMCreateCLI.swift`),
/// encoded with `VPhoneCreateJSON.encoder`. `RealCLICreateTests` checks the
/// decoder against the real command.
struct CreateStatusMirror: Encodable {
    struct Live: Encodable {
        var createRunInProgress: Bool
        var bundleLockHeld: Bool
        var firmwareTransaction: VPhoneCreateRecoveryRequirement?
    }

    var bundle: String
    var checkpointError: String?
    var overallStatus: String?
    var checkpointOverallStatus: VPhoneCreateOverallStatus?
    var nextStage: VPhoneCreateStage?
    var live: Live
    var checkpoint: VPhoneCreateCheckpoint?

    static func after(_ checkpoint: VPhoneCreateCheckpoint) -> Self {
        Self(bundle: "/fixture/m", overallStatus: checkpoint.overallStatus.rawValue,
             checkpointOverallStatus: checkpoint.overallStatus, nextStage: checkpoint.nextStage,
             live: .init(createRunInProgress: false, bundleLockHeld: false), checkpoint: checkpoint)
    }

    func data() throws -> Data {
        try VPhoneCreateJSON.encoder.encode(self)
    }
}

// MARK: - Commands

@Suite struct CreateCommandTests {
    static let root = "/Users/fixture/VMs"
    static let iphone = "https://updates.example.invalid/iPhone17,3_26.1_23B85_Restore.ipsw"
    static let cloudOS = "/Volumes/IPSW/cloudOS.ipsw"

    static func request(_ variant: VPhoneLaunchpadCreateVariant = .regular) -> VPhoneLaunchpadCreateRequest {
        VPhoneLaunchpadCreateRequest(name: "pcc-research-01", libraryRoot: root, variant: variant,
                                     iphoneSource: iphone, cloudosSource: cloudOS)
    }

    @Test func createPassesTheRootPopupAndOnlyTheDefaults() throws {
        let command = try #require(VPhoneLaunchpadCreateCommand.create(Self.request()))
        #expect(command.kind == .create)
        #expect(command.arguments == [
            "vm", "create", "pcc-research-01", "--library-root", Self.root, "--variant", "regular",
            "--iphone-source", Self.iphone, "--cloudos-source", Self.cloudOS, "--disk-size", "64", "--root-popup",
        ])
    }

    @Test func noCommandCarriesAPasswordOrInteractivePrompts() throws {
        var requests: [VPhoneLaunchpadCreateRequest] = []
        for variant in VPhoneLaunchpadCreateVariant.allCases where variant.isAvailable {
            var request = Self.request(variant)
            request.keepArtifacts = true
            request.frida = true
            request.spoofBuild = variant == .exp ? "23B85" : ""
            request.restoreBackend = .native
            requests.append(request)
        }
        var commands = try requests.map { try #require(VPhoneLaunchpadCreateCommand.create($0)) }
        let machine = VPhoneLaunchpadMachinePath(libraryRoot: Self.root, name: "m")
        for variant in ["regular", "dev", "jb", "exp"] {
            commands.append(try #require(VPhoneLaunchpadCreateCommand.resume(machine, variant: variant)))
            commands.append(try #require(VPhoneLaunchpadCreateCommand.resume(
                machine, variant: variant, restartFrom: .cfw, acceptToolChange: true, keepArtifacts: true)))
        }
        commands.append(try #require(VPhoneLaunchpadCreateCommand.status(machine)))
        commands.append(VPhoneLaunchpadCreateCommand.catalog)
        for command in commands {
            #expect(!command.arguments.contains("--sudo-password"))
            #expect(!command.arguments.contains { $0.hasPrefix("--sudo-password") || $0 == "-s" })
            #expect(!command.arguments.contains("--interactive"))
            #expect(!command.arguments.contains("--dfu"))
            // Every create and resume elevates only through the system dialog.
            if command.kind == .create || command.kind == .resume {
                #expect(command.arguments.filter { $0 == "--root-popup" }.count == 1)
            } else {
                #expect(!command.arguments.contains("--root-popup"))
            }
        }
    }

    @Test func lessIsNotOffered() {
        #expect(!VPhoneLaunchpadCreateVariant.less.isAvailable)
        #expect(VPhoneLaunchpadCreateVariant.allCases.filter(\.isAvailable).map(\.rawValue) == ["regular", "dev", "jb", "exp"])
        #expect(VPhoneLaunchpadCreateCommand.create(Self.request(.less)) == nil)
        #expect(VPhoneLaunchpadCreateCommand.refusal(Self.request(.less)) == .variantUnavailable)
        let machine = VPhoneLaunchpadMachinePath(libraryRoot: Self.root, name: "m")
        #expect(VPhoneLaunchpadCreateCommand.resume(machine, variant: "less") == nil)
        #expect(VPhoneLaunchpadCreateCommand.resume(machine, variant: "other") == nil)
    }

    @Test func backendsAndOptionsAppearOnlyWhenChosen() throws {
        var request = Self.request(.exp)
        request.keepArtifacts = true
        request.frida = true
        request.spoofBuild = " 23B85 "
        request.diskSizeGB = 128
        request.prepareBackend = .script
        request.restoreBackend = .python
        let command = try #require(VPhoneLaunchpadCreateCommand.create(request))
        #expect(Array(command.arguments.suffix(10)) == [
            "128", "--root-popup", "--keep-artifacts", "--frida", "--spoof-build", "23B85",
            "--prepare-backend", "script", "--restore-backend", "python",
        ])
        let plain = try #require(VPhoneLaunchpadCreateCommand.create(Self.request(.jb)))
        #expect(!plain.arguments.contains("--prepare-backend"))
        #expect(!plain.arguments.contains("--restore-backend"))
        #expect(!plain.arguments.contains("--keep-artifacts"))
        #expect(!plain.arguments.contains("--frida"))
    }

    @Test func requestsTheCLIWouldRejectAreRefused() {
        func refusal(_ edit: (inout VPhoneLaunchpadCreateRequest) -> Void) -> VPhoneLaunchpadCreateCommand.Refusal? {
            var request = Self.request()
            edit(&request)
            #expect((VPhoneLaunchpadCreateCommand.create(request) == nil) == (VPhoneLaunchpadCreateCommand.refusal(request) != nil))
            return VPhoneLaunchpadCreateCommand.refusal(request)
        }
        #expect(refusal { $0.name = "-rf" } == .name)
        #expect(refusal { $0.name = "a/b" } == .name)
        #expect(refusal { $0.name = "" } == .name)
        #expect(refusal { $0.libraryRoot = "relative/VMs" } == .location)
        #expect(refusal { $0.libraryRoot = "/" + String(repeating: "x", count: 120) } == .location)
        #expect(refusal { $0.iphoneSource = "" } == .source)
        #expect(refusal { $0.iphoneSource = "--sudo-password=x" } == .source)
        #expect(refusal { $0.cloudosSource = "relative.ipsw" } == .source)
        #expect(refusal { $0.cloudosSource = "ftp://host/cloudOS.ipsw" } == .source)
        #expect(refusal { $0.cloudosSource = "/a.ipsw\n--interactive" } == .source)
        #expect(refusal { $0.diskSizeGB = 16 } == .diskSize)
        #expect(refusal { $0.spoofBuild = "23B85" } == .spoofBuild)
        #expect(refusal { $0.variant = .exp; $0.spoofBuild = "23B85; rm" } == .spoofBuild)
        #expect(refusal { $0.prepareBackend = .native } == .nativePrepareNeedsFiles)
        #expect(refusal { $0.prepareBackend = .native; $0.iphoneSource = "/a/iPhone.ipsw" } == nil)
    }

    @Test func resumeStatusAndCatalogArguments() throws {
        let machine = VPhoneLaunchpadMachinePath(libraryRoot: Self.root, name: "m")
        #expect(try #require(VPhoneLaunchpadCreateCommand.resume(machine, variant: "jb")).arguments == [
            "vm", "create", "m", "--resume", "--library-root", Self.root, "--root-popup",
        ])
        #expect(try #require(VPhoneLaunchpadCreateCommand.resume(
            machine, variant: "dev", restartFrom: .firstBoot, acceptToolChange: true, keepArtifacts: true)).arguments == [
            "vm", "create", "m", "--resume", "--library-root", Self.root, "--root-popup",
            "--restart-from", "first_boot", "--accept-tool-change", "--keep-artifacts",
        ])
        #expect(try #require(VPhoneLaunchpadCreateCommand.status(machine)).arguments == [
            "vm", "create-status", "m", "--json", "--library-root", Self.root,
        ])
        #expect(VPhoneLaunchpadCreateCommand.catalog.arguments == ["fw", "catalog", "--json"])
        #expect(VPhoneLaunchpadCreateCommand.status(.init(libraryRoot: "rel", name: "m")) == nil)
        #expect(VPhoneLaunchpadCreateCommand.resume(.init(libraryRoot: Self.root, name: "-m"), variant: "regular") == nil)
    }

    @Test func catalogDecodesTheCLIReport() throws {
        let data = try JSONEncoder().encode(VPhoneFirmwareCatalog.report)
        let catalog = try VPhoneLaunchpadFirmwareCatalog.decode(
            .fixture(status: 0, output: String(decoding: data, as: UTF8.self)))
        #expect(catalog.device == VPhoneFirmwareCatalog.report.device)
        #expect(catalog.pairings.map(\.iosURL) == VPhoneFirmwareCatalog.report.pairings.map(\.ios.url))
        #expect(catalog.pairings.map(\.cloudOSURL) == VPhoneFirmwareCatalog.report.pairings.map(\.recommendedCloudOS.url))
        #expect(throws: VPhoneLaunchpadError.self) {
            try VPhoneLaunchpadFirmwareCatalog.decode(.fixture(status: 64, output: "Error: x"))
        }
        let pairing = VPhoneLaunchpadFirmwareCatalog.Pairing(
            iosName: "26.1", iosURL: "https://x/iPhone17,3_26.1_23B85_Restore.ipsw", cloudOSName: "c", cloudOSURL: "u")
        #expect(pairing.build == "23B85")
    }
}

// MARK: - Checkpoint to UI state

@Suite struct CreateProgressTests {
    typealias Tone = VPhoneLaunchpadCreateProgress.Tone

    /// Round trip through the file and the lock-free loader.
    static func read(_ checkpoint: VPhoneCreateCheckpoint, live: Bool = false) throws -> VPhoneLaunchpadCreateProgress {
        let temp = try LaunchpadTemporaryDirectory("launchpad-progress")
        let machine = VPhoneLaunchpadMachinePath(libraryRoot: temp.canonicalPath, name: "m")
        try CheckpointFixture.write(checkpoint, to: machine.url)
        return try #require(VPhoneLaunchpadCreateProgress.read(machine, live: live)).get()
    }

    static func tones(_ progress: VPhoneLaunchpadCreateProgress) -> [String: Tone] {
        Dictionary(uniqueKeysWithValues: progress.stages.map { ($0.name, $0.tone) })
    }

    @Test func freshRegularCreateIsIncompleteAndJBFinalizeDoesNotApply() throws {
        let progress = try Self.read(CheckpointFixture.make())
        #expect(progress.overallStatus == "incomplete")
        #expect(progress.overallTone == .pending)
        #expect(progress.nextStage == .prepare)
        #expect(progress.stages.map(\.name) == ["prepare", "patch", "restore", "cfw", "first_boot", "jb_finalize", "verification"])
        #expect(progress.stages.map(\.status) == ["pending", "pending", "pending", "pending", "pending", "not_applicable", "pending"])
        let jb = try #require(progress.stages.first { $0.stage == .jbFinalize })
        #expect(jb.tone == .notApplicable)
        #expect(jb.note == "jb_finalize applies only to variants jb and exp")
        #expect(progress.toolchainSha256 == "aaa")
    }

    @Test func lessMarksCFWAndJBFinalizeNotApplicable() throws {
        let progress = try Self.read(CheckpointFixture.make(variant: "less"))
        #expect(Self.tones(progress)["cfw"] == .notApplicable)
        #expect(Self.tones(progress)["jb_finalize"] == .notApplicable)
        #expect(progress.stages.first { $0.stage == .cfw }?.status == "not_applicable")
        #expect(progress.variant == "less")
    }

    @Test func unverifiedNeverReadsAsPassed() throws {
        let checkpoint = CheckpointFixture.make(variant: "jb") { checkpoint in
            CheckpointFixture.done(&checkpoint, .prepare, .patch, .restore, .cfw, .firstBoot)
            CheckpointFixture.done(&checkpoint, .jbFinalize, unverified: "no setup log evidence")
            CheckpointFixture.done(&checkpoint, .verification)
        }
        let progress = try Self.read(checkpoint)
        #expect(progress.overallStatus == "completed_unverified")
        #expect(progress.overallTone == .warning)
        let stage = try #require(progress.stages.first { $0.stage == .jbFinalize })
        #expect(stage.status == "unverified")
        #expect(stage.tone == .warning)
        #expect(stage.note == "no setup log evidence")
        #expect(progress.nextStage == nil)
        #expect(Self.tones(progress).values.filter { $0 == .passed }.count == 6)
        // Every stage is done, so any stage may be restarted.
        #expect(progress.restartableStages == VPhoneCreateStage.allCases)
    }

    @Test func allStagesDoneIsTheOnlyPassedOverall() throws {
        let progress = try Self.read(CheckpointFixture.finished())
        #expect(progress.overallStatus == "succeeded")
        #expect(progress.overallTone == .passed)
        #expect(VPhoneLaunchpadCreateProgress.tone(.completedUnverified) == .warning)
        #expect(VPhoneLaunchpadCreateProgress.tone(.recoveryRequired) == .failed)
        #expect(VPhoneLaunchpadCreateProgress.tone(.unverified, live: true) == .warning)
    }

    @Test func aRunningStageIsUnderWayOnlyWhileTheOwnRunLives() throws {
        let checkpoint = CheckpointFixture.make { checkpoint in
            CheckpointFixture.done(&checkpoint, .prepare)
            CheckpointFixture.began(&checkpoint, .patch, .running)
        }
        let live = try Self.read(checkpoint, live: true)
        #expect(live.overallStatus == "running")
        #expect(live.overallTone == .running)
        #expect(Self.tones(live)["patch"] == .running)
        let ended = try Self.read(checkpoint, live: false)
        #expect(ended.overallStatus == "interrupted")
        #expect(ended.overallTone == .warning)
        #expect(Self.tones(ended)["patch"] == .warning)
        #expect(ended.stages.first { $0.stage == .patch }?.status == "running")
        #expect(ended.restartableStages == [.prepare, .patch])
    }

    @Test func recoveryRequiredAndFailuresKeepTheirNames() throws {
        let requirement = try CheckpointFixture.recovery(
            #"{"kind":"firmware_transaction","stage":"patch","detail":"a fw patch transaction is pending","action":"run vphone-cli fw patch --recover m"}"#)
        let checkpoint = CheckpointFixture.make { checkpoint in
            CheckpointFixture.done(&checkpoint, .prepare)
            CheckpointFixture.began(&checkpoint, .patch, .failed, error: "stage patch failed: exit 1")
            checkpoint.recoveryRequired = requirement
        }
        let progress = try Self.read(checkpoint)
        #expect(progress.overallStatus == "recovery_required")
        #expect(progress.overallTone == .failed)
        #expect(progress.recovery == .init(kind: "firmware_transaction", stage: "patch",
                                           detail: "a fw patch transaction is pending",
                                           action: "run vphone-cli fw patch --recover m"))
        let patch = try #require(progress.stages.first { $0.stage == .patch })
        #expect(patch.status == "failed")
        #expect(patch.tone == .failed)
        #expect(patch.note == "stage patch failed: exit 1")

        let cancelled = try Self.read(CheckpointFixture.make { checkpoint in
            CheckpointFixture.began(&checkpoint, .prepare, .cancelled)
        })
        #expect(cancelled.overallStatus == "cancelled")
        #expect(cancelled.overallTone == .warning)
    }

    @Test func missingAndUnreadableCheckpoints() throws {
        let temp = try LaunchpadTemporaryDirectory("launchpad-progress")
        let machine = VPhoneLaunchpadMachinePath(libraryRoot: temp.canonicalPath, name: "m")
        #expect(VPhoneLaunchpadCreateProgress.read(machine, live: false) == nil)
        let directory = machine.url.appendingPathComponent(VPhoneCreateCheckpointStore.directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: directory.appendingPathComponent(VPhoneCreateCheckpointStore.fileName))
        guard case let .failure(error)? = VPhoneLaunchpadCreateProgress.read(machine, live: false) else {
            Issue.record("expected an unreadable checkpoint")
            return
        }
        #expect(error.message.contains("unreadable"))
    }

    @Test func createStatusDecodesTheCLIFields() throws {
        let checkpoint = CheckpointFixture.make { CheckpointFixture.done(&$0, .prepare) }
        let transaction = try CheckpointFixture.recovery(
            #"{"kind":"firmware_transaction","detail":"pending","action":"recover"}"#)
        var mirror = CreateStatusMirror.after(checkpoint)
        mirror.live = .init(createRunInProgress: false, bundleLockHeld: true, firmwareTransaction: transaction)
        let status = try VPhoneLaunchpadCreateStatus.decode(
            .fixture(status: 0, output: String(decoding: try mirror.data(), as: UTF8.self)))
        #expect(status.overallStatus == "incomplete")
        #expect(status.nextStage == "patch")
        #expect(status.live.bundleLockHeld)
        #expect(!status.live.createRunInProgress)
        #expect(status.live.firmwareTransaction?.detail == "pending")
        // Exit 2 still carries the report, with the checkpoint error.
        let broken = CreateStatusMirror(bundle: "/fixture/m", checkpointError: "create checkpoint is unreadable: x",
                                        live: .init(createRunInProgress: false, bundleLockHeld: false))
        let unreadable = try VPhoneLaunchpadCreateStatus.decode(
            .fixture(status: 2, output: String(decoding: try broken.data(), as: UTF8.self)))
        #expect(unreadable.checkpointError == "create checkpoint is unreadable: x")
        #expect(throws: VPhoneLaunchpadError.self) {
            try VPhoneLaunchpadCreateStatus.decode(.fixture(status: 1, output: "Error: VM 'm' not found"))
        }
    }

    @Test func toolChangeIsReadFromTheCLIError() {
        let lines = [
            "[-] vm create --resume refused: the CLI/VM toolchain differs from the one recorded in the checkpoint (aaaaaaaaaaaa -> bbbbbbbbbbbb); the checkpoint was not changed (overall: failed).",
            "    action: to continue with this build: vphone-cli vm create --resume m --accept-tool-change",
            "Error: CLI/VM toolchain changed since the checkpoint (aaaaaaaaaaaaaaaa -> bbbbbbbbbbbbbbbb); pass --accept-tool-change to resume with this build",
        ]
        #expect(VPhoneLaunchpadToolChange.parse(lines) == .init(recorded: "aaaaaaaaaaaaaaaa", current: "bbbbbbbbbbbbbbbb"))
        #expect(VPhoneLaunchpadToolChange.parse(["Error: CLI/VM toolchain changed since the checkpoint (unknown -> cc); pass"])
            == .init(recorded: "unknown", current: "cc"))
        #expect(VPhoneLaunchpadToolChange.parse(["Error: stage patch failed: exit 1"]) == nil)
    }
}

// MARK: - Stand-in vphone-cli for vm create

/// A shell script in place of `vphone-cli`. Every call appends its arguments
/// to `arguments.log` in the control folder.
///
/// - `vm list` prints `<root>/.list.json` or `[]`.
/// - `vm create <name>` makes `<root>/<name>/.create-checkpoint/` and acts by
///   `create.mode` (`--resume`: `resume.mode`):
///   - `hang`: copies `running.json` in, records its PID, then runs
///     `middle.sh`, which records its PID and runs `inner.sh`, which records
///     its PID and becomes `sleep 30`. Three processes, one group, all in
///     the foreground; none handles SIGINT.
///   - `toolchange`: without `--accept-tool-change` prints the CLI's
///     tool-change refusal and exits 1; with it, as `done`.
///   - `done` (default): copies `done.json` in and exits 0.
/// - `vm create-status` prints `status.json`.
struct CreateStandIn {
    let temp: LaunchpadTemporaryDirectory
    let root: String
    let logs: URL
    let control: URL
    let script: URL

    init() throws {
        temp = try LaunchpadTemporaryDirectory(short: "lpc")
        control = temp.url
        let rootURL = temp.url.appendingPathComponent("lib", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        root = VPhoneLaunchpadMachineLocations.canonical(rootURL)
        logs = temp.url.appendingPathComponent("Logs", isDirectory: true)
        script = temp.url.appendingPathComponent("vphone-cli")
        let c = control.path
        try Self.write("""
        #!/bin/sh
        c='\(c)'
        echo "$*" >> "$c/arguments.log"
        root=""; prev=""
        for a in "$@"; do
          if [ "$prev" = "--library-root" ]; then root="$a"; fi
          prev="$a"
        done
        case "$1 $2" in
        "vm list")
          if [ -e "$root/.list.json" ]; then cat "$root/.list.json"; else echo '[]'; fi ;;
        "vm create")
          name="$3"
          mkdir -p "$root/$name/.create-checkpoint"
          case " $* " in
          *" --resume "*) mode=$(cat "$c/resume.mode" 2>/dev/null || echo done) ;;
          *) mode=$(cat "$c/create.mode" 2>/dev/null || echo done) ;;
          esac
          echo "create $name mode $mode"
          case "$mode" in
          hang)
            cp "$c/running.json" "$root/$name/.create-checkpoint/checkpoint.json"
            echo $$ >> "$c/pids"
            "$c/middle.sh" "$c"
            echo "outer after middle" ;;
          toolchange)
            case " $* " in
            *" --accept-tool-change "*)
              cp "$c/done.json" "$root/$name/.create-checkpoint/checkpoint.json"; echo "=== Done ===" ;;
            *)
              echo "[-] vm create --resume refused: the CLI/VM toolchain differs from the one recorded in the checkpoint (aaaaaaaaaaaa -> bbbbbbbbbbbb); the checkpoint was not changed (overall: failed)."
              echo "Error: CLI/VM toolchain changed since the checkpoint (aaa -> bbb); pass --accept-tool-change to resume with this build" >&2
              exit 1 ;;
            esac ;;
          *)
            cp "$c/done.json" "$root/$name/.create-checkpoint/checkpoint.json"; echo "=== Done ===" ;;
          esac ;;
        "vm create-status")
          cat "$c/status.json" ;;
        *) exit 99 ;;
        esac
        """, to: script)
        try Self.write("""
        #!/bin/sh
        echo $$ >> "$1/pids"
        "$1/inner.sh" "$1"
        echo "middle after inner"
        """, to: control.appendingPathComponent("middle.sh"))
        try Self.write("""
        #!/bin/sh
        echo $$ >> "$1/pids"
        exec sleep 30
        """, to: control.appendingPathComponent("inner.sh"))
        try CheckpointFixture.data(CheckpointFixture.make { checkpoint in
            CheckpointFixture.began(&checkpoint, .prepare, .running)
        }).write(to: control.appendingPathComponent("running.json"))
        try CheckpointFixture.data(CheckpointFixture.finished()).write(to: control.appendingPathComponent("done.json"))
        try CreateStatusMirror.after(CheckpointFixture.finished()).data().write(to: control.appendingPathComponent("status.json"))
    }

    private static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func mode(create: String? = nil, resume: String? = nil) throws {
        if let create {
            try create.write(to: control.appendingPathComponent("create.mode"), atomically: true, encoding: .utf8)
        }
        if let resume {
            try resume.write(to: control.appendingPathComponent("resume.mode"), atomically: true, encoding: .utf8)
        }
    }

    var arguments: [String] {
        ((try? String(contentsOf: control.appendingPathComponent("arguments.log"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    var pids: [pid_t] {
        ((try? String(contentsOf: control.appendingPathComponent("pids"), encoding: .utf8)) ?? "")
            .split(separator: "\n").compactMap { pid_t($0) }
    }

    func path(_ name: String) -> VPhoneLaunchpadMachinePath {
        VPhoneLaunchpadMachinePath(libraryRoot: root, name: name)
    }

    func request(_ name: String) -> VPhoneLaunchpadCreateRequest {
        VPhoneLaunchpadCreateRequest(name: name, libraryRoot: root, iphoneSource: CreateCommandTests.iphone,
                                     cloudosSource: CreateCommandTests.cloudOS)
    }

    @MainActor
    func library() async -> VPhoneLaunchpadMachineLibrary {
        let library = VPhoneLaunchpadMachineLibrary(
            defaults: InMemoryDefaults(), libraryRoot: root, logsDirectory: logs,
            runStateReader: VPhoneLaunchpadRunStateReader(readRecord: { _ in nil }, identity: { _ in nil })
        )
        library.startMonitoring(with: VPhoneLaunchpadCommandLine(executable: script, history: VPhoneLaunchpadCommandHistory()))
        library.stopMonitoring()
        await library.refresh()
        return library
    }
}

/// True once `pid` names no process, not even a zombie.
func isGone(_ pid: pid_t) -> Bool {
    kill(pid, 0) == -1 && errno == ESRCH
}

// MARK: - Create runs

@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct CreationRunTests {
    @Test func aNewMachineRunsVMCreateDetachedAndReadsStatusOnceAfterwards() async throws {
        let standIn = try CreateStandIn()
        let library = await standIn.library()
        let creation = try #require(library.create(standIn.request("n1")))
        #expect(library.selection == [standIn.path("n1")])
        #expect(await eventually { creation.exitStatus != nil && creation.status != nil })
        #expect(creation.exitStatus == 0)
        let progress = try #require(try creation.progress?.get())
        #expect(progress.overallStatus == "succeeded")
        #expect(try creation.status?.get().overallStatus == "succeeded")

        let creates = standIn.arguments.filter { $0.hasPrefix("vm create ") }
        #expect(creates == [
            "vm create n1 --library-root \(standIn.root) --variant regular --iphone-source \(CreateCommandTests.iphone) "
                + "--cloudos-source \(CreateCommandTests.cloudOS) --disk-size 64 --root-popup",
        ])
        #expect(standIn.arguments.filter { $0.hasPrefix("vm create-status") } == ["vm create-status n1 --json --library-root \(standIn.root)"])
        // The create log sits beside the console logs, with its own suffix.
        #expect(creation.logFile == standIn.logs.appendingPathComponent("n1-create.log"))
        let log = try String(contentsOf: creation.logFile, encoding: .utf8)
        #expect(log.contains("create n1 mode done"))
        // The folder now exists, so the name is taken.
        #expect(library.isTaken(standIn.path("n1")))
        #expect(library.create(standIn.request("n1")) == nil)
        #expect(standIn.arguments.filter { $0.hasPrefix("vm create ") }.count == 1)
    }

    @Test func cancellingInterruptsTheWholeProcessGroupAndRefreshNeverAsksForStatus() async throws {
        let standIn = try CreateStandIn()
        try standIn.mode(create: "hang")
        let library = await standIn.library()
        let machine = standIn.path("n2")
        let creation = try #require(library.create(standIn.request("n2")))
        #expect(await eventually { standIn.pids.count == 3 })
        #expect(await eventually {
            if case let .success(progress)? = creation.progress { return progress.overallStatus == "running" }
            return false
        })
        let group = try #require(creation.processGroup)
        let pids = standIn.pids
        #expect(pids.first == group)
        for pid in pids {
            #expect(getpgid(pid) == group)
        }
        #expect(getsid(group) == group)
        #expect(getpgid(0) != group)
        #expect(library.activity(of: machine) == String(localized: "Creating…"))
        #expect(!library.canStart(machine))
        #expect(!library.canStop(machine))
        #expect(VPhoneLaunchpadQuit.decision(library) == .confirm(machines: ["n2"]))

        // Periodic work while the run lives: list refreshes and the
        // checkpoint poll. Neither runs create-status.
        await library.refresh()
        await library.refresh()
        try await Task.sleep(for: .milliseconds(2500))
        #expect(standIn.arguments.filter { $0.contains("create-status") }.isEmpty)
        #expect(standIn.arguments.filter { $0.hasPrefix("vm list") }.count == 3)

        VPhoneLaunchpadQuit.confirmed(library)
        #expect(creation.cancelRequested)
        #expect(await eventually { !creation.isRunning && creation.status != nil })
        #expect(creation.exitStatus == SIGINT)
        #expect(await eventually { pids.allSatisfy(isGone) })
        #expect(killpg(group, 0) == -1 && errno == ESRCH)
        #expect(standIn.arguments.filter { $0.hasPrefix("vm create-status") }.count == 1)
        #expect(standIn.arguments.last?.hasPrefix("vm create-status") == true
            || standIn.arguments.suffix(2).contains { $0.hasPrefix("vm create-status") })
        // The stage left running reads as interrupted once the run is gone.
        let progress = try #require(try creation.progress?.get())
        #expect(progress.overallStatus == "interrupted")
        #expect(VPhoneLaunchpadQuit.decision(library) == .quit)
        #expect(!creation.cancel())
        let log = try String(contentsOf: creation.logFile, encoding: .utf8)
        #expect(!log.contains("outer after middle"))
        #expect(!log.contains("middle after inner"))
    }

    @Test func aChangedToolchainIsResumedOnlyAfterConfirmation() async throws {
        let standIn = try CreateStandIn()
        try standIn.mode(resume: "toolchange")
        let machine = standIn.path("m")
        try CheckpointFixture.write(CheckpointFixture.make(variant: "jb") { checkpoint in
            CheckpointFixture.done(&checkpoint, .prepare)
            CheckpointFixture.began(&checkpoint, .patch, .failed, error: "stage patch failed: exit 1")
        }, to: machine.url)
        let library = await standIn.library()
        let creation = library.creation(for: machine)
        await creation.reloadProgress()
        #expect(library.canResume(machine))

        library.resume(machine, restartFrom: .patch)
        #expect(await eventually { creation.exitStatus != nil && creation.status != nil })
        #expect(creation.exitStatus == 1)
        #expect(creation.toolChange == .init(recorded: "aaa", current: "bbb"))
        #expect(creation.lastResume?.restartFrom == .patch)
        let first = standIn.arguments.filter { $0.hasPrefix("vm create ") }
        #expect(first == ["vm create m --resume --library-root \(standIn.root) --root-popup --restart-from patch"])

        // Declining leaves the checkpoint and runs nothing.
        creation.dismissToolChange()
        #expect(creation.toolChange == nil)
        #expect(standIn.arguments.filter { $0.hasPrefix("vm create ") }.count == 1)

        // Confirming adds --accept-tool-change to the same request.
        library.resume(machine, restartFrom: creation.lastResume?.restartFrom, acceptToolChange: true)
        #expect(await eventually { creation.exitStatus == 0 && creation.status != nil })
        #expect(creation.toolChange == nil)
        #expect(standIn.arguments.filter { $0.hasPrefix("vm create ") }.last
            == "vm create m --resume --library-root \(standIn.root) --root-popup --restart-from patch --accept-tool-change")
        #expect(standIn.arguments.filter { $0.hasPrefix("vm create-status") }.count == 2)
        #expect(try creation.progress?.get().overallStatus == "succeeded")
        // A resume appends to the create log after a separator line.
        let log = try String(contentsOf: creation.logFile, encoding: .utf8)
        #expect(log.components(separatedBy: "--resume").count - 1 >= 2)
        #expect(log.contains("toolchain changed since the checkpoint"))
        #expect(log.contains("=== Done ==="))
    }

    @Test func lessAndBusyMachinesAreNotResumed() async throws {
        let standIn = try CreateStandIn()
        let machine = standIn.path("l")
        try CheckpointFixture.write(CheckpointFixture.make(variant: "less") { checkpoint in
            CheckpointFixture.began(&checkpoint, .prepare, .failed, error: "x")
        }, to: machine.url)
        let library = await standIn.library()
        let creation = library.creation(for: machine)
        await creation.reloadProgress()
        #expect(!library.canResume(machine))
        library.resume(machine)
        try await Task.sleep(for: .milliseconds(300))
        #expect(standIn.arguments.filter { $0.hasPrefix("vm create") }.isEmpty)
        #expect(!creation.isRunning)

        // No checkpoint read yet: nothing to resume from.
        let other = standIn.path("o")
        _ = library.creation(for: other)
        #expect(!library.canResume(other))
    }
}

// MARK: - Locations

@Suite struct LocationProblemTests {
    @Test func aWritableFolderAndAMissingOneBelowItAreAccepted() throws {
        let temp = try LaunchpadTemporaryDirectory("launchpad-location")
        #expect(VPhoneLaunchpadMachineLocations.problem(with: temp.canonicalPath) == nil)
        #expect(VPhoneLaunchpadMachineLocations.problem(with: temp.canonicalPath + "/new/VMs") == nil)
        #expect(VPhoneLaunchpadMachineLocations.availableBytes(temp.canonicalPath).map { $0 > 0 } == true)
    }

    @Test func aMachineFolderIsRefused() throws {
        let temp = try LaunchpadTemporaryDirectory("launchpad-location")
        try LaunchpadReports.writeBundle(named: "m", in: temp.url)
        let problem = try #require(VPhoneLaunchpadMachineLocations.problem(with: temp.canonicalPath + "/m"))
        #expect(problem.contains("is a machine"))
    }

    @Test func aReadOnlyFolderIsRefused() throws {
        let temp = try LaunchpadTemporaryDirectory("launchpad-location")
        let locked = temp.url.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let problem = try #require(VPhoneLaunchpadMachineLocations.problem(with: VPhoneLaunchpadMachineLocations.canonical(locked)))
        #expect(problem.contains("cannot write"))
    }
}

// MARK: - Smoke fixtures

/// Writes the checkpoints the B4 UI smoke check shows into bundles that
/// `vm new` made: `<root>/fail` (recovery_required, patch failed),
/// `<root>/jb` (completed_unverified) and `<root>/less` (prepare failed).
/// Enabled only by `VPHONE_LAUNCHPAD_CHECKPOINT_FIXTURES=<root>`, which must
/// lie in the temporary folder.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_LAUNCHPAD_CHECKPOINT_FIXTURES"] != nil))
struct SmokeCheckpointFixtures {
    @Test func writeSmokeCheckpoints() throws {
        let root = try #require(ProcessInfo.processInfo.environment["VPHONE_LAUNCHPAD_CHECKPOINT_FIXTURES"])
        let canonical = VPhoneLaunchpadMachineLocations.canonical(URL(fileURLWithPath: root))
        let temporary = VPhoneLaunchpadMachineLocations.canonical(FileManager.default.temporaryDirectory)
        try #require(canonical.hasPrefix(temporary + "/"), "fixtures go only below \(temporary)")
        let requirement = try CheckpointFixture.recovery(
            #"{"kind":"firmware_transaction","stage":"patch","detail":"a fw patch transaction is pending (fixture)","action":"vphone-cli fw patch --recover fail"}"#)
        let fixtures: [(String, VPhoneCreateCheckpoint)] = [
            ("fail", CheckpointFixture.make(variant: "regular") { checkpoint in
                CheckpointFixture.done(&checkpoint, .prepare)
                CheckpointFixture.began(&checkpoint, .patch, .failed, error: "stage patch failed: fixture")
                checkpoint.recoveryRequired = requirement
            }),
            ("jb", CheckpointFixture.make(variant: "jb") { checkpoint in
                CheckpointFixture.done(&checkpoint, .prepare, .patch, .restore, .cfw, .firstBoot)
                CheckpointFixture.done(&checkpoint, .jbFinalize, unverified: "no setup log evidence (fixture)")
                CheckpointFixture.done(&checkpoint, .verification)
            }),
            ("less", CheckpointFixture.make(variant: "less") { checkpoint in
                CheckpointFixture.began(&checkpoint, .prepare, .failed, error: "stage prepare failed: fixture")
            }),
        ]
        // Only bundles the smoke script made with `vm new` get a checkpoint.
        var written: [String] = []
        for (name, checkpoint) in fixtures {
            let bundle = URL(fileURLWithPath: canonical).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: bundle.appendingPathComponent("config.plist").path) else {
                continue
            }
            try CheckpointFixture.write(checkpoint, to: bundle)
            written.append(name)
        }
        try #require(!written.isEmpty)
        FileHandle.standardOutput.write(Data("[smoke-fixtures] \(canonical): \(written.joined(separator: ", "))\n".utf8))
    }
}
