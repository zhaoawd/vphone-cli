import Darwin
import Foundation
import Testing
@testable import VPhoneCore

struct CreateResourceSnapshotTests {
    struct Fixture {
        let root: URL
        let source: VPhoneResources
        let cli: URL
        let machine: URL
        var storage: URL { root.appendingPathComponent("snapshots") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-tests-" + UUID().uuidString)
            source = VPhoneResources(base: root.appendingPathComponent("source"), environment: [:])
            cli = source.base.appendingPathComponent("bin/vphone-cli")
            machine = root.appendingPathComponent("machine")
            for path in ["bin/vphone-cli", "bin/vphone-vm", "scripts/fw_prepare.sh", "scripts/patchers/cfw.py",
                         "scripts/vphoned/signcert.p12", "requirements.txt", ".build/guest/vphoned"] {
                let file = source.base.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("original".utf8).write(to: file)
            }
            try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: true)
        }

        func capture(capacity: Int64 = Int64.max) throws -> VPhoneCreateResourceSnapshot {
            try .capture(resources: source, executable: cli, storage: storage, availableBytes: { _ in capacity })
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    final class Stages: VPhoneCreateStageExecutor, VPhoneCreateStageVerifier, VPhoneCreateStateProber {
        var fail: VPhoneCreateStage?
        var onExecute: (VPhoneCreateStage) throws -> Void = { _ in }
        let version = "snapshot-test-verifier"
        func execute(_ stage: VPhoneCreateStage, context: VPhoneCreateStageContext) throws -> [String: String] {
            try onExecute(stage)
            if stage == fail { throw VPhoneMachineBindingError("injected stage failure") }
            return ["executed": stage.rawValue]
        }
        func verify(_ stage: VPhoneCreateStage, context: VPhoneCreateStageContext, evidence: [String: String]) -> VPhoneCreateVerification {
            .verified(artifacts: [], evidence: [:])
        }
        func probe(_ stage: VPhoneCreateStage, context: VPhoneCreateStageContext) -> VPhoneCreateProbeResult { .idle(evidence: "test idle") }
        func artifactsRewrittenOnRerun(_ stage: VPhoneCreateStage) -> Set<String> { [] }
        func removeArtifact(_ artifact: VPhoneCreateArtifactRecord, context: VPhoneCreateStageContext) -> Bool { false }
    }

    func runner(_ snapshot: VPhoneCreateResourceSnapshot, _ stages: Stages) -> VPhoneCreateRunner {
        .init(executor: stages, verifier: stages, prober: stages, toolFingerprint: { try? snapshot.fingerprint() },
              resourceSnapshot: snapshot, bundleLockHeld: { _ in false }, log: { _ in })
    }
    var options: VPhoneCreateEffectiveOptions {
        .init(variant: "regular", iphoneSource: nil, cloudosSource: nil, spoofBuild: nil, forceDscMaxSlide: false,
              enableFrida: false, cpuCount: 2, memoryMb: 1024, diskSizeGb: 0)
    }

    @Test func capacityRefusalLeavesNoPartialSnapshotOrVMChanges() throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(throws: Error.self) { try f.capture(capacity: 0) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.storage.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.machine.path).isEmpty)
    }

    @Test func failedAttemptKeepsSnapshotAndAcceptedResumePreservesEarlierOrigins() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let first = try f.capture()
        let stages = Stages(); stages.fail = .cfw
        #expect(throws: VPhoneCreateRunError.self) {
            try runner(first, stages).create(bundleURL: f.machine, options: options, iphoneSource: nil, cloudosSource: nil)
        }
        let stored = try VPhoneCreateCheckpointStore.load(bundleURL: f.machine)
        #expect(stored.checkpoint.record(.prepare).evidence["resource_snapshot_sha256"] == first.manifest.sha256)
        let oldManifest = f.machine.appendingPathComponent(".create-checkpoint/attempts/\(stored.checkpoint.attemptId)-toolchain.json")
        let decoded = try VPhoneCreateJSON.decoder.decode(VPhoneCreateResourceSnapshot.Manifest.self, from: Data(contentsOf: oldManifest))
        #expect(decoded.sha256 == first.manifest.sha256 && !decoded.closureLimits.isEmpty)
        try Data("replacement".utf8).write(to: f.source.fwPrepareScript)
        let second = try f.capture()
        stages.fail = nil
        #expect(throws: VPhoneCreateRunError.self) { try runner(second, stages).resume(bundleURL: f.machine) }
        #expect(try VPhoneCreateCheckpointStore.load(bundleURL: f.machine).data == stored.data)
        let resumed = try runner(second, stages).resume(bundleURL: f.machine, request: .init(acceptToolChange: true))
        #expect(resumed.attempts.last?.acceptedToolChange == true)
        #expect(resumed.record(.prepare).evidence["resource_snapshot_sha256"] == first.manifest.sha256)
        #expect(resumed.record(.cfw).evidence["resource_snapshot_sha256"] == second.manifest.sha256)
        #expect(FileManager.default.fileExists(atPath: first.directory.path))
        #expect(!FileManager.default.fileExists(atPath: second.directory.path))
        #expect(try String(contentsOf: first.resources.fwPrepareScript, encoding: .utf8) == "original")
    }

    @Test func developmentDebListIsCopiedAndResumeRequiresAcceptanceAfterChanges() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let list = f.source.base.appendingPathComponent("debs.list")
        try Data("openssh-client\n".utf8).write(to: list)
        let first = try f.capture()
        #expect(FileManager.default.fileExists(atPath: first.resources.base.appendingPathComponent("debs.list").path))
        if FileManager.default.fileExists(atPath: first.resources.base.appendingPathComponent("debs.list").path) {
            #expect(try String(contentsOf: first.resources.base.appendingPathComponent("debs.list"), encoding: .utf8) == "openssh-client\n")
        }
        let stages = Stages(); stages.fail = .cfw
        #expect(throws: VPhoneCreateRunError.self) {
            try runner(first, stages).create(bundleURL: f.machine, options: options, iphoneSource: nil, cloudosSource: nil)
        }
        let stored = try VPhoneCreateCheckpointStore.load(bundleURL: f.machine)
        try Data("openssh-server\n".utf8).write(to: list)
        let second = try f.capture()
        #expect(first.manifest.sha256 != second.manifest.sha256)
        stages.fail = nil
        #expect(throws: VPhoneCreateRunError.self) { try runner(second, stages).resume(bundleURL: f.machine) }
        #expect(try VPhoneCreateCheckpointStore.load(bundleURL: f.machine).data == stored.data)
    }

    @Test func snapshotMutationDuringFinalStageCannotBeAccepted() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let snapshot = try f.capture()
        let stages = Stages()
        stages.onExecute = { stage in
            if stage == .verification { try Data("changed during final stage".utf8).write(to: snapshot.resources.fwPrepareScript) }
        }
        #expect(throws: VPhoneCreateRunError.self) {
            try runner(snapshot, stages).create(bundleURL: f.machine, options: options, iphoneSource: nil, cloudosSource: nil)
        }
        let checkpoint = try VPhoneCreateCheckpointStore.load(bundleURL: f.machine).checkpoint
        #expect(checkpoint.record(.verification).status == .failed)
        #expect(FileManager.default.fileExists(atPath: snapshot.directory.path))
    }

    // FirmwareTransaction and the less filesystem patcher call resolve internally.
    @Test func nestedResourceResolutionUsesAttemptScopeAndRestoresCaller() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let snapshot = try f.capture()
        let before = VPhoneResources.resolve().base
        try VPhoneResources.withCreateResources(snapshot.resources) {
            #expect(VPhoneResources.resolve().base == snapshot.resources.base)
            let content = try String(contentsOf: VPhoneResources.resolve().fwPrepareScript, encoding: .utf8)
            #expect(content == "original")
            #expect(VPhoneResources.resolve(executablePath: "/Applications/Other.app/Contents/MacOS/vphone-cli").base.path == "/Applications/Other.app/Contents/Resources")
        }
        #expect(VPhoneResources.resolve().base == before)
    }

    @Test func snapshotQuotaRefusesAdditionalCopiesWithoutDeletingEvidence() throws {
        let f = try Fixture(); defer { f.cleanup() }
        var copies: [VPhoneCreateResourceSnapshot] = []
        for _ in 0..<8 { copies.append(try f.capture()) }
        #expect(throws: Error.self) { try f.capture() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.storage.path).count == 8)
        #expect(copies.allSatisfy { FileManager.default.fileExists(atPath: $0.directory.appendingPathComponent("manifest.json").path) })
    }

    @Test func unusedSnapshotWithReadOnlySourceDirectoriesIsReleased() throws {
        let f = try Fixture(); defer { f.cleanup() }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.source.scriptsDir.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.source.scriptsDir.path)
        var snapshot: VPhoneCreateResourceSnapshot? = try f.capture()
        let directory = try #require(snapshot?.directory)
        snapshot = nil
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VPHONE_CREATE_SNAPSHOT_SMOKE_SOURCE"] != nil))
    func actualBuildResourceCopyRunsReadOnlyProbes() throws {
        let environment = ProcessInfo.processInfo.environment
        let cli = URL(fileURLWithPath: try #require(environment["VPHONE_CREATE_SNAPSHOT_SMOKE_SOURCE"]))
        let source = VPhoneResources.resolve(executablePath: cli.path)
        let snapshot = try VPhoneCreateResourceSnapshot.capture(resources: source, executable: cli)
        let command = try VPhoneProcessRunner.runCapturing(snapshot.executable, ["resources", "--json"], timeout: 20)
        let originalRuntime = try VPhoneProcessRunner.runCapturing(VPhoneResources.vmExecutable(executable: cli), ["--help"], timeout: 20)
        let runtime = try VPhoneProcessRunner.runCapturing(VPhoneResources.vmExecutable(executable: snapshot.executable), ["--help"], timeout: 20)
        #expect(command.succeeded)
        // A source build can already be rejected by the host. Copying must
        // preserve its observed result; the report retains both outcomes.
        #expect(runtime.exitCode == originalRuntime.exitCode && runtime.timedOut == originalRuntime.timedOut)
        let paths = try #require(try JSONSerialization.jsonObject(with: Data(command.stdout.utf8)) as? [String: String])
        #expect(URL(fileURLWithPath: try #require(paths["base"])).resolvingSymlinksInPath() == snapshot.resources.base.resolvingSymlinksInPath())
        #expect(try snapshot.fingerprint() == snapshot.manifest.sha256)
        let sourceContents = cli.resolvingSymlinksInPath().deletingLastPathComponent().deletingLastPathComponent()
        var signatureExit: Int32?
        if FileManager.default.fileExists(atPath: sourceContents.appendingPathComponent("_CodeSignature/CodeResources").path) {
            let signature = try VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: "/usr/bin/codesign"),
                ["--verify", "--strict", snapshot.directory.appendingPathComponent("VPhone.bundle").path], timeout: 20)
            signatureExit = signature.exitCode
            #expect(signature.succeeded, "\(signature.stderr)")
        }
        let pythonProbe = snapshot.resources.pythonCandidates.contains { snapshot.resources.pythonIsUsable($0.url) }
        if let report = environment["VPHONE_CREATE_SNAPSHOT_SMOKE_REPORT"] {
            var object = try #require(try JSONSerialization.jsonObject(with: VPhoneCreateJSON.encoder.encode(snapshot.manifest)) as? [String: Any])
            object["cli_resources_exit"] = command.exitCode
            object["vm_help_exit"] = runtime.exitCode
            object["source_vm_help_exit"] = originalRuntime.exitCode
            object["vm_help_succeeded"] = runtime.succeeded
            if let signatureExit { object["signature_verify_exit"] = signatureExit }
            object["resolved_resource_paths"] = paths
            object["external_python_locked_probe"] = pythonProbe
            object["vm_started"] = false
            try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: report))
        }
    }


    @Test func aVMImageCannotEnterTheResourceCopy() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try Data("VM disk fixture".utf8).write(to: f.source.scriptsDir.appendingPathComponent("Disk.img"))
        #expect(throws: Error.self) { try f.capture() }
    }

    @Test(arguments: [1, 2, 3])
    func aVMImageAliasCannotEnterTheResourceCopy(linkCount: Int) throws {
        let f = try Fixture(); defer { f.cleanup() }
        let disk = f.machine.appendingPathComponent("Disk.img")
        try Data("VM disk fixture".utf8).write(to: disk)
        var target = disk
        for index in 0..<linkCount {
            let parent = index == linkCount - 1 ? f.source.scriptsDir : f.machine
            let alias = parent.appendingPathComponent("disk-alias-\(index)")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
            target = alias
        }
        #expect(throws: Error.self) { try f.capture() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.storage.path).isEmpty)
        #expect(try String(contentsOf: disk, encoding: .utf8) == "VM disk fixture")
    }

    @Test(arguments: [0, (1 << 20) + 7])
    func sourceGrowthIsRefusedBeforeWritingBeyondPreflightSize(initialBytes: Int) throws {
        let f = try Fixture(); defer { f.cleanup() }
        let growing = f.source.scriptsDir.appendingPathComponent("growing-input")
        try Data(repeating: 0x41, count: initialBytes).write(to: growing)
        var observedTarget: FileHandle?
        defer { try? observedTarget?.close() }
        #expect(throws: Error.self) {
            try VPhoneCreateResourceSnapshot.capture(resources: f.source, executable: f.cli, storage: f.storage,
                availableBytes: { _ in Int64.max }, beforeCopy: { source, target in
                    guard source.path == growing.path else { return }
                    // Retain the actual output inode after failed-capture cleanup.
                    observedTarget = try FileHandle(forReadingFrom: target)
                    let writer = try FileHandle(forWritingTo: growing)
                    defer { try? writer.close() }
                    try writer.seekToEnd()
                    try writer.write(contentsOf: Data(repeating: 0x42, count: 64 << 10))
                })
        }
        let target = try #require(observedTarget)
        #expect(try target.seekToEnd() <= UInt64(initialBytes))
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.storage.path).isEmpty)
    }

}
