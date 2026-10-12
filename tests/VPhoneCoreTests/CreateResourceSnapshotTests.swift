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
        var rom: URL { root.appendingPathComponent("framework/boot-rom") }
        var seprom: URL { root.appendingPathComponent("framework/sep-rom") }
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
            try FileManager.default.createDirectory(at: rom.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("rom-A".utf8).write(to: rom)
            try Data("sep-A".utf8).write(to: seprom)
            try FileManager.default.createDirectory(at: machine, withIntermediateDirectories: true)
        }

        func capture(capacity: Int64 = Int64.max) throws -> VPhoneCreateResourceSnapshot {
            try .capture(resources: source, executable: cli, storage: storage, romSource: rom, sepromSource: seprom, availableBytes: { _ in capacity })
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

    @Test(arguments: [false, true])
    func v2InputsAreFrozenIncludingEnvironmentOverrides(external: Bool) throws {
        let f = try Fixture(); defer { f.cleanup() }
        let components = external ? f.root.appendingPathComponent("external-components") : f.source.guestComponentsStage
        let daemon = external ? f.root.appendingPathComponent("external-api") : f.source.daemonAPICandidate
        for directory in [components, daemon] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("candidate-A".utf8).write(to: directory.appendingPathComponent("manifest.json"))
        }
        let source = external ? VPhoneResources(base: f.source.base, environment: [
            "VPHONE_GUEST_COMPONENTS": components.path, "VPHONE_API_DAEMON": daemon.path]) : f.source
        let snapshot = try VPhoneCreateResourceSnapshot.capture(resources: source, executable: f.cli,
            storage: f.storage, romSource: f.rom, sepromSource: f.seprom, availableBytes: { _ in Int64.max })
        let fingerprint = try snapshot.fingerprint()
        for (original, frozen) in [(components, snapshot.resources.guestComponentsStage),
                                   (daemon, snapshot.resources.daemonAPICandidate)] {
            #expect(frozen.path.hasPrefix(snapshot.directory.path + "/"))
            #expect(try String(contentsOf: frozen.appendingPathComponent("manifest.json"), encoding: .utf8) == "candidate-A")
            try Data("candidate-B".utf8).write(to: original.appendingPathComponent("manifest.json"))
            #expect(try String(contentsOf: frozen.appendingPathComponent("manifest.json"), encoding: .utf8) == "candidate-A")
        }
        #expect(try snapshot.fingerprint() == fingerprint)
        let next = try VPhoneCreateResourceSnapshot.capture(resources: source, executable: f.cli,
            storage: f.storage, romSource: f.rom, sepromSource: f.seprom, availableBytes: { _ in Int64.max })
        #expect(next.manifest.sha256 != fingerprint)
    }

    // Catch omitting either live framework ROM from the captured bytes and identity.
    @Test func romCopiesAreManifestedAndIsolatedFromLiveReplacement() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let snapshot = try f.capture()
        try Data("rom-B".utf8).write(to: f.rom)
        try Data("sep-B".utf8).write(to: f.seprom)
        #expect(try String(contentsOf: snapshot.romSource, encoding: .utf8) == "rom-A")
        #expect(try String(contentsOf: snapshot.sepromSource, encoding: .utf8) == "sep-A")
        #expect(snapshot.manifest.entries.contains { $0.path == "ROMs/AVPBooter.vresearch1.bin" && $0.bytes == 5 && $0.sha256 != nil })
        #expect(snapshot.manifest.entries.contains { $0.path == "ROMs/AVPSEPBooter.vresearch1.bin" && $0.bytes == 5 && $0.sha256 != nil })
    }

    @Test(arguments: [false, true])
    func missingROMRefusesBeforeAnyMachineChanges(sep: Bool) throws {
        let f = try Fixture(); defer { f.cleanup() }
        try FileManager.default.removeItem(at: sep ? f.seprom : f.rom)
        #expect(throws: Error.self) { try f.capture() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.machine.path).isEmpty)
        if FileManager.default.fileExists(atPath: f.storage.path) {
            #expect(try FileManager.default.contentsOfDirectory(atPath: f.storage.path).isEmpty)
        }
    }

    @Test(arguments: [false, true])
    func romChangesRequireExplicitResumeAcceptanceAndRetainEarlierOrigins(sep: Bool) throws {
        let f = try Fixture(); defer { f.cleanup() }
        let first = try f.capture()
        let stages = Stages(); stages.fail = .cfw
        #expect(throws: VPhoneCreateRunError.self) {
            try runner(first, stages).create(bundleURL: f.machine, options: options, iphoneSource: nil, cloudosSource: nil)
        }
        let stored = try VPhoneCreateCheckpointStore.load(bundleURL: f.machine)
        try Data("rom-B".utf8).write(to: sep ? f.seprom : f.rom)
        let second = try f.capture()
        #expect(second.manifest.sha256 != first.manifest.sha256)
        stages.fail = nil
        #expect(throws: VPhoneCreateRunError.self) { try runner(second, stages).resume(bundleURL: f.machine) }
        #expect(try VPhoneCreateCheckpointStore.load(bundleURL: f.machine).data == stored.data)
        let resumed = try runner(second, stages).resume(bundleURL: f.machine, request: .init(acceptToolChange: true))
        #expect(resumed.attempts.last?.acceptedToolChange == true)
        #expect(resumed.record(.prepare).evidence["resource_snapshot_sha256"] == first.manifest.sha256)
        #expect(resumed.record(.cfw).evidence["resource_snapshot_sha256"] == second.manifest.sha256)
    }

    @Test func romSymlinkIsMaterializedAndLaterTargetChangesAreIsolated() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let original = f.root.appendingPathComponent("linked-rom-input")
        try Data("rom-A".utf8).write(to: original)
        try FileManager.default.removeItem(at: f.rom)
        try FileManager.default.createSymbolicLink(at: f.rom, withDestinationURL: original)
        let snapshot = try f.capture()
        try Data("rom-B".utf8).write(to: original)
        var info = stat()
        #expect(lstat(snapshot.romSource.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG)
        #expect(try String(contentsOf: snapshot.romSource, encoding: .utf8) == "rom-A")
    }

    @Test func redirectedROMAfterInventoryIsRefused() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let original = f.root.appendingPathComponent("rom-original")
        let replacement = f.root.appendingPathComponent("rom-replacement")
        try Data("rom-A".utf8).write(to: original)
        try Data("rom-B".utf8).write(to: replacement)
        try FileManager.default.removeItem(at: f.rom)
        try FileManager.default.createSymbolicLink(at: f.rom, withDestinationURL: original)
        #expect(throws: Error.self) {
            try VPhoneCreateResourceSnapshot.capture(resources: f.source, executable: f.cli, storage: f.storage,
                romSource: f.rom, sepromSource: f.seprom, availableBytes: { _ in
                    try FileManager.default.removeItem(at: f.rom)
                    try FileManager.default.createSymbolicLink(at: f.rom, withDestinationURL: replacement)
                    return Int64.max
                })
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.storage.path).isEmpty)
    }

    @Test func romGrowthCannotWritePastItsAdmittedSize() throws {
        let f = try Fixture(); defer { f.cleanup() }
        var observedTarget: FileHandle?
        defer { try? observedTarget?.close() }
        #expect(throws: Error.self) {
            try VPhoneCreateResourceSnapshot.capture(resources: f.source, executable: f.cli, storage: f.storage,
                romSource: f.rom, sepromSource: f.seprom, availableBytes: { _ in Int64.max }, beforeCopy: { source, target in
                    guard source.path == f.rom.path else { return }
                    observedTarget = try FileHandle(forReadingFrom: target)
                    let writer = try FileHandle(forWritingTo: source)
                    defer { try? writer.close() }
                    try writer.seekToEnd()
                    try writer.write(contentsOf: Data(repeating: 0x42, count: 64 << 10))
                })
        }
        let target = try #require(observedTarget)
        #expect(try target.seekToEnd() <= 5)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.storage.path).isEmpty)
    }

    @Test func romsCountAgainstCapacityAdmission() throws {
        let f = try Fixture(); defer { f.cleanup() }
        // Seven existing fixture inputs contain eight bytes each; the two ROMs add ten bytes.
        #expect(throws: Error.self) { try f.capture(capacity: 56 + (64 << 20)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.storage.path).isEmpty)
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

    @Test(arguments: ["script", "rom", "seprom"])
    func snapshotMutationDuringFinalStageCannotBeAccepted(input: String) throws {
        let f = try Fixture(); defer { f.cleanup() }
        let snapshot = try f.capture()
        let stages = Stages()
        stages.onExecute = { stage in
            if stage == .verification {
                let file = input == "rom" ? snapshot.romSource : input == "seprom" ? snapshot.sepromSource : snapshot.resources.fwPrepareScript
                try Data("changed during final stage".utf8).write(to: file)
            }
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
            try VPhoneCreateResourceSnapshot.capture(resources: f.source, executable: f.cli, storage: f.storage, romSource: f.rom, sepromSource: f.seprom,
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

    @Test(arguments: ["afterInventory", "beforeCopy"])
    func metadataOnlyXattrChangePreservesTheFrozenContentContract(timing: String) throws {
        let f = try Fixture(); defer { f.cleanup() }
        let baseline = try f.capture()
        var changedMetadata = false
        func changeMetadata() throws {
            let source = f.source.fwPrepareScript
            var before = stat(); var after = stat()
            #expect(lstat(source.path, &before) == 0)
            let value = Data("snapshot-test-metadata".utf8)
            let status = value.withUnsafeBytes { bytes in
                setxattr(source.path, "com.vphone.snapshot-test", bytes.baseAddress, bytes.count, 0, 0)
            }
            try #require(status == 0, "setxattr failed: \(String(cString: strerror(errno)))")
            #expect(lstat(source.path, &after) == 0)
            #expect(before.st_dev == after.st_dev && before.st_ino == after.st_ino)
            #expect(before.st_mode == after.st_mode && before.st_size == after.st_size)
            #expect(before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
                && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
            changedMetadata = before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec
                || before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec
            #expect(changedMetadata)
        }
        let snapshot = try VPhoneCreateResourceSnapshot.capture(resources: f.source, executable: f.cli, storage: f.storage, romSource: f.rom, sepromSource: f.seprom,
            availableBytes: { _ in
                if timing == "afterInventory" { try changeMetadata() }
                return Int64.max
            }, beforeCopy: { source, _ in
                if timing == "beforeCopy", source.path == f.source.fwPrepareScript.path { try changeMetadata() }
            })
        #expect(changedMetadata)
        #expect(snapshot.manifest.sha256 == baseline.manifest.sha256)
        #expect(try String(contentsOf: snapshot.resources.fwPrepareScript, encoding: .utf8) == "original")
    }

    @Test func sameLengthContentRewriteWithRestoredMtimeIsRefused() throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(throws: Error.self) {
            try VPhoneCreateResourceSnapshot.capture(resources: f.source, executable: f.cli, storage: f.storage, romSource: f.rom, sepromSource: f.seprom,
                availableBytes: { _ in Int64.max }, beforeCopy: { source, _ in
                    guard source.path == f.source.fwPrepareScript.path else { return }
                    let writer = try FileHandle(forWritingTo: source)
                    defer { try? writer.close() }
                    var before = stat(); var after = stat()
                    #expect(fstat(writer.fileDescriptor, &before) == 0)
                    try writer.write(contentsOf: Data("modified".utf8))
                    let times = [before.st_atimespec, before.st_mtimespec]
                    let status = times.withUnsafeBufferPointer { futimens(writer.fileDescriptor, $0.baseAddress) }
                    try #require(status == 0, "futimens failed: \(String(cString: strerror(errno)))")
                    #expect(fstat(writer.fileDescriptor, &after) == 0)
                    #expect(before.st_dev == after.st_dev && before.st_ino == after.st_ino)
                    #expect(before.st_mode == after.st_mode && before.st_size == after.st_size)
                    #expect(before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
                        && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
                })
        }
        #expect(try String(contentsOf: f.source.fwPrepareScript, encoding: .utf8) == "modified")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.storage.path).isEmpty)
    }

    @Test func linkRedirectedAfterInventoryToDifferentContentIsRefused() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let original = f.root.appendingPathComponent("original-resource")
        let replacement = f.root.appendingPathComponent("replacement-resource")
        try Data("original".utf8).write(to: original)
        try Data("replaced".utf8).write(to: replacement)
        let link = f.source.scriptsDir.appendingPathComponent("linked-resource")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        #expect(throws: Error.self) {
            try VPhoneCreateResourceSnapshot.capture(resources: f.source, executable: f.cli, storage: f.storage, romSource: f.rom, sepromSource: f.seprom,
                availableBytes: { _ in
                    try FileManager.default.removeItem(at: link)
                    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: replacement)
                    return Int64.max
                })
        }
        #expect(try String(contentsOf: original, encoding: .utf8) == "original")
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.storage.path).isEmpty)
    }

}
