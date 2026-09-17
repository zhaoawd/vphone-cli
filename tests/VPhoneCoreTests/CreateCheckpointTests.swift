import Darwin
import Foundation
import Testing
@testable import VPhoneCore

// D4: create checkpoints and resume, driven entirely by fake stages in temporary
// directories. No VM, firmware, sudo or network is involved.

// MARK: - Fake stages

private struct FakeFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Executor, verifier and prober in one. Each stage writes a small output
/// file; prepare builds a `Restore/` tree that patch modifies, and the disk
/// stages append to `Disk.img`.
private final class FakeStages: VPhoneCreateStageExecutor, VPhoneCreateStageVerifier, VPhoneCreateStateProber,
    @unchecked Sendable
{
    enum Fault { case beforeExecution, afterExecution, cancel, verifierRejects, leaveFirmwareTransaction }

    private let lock = NSLock()
    private var _faults: [VPhoneCreateStage: Fault] = [:]
    private var _executed: [VPhoneCreateStage] = []
    private var _verified: [VPhoneCreateStage] = []
    private var _probed: [VPhoneCreateStage] = []
    private var _removed: [String] = []
    var probeResults: [VPhoneCreateStage: VPhoneCreateProbeResult] = [:]
    var onExecute: ((VPhoneCreateStage) -> Void)?
    let version = "fake-verifier-1"

    static let diskStages: Set<VPhoneCreateStage> = [.restore, .cfw, .firstBoot, .verification]

    func setFault(_ stage: VPhoneCreateStage, _ fault: Fault?) { lock.withLock { _faults[stage] = fault } }
    var executed: [VPhoneCreateStage] { lock.withLock { _executed } }
    var verified: [VPhoneCreateStage] { lock.withLock { _verified } }
    var probed: [VPhoneCreateStage] { lock.withLock { _probed } }
    var removed: [String] { lock.withLock { _removed } }
    func resetCalls() { lock.withLock { _executed = []; _verified = []; _probed = [] } }

    /// One-shot: a fault fires once, so a resume after it succeeds.
    private func takeFault(_ stage: VPhoneCreateStage) -> Fault? {
        lock.withLock { _faults.removeValue(forKey: stage) }
    }
    private func peekFault(_ stage: VPhoneCreateStage) -> Fault? { lock.withLock { _faults[stage] } }

    func execute(_ stage: VPhoneCreateStage, context: VPhoneCreateStageContext) throws -> [String: String] {
        lock.withLock { _executed.append(stage) }
        onExecute?(stage)
        let fault = peekFault(stage)
        if fault == .beforeExecution { _ = takeFault(stage); throw FakeFailure(message: "fault before \(stage.rawValue)") }
        let dir = context.bundleURL
        let fm = FileManager.default
        switch stage {
        case .prepare:
            let restore = dir.appendingPathComponent("Restore")
            try? fm.removeItem(at: restore)
            try fm.createDirectory(at: restore, withIntermediateDirectories: false)
            try Data("base firmware".utf8).write(to: restore.appendingPathComponent("BuildManifest.plist"))
        case .patch:
            // Like the C4 transaction, a failing patch run leaves the tree unchanged.
            if fault == nil { try Data("patched".utf8).write(to: dir.appendingPathComponent("Restore/patched.bin")) }
        case .restore:
            try Data("restored".utf8).write(to: dir.appendingPathComponent("Disk.img"))
            try VPhoneVirtualMachineManifest(machineIdentifier: Data("machine-1".utf8), cpuCount: 2, memorySize: 1024, romImages: nil)
                .write(to: dir.appendingPathComponent("config.plist"))
        default:
            if Self.diskStages.contains(stage) {
                let handle = try FileHandle(forWritingTo: dir.appendingPathComponent("Disk.img"))
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(stage.rawValue.utf8))
                try handle.close()
            }
        }
        try Data("\(stage.rawValue) output".utf8).write(to: dir.appendingPathComponent("out-\(stage.rawValue).txt"))
        switch fault {
        case .afterExecution:
            _ = takeFault(stage)
            throw FakeFailure(message: "fault after \(stage.rawValue)")
        case .cancel:
            _ = takeFault(stage)
            throw CancellationError()
        case .leaveFirmwareTransaction:
            _ = takeFault(stage)
            let root = dir.appendingPathComponent(".firmware-transaction")
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
            try Data(#"{"phase":"publishing"}"#.utf8).write(to: root.appendingPathComponent("journal.json"))
            throw FakeFailure(message: "patch interrupted during publication")
        default:
            break
        }
        return ["ran": stage.rawValue]
    }

    func artifactsRewrittenOnRerun(_ stage: VPhoneCreateStage) -> Set<String> {
        Self.diskStages.contains(stage) ? ["disk"] : []
    }

    func removeArtifact(_ artifact: VPhoneCreateArtifactRecord, context: VPhoneCreateStageContext) -> Bool {
        lock.withLock { _removed.append(artifact.name) }
        return (try? FileManager.default.removeItem(at: context.bundleURL.appendingPathComponent(artifact.relativePath))) != nil
    }

    func verify(_ stage: VPhoneCreateStage, context: VPhoneCreateStageContext, evidence: [String: String]) -> VPhoneCreateVerification {
        lock.withLock { _verified.append(stage) }
        if peekFault(stage) == .verifierRejects {
            _ = takeFault(stage)
            return .rejected("fake verifier rejected \(stage.rawValue)")
        }
        guard evidence["ran"] == stage.rawValue else { return .rejected("no executor evidence") }
        let output = "out-\(stage.rawValue).txt"
        let restoreRemoved = context.checkpoint.artifact("restore_tree")?.availability == .removed
        if !restoreRemoved {
            guard FileManager.default.fileExists(atPath: context.bundleURL.appendingPathComponent(output).path) else {
                return .rejected("missing \(output)")
            }
        }
        var artifacts = [VPhoneCreateArtifactSpec(name: stage.rawValue, relativePath: output, kind: .sha256File)]
        if stage == .prepare || stage == .patch {
            artifacts.append(.init(
                name: "restore_tree", relativePath: "Restore", kind: .treeMetadata,
                retainUntil: [.patch, .restore, .cfw, .firstBoot, .verification]))
        }
        if Self.diskStages.contains(stage) {
            artifacts.append(.init(name: "disk", relativePath: "Disk.img", kind: .fileMetadata))
        }
        if stage == .jbFinalize {
            return .unverified(reason: "no guest evidence collector", artifacts: artifacts, evidence: [:])
        }
        return .verified(artifacts: artifacts, evidence: ["checked": output])
    }

    func probe(_ stage: VPhoneCreateStage, context: VPhoneCreateStageContext) -> VPhoneCreateProbeResult {
        lock.withLock { _probed.append(stage) }
        return probeResults[stage] ?? .idle(evidence: "fake: no live state for \(stage.rawValue)")
    }
}

private struct InjectedWriteFailure: Error {}

// MARK: - Fixture

private struct Fixture {
    let root: URL
    let bundle: URL
    let fake = FakeStages()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("d4-" + UUID().uuidString)
        bundle = root.appendingPathComponent("vm")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    static func options(_ variant: String = "jb", iphone: String? = "/ipsw/iPhone.ipsw") -> VPhoneCreateEffectiveOptions {
        .init(variant: variant, iphoneSource: iphone, cloudosSource: "/ipsw/cloudOS.ipsw", spoofBuild: nil,
              forceDscMaxSlide: false, enableFrida: false, cpuCount: 8, memoryMb: 8192, diskSizeGb: 64)
    }

    func runner(
        inject: @escaping (VPhoneCreateCheckpointStore.WriteStep, VPhoneCreateCheckpoint) throws -> Void = { _, _ in },
        tool: String? = "tool-a", keepArtifacts: Bool = false
    ) -> VPhoneCreateRunner {
        VPhoneCreateRunner(
            executor: fake, verifier: fake, prober: fake,
            storeHooks: .init(inject: inject, acquireBundleLock: {
                try VPhoneVMLock(directory: $0, operation: VPhoneVMOperation.createCheckpoint)
            }),
            toolFingerprint: { tool }, log: { _ in }, keepArtifacts: keepArtifacts)
    }

    @discardableResult
    func create(_ runner: VPhoneCreateRunner, variant: String = "jb", iphone: String? = "/ipsw/iPhone.ipsw") throws -> VPhoneCreateCheckpoint {
        try runner.create(bundleURL: bundle, options: Self.options(variant, iphone: iphone), iphoneSource: iphone, cloudosSource: "/ipsw/cloudOS.ipsw")
    }

    func load() throws -> VPhoneCreateCheckpoint { try VPhoneCreateCheckpointStore.load(bundleURL: bundle).checkpoint }
    var checkpointURL: URL { bundle.appendingPathComponent(".create-checkpoint/checkpoint.json") }
    func checkpointBytes() -> Data? { try? Data(contentsOf: checkpointURL) }
}

private func statuses(_ checkpoint: VPhoneCreateCheckpoint) -> [VPhoneCreateStage: VPhoneCreateStageStatus] {
    Dictionary(uniqueKeysWithValues: checkpoint.stages.map { ($0.stage, $0.status) })
}

private let allStages = VPhoneCreateStage.allCases

// MARK: - Tests

@Suite struct CreateCheckpointTests {
    // MARK: Fresh create

    @Test func freshCreateRecordsEveryStageAndOverallStatus() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let checkpoint = try f.create(f.runner(), variant: "regular")
        #expect(f.fake.executed == [.prepare, .patch, .restore, .cfw, .firstBoot, .verification])
        let s = statuses(checkpoint)
        #expect(s[.jbFinalize] == .notApplicable)
        #expect(allStages.filter { $0 != .jbFinalize }.allSatisfy { s[$0] == .succeeded })
        #expect(checkpoint.overallStatus == .succeeded)
        let disk = try f.load()
        #expect(disk == checkpoint || disk.overallStatus == .succeeded)
        #expect(disk.record(.restore).verifierVersion == "fake-verifier-1")
        #expect(disk.record(.restore).executorResult == "completed")
        #expect(disk.bundleIdentity.machineIdentifierSha256 != nil)
    }

    @Test func unverifiedStageNeverReportsOverallSuccess() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let checkpoint = try f.create(f.runner(), variant: "jb")
        #expect(checkpoint.record(.jbFinalize).status == .unverified)
        #expect(checkpoint.record(.jbFinalize).reason == "no guest evidence collector")
        #expect(checkpoint.overallStatus == .completedUnverified)
        // A resume of a finished create runs nothing and writes nothing.
        let before = f.checkpointBytes()
        f.fake.resetCalls()
        let again = try f.runner().resume(bundleURL: f.bundle)
        #expect(f.fake.executed.isEmpty)
        #expect(again.overallStatus == .completedUnverified)
        #expect(f.checkpointBytes() == before)
    }

    // MARK: Fault matrix

    enum MatrixFault: String, CaseIterable, Sendable {
        case beforeExecution, afterExecution, beforeCheckpointCommit, cancel, verifierRejects
    }

    @Test(arguments: VPhoneCreateStage.allCases, MatrixFault.allCases)
    func faultMatrixFirstRunAndResume(stage: VPhoneCreateStage, fault: MatrixFault) throws {
        let f = try Fixture(); defer { f.cleanup() }
        var inject: (VPhoneCreateCheckpointStore.WriteStep, VPhoneCreateCheckpoint) throws -> Void = { _, _ in }
        switch fault {
        case .beforeExecution: f.fake.setFault(stage, .beforeExecution)
        case .afterExecution: f.fake.setFault(stage, .afterExecution)
        case .cancel: f.fake.setFault(stage, .cancel)
        case .verifierRejects: f.fake.setFault(stage, .verifierRejects)
        case .beforeCheckpointCommit:
            // The process "dies" after the executor and verifier succeeded but
            // before the success record reaches disk.
            var fired = false
            inject = { step, checkpoint in
                if !fired, step == .rename, checkpoint.record(stage).status.isDone {
                    fired = true
                    throw InjectedWriteFailure()
                }
            }
        }

        // First run.
        let firstRunner = f.runner(inject: inject)
        #expect(throws: VPhoneCreateRunError.self) { try f.create(firstRunner) }
        let index = allStages.firstIndex(of: stage)!
        #expect(f.fake.executed == Array(allStages[...index]))
        let first = try f.load()
        let expected: VPhoneCreateStageStatus = switch fault {
        case .beforeExecution, .afterExecution, .verifierRejects: .failed
        case .cancel: .cancelled
        case .beforeCheckpointCommit: .running
        }
        #expect(first.record(stage).status == expected)
        #expect(allStages[..<index].allSatisfy { first.record($0).status.isDone })
        #expect(allStages[(index + 1)...].allSatisfy { first.record($0).status == .pending })
        #expect(first.overallStatus != .succeeded && first.overallStatus != .completedUnverified)
        let firstAttempt = first.attemptId

        // Resume.
        f.fake.resetCalls()
        if stage == .patch, fault == .beforeCheckpointCommit {
            // Patch published its output but the success record was lost: the
            // tree no longer matches prepare's record and patch must not run on
            // it again. The recovery path is an explicit restart from prepare.
            let before = f.checkpointBytes()
            #expect { try f.runner().resume(bundleURL: f.bundle) } throws: { error in
                guard case let VPhoneCreateRunError.artifactChanged(name, recordedBy, _) = error else { return false }
                return name == "restore_tree" && recordedBy == .prepare
            }
            #expect(f.fake.executed.isEmpty)
            #expect(f.checkpointBytes() == before)
            let restarted = try f.runner().resume(bundleURL: f.bundle, request: .init(restartFrom: .prepare))
            #expect(f.fake.executed == allStages)
            #expect(restarted.overallStatus == .completedUnverified)
            #expect(restarted.record(.patch).history.first?.status == .running)
            return
        }
        let resumed = try f.runner().resume(bundleURL: f.bundle)
        #expect(f.fake.executed == Array(allStages[index...]))
        #expect(f.fake.probed.first == stage)
        // Every skipped stage was re-verified before the rerun, then each run stage verified once.
        #expect(f.fake.verified == Array(allStages[..<index]) + Array(allStages[index...]))
        #expect(resumed.overallStatus == .completedUnverified)
        let history = resumed.record(stage).history
        #expect(history.count == 1)
        #expect(history.first?.status == expected)
        #expect(history.first?.attemptId == firstAttempt)
        #expect(resumed.resumedFrom?.attemptId == firstAttempt)
        #expect(resumed.attempts.map(\.kind) == ["create", "resume"])
        let archived = f.bundle.appendingPathComponent(".create-checkpoint").appendingPathComponent(resumed.resumedFrom!.archivedAs)
        let archivedCheckpoint = try VPhoneCreateJSON.decoder.decode(VPhoneCreateCheckpoint.self, from: Data(contentsOf: archived))
        #expect(archivedCheckpoint.record(stage).status == expected)
        #expect(try f.load() == resumed || f.load().overallStatus == .completedUnverified)
    }

    // MARK: Artifacts

    @Test func changedArtifactAfterSuccessRefusesResumeWithoutExecuting() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.fake.setFault(.restore, .beforeExecution)
        #expect(throws: VPhoneCreateRunError.self) { try f.create(f.runner()) }
        try Data("tampered".utf8).write(to: f.bundle.appendingPathComponent("Restore/BuildManifest.plist"))
        let before = f.checkpointBytes()
        f.fake.resetCalls()
        do {
            try f.runner().resume(bundleURL: f.bundle)
            Issue.record("resume accepted a changed artifact")
        } catch let VPhoneCreateRunError.artifactChanged(name, recordedBy, _) {
            #expect(name == "restore_tree")
            #expect(recordedBy == .patch)
        }
        #expect(f.fake.executed.isEmpty)
        #expect(f.checkpointBytes() == before)
    }

    @Test func movedArtifactRefusesResume() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.fake.setFault(.cfw, .afterExecution)
        #expect(throws: VPhoneCreateRunError.self) { try f.create(f.runner()) }
        try FileManager.default.moveItem(
            at: f.bundle.appendingPathComponent("out-patch.txt"), to: f.root.appendingPathComponent("elsewhere.txt"))
        f.fake.resetCalls()
        #expect(throws: VPhoneCreateRunError.self) { try f.runner().resume(bundleURL: f.bundle) }
        #expect(f.fake.executed.isEmpty)
    }

    @Test func rerunStageMayRewriteItsDeclaredArtifacts() throws {
        // cfw failed after appending to Disk.img; cfw declares "disk" rewritable.
        let f = try Fixture(); defer { f.cleanup() }
        f.fake.setFault(.cfw, .afterExecution)
        #expect(throws: VPhoneCreateRunError.self) { try f.create(f.runner()) }
        f.fake.resetCalls()
        try f.runner().resume(bundleURL: f.bundle)
        #expect(f.fake.executed.first == .cfw)
    }

    @Test func restartFromStageWhoseOutputWasModifiedLaterIsRefused() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.fake.setFault(.restore, .beforeExecution)
        #expect(throws: VPhoneCreateRunError.self) { try f.create(f.runner()) }
        f.fake.resetCalls()
        // Restore tree is already patched: re-patching from it must be refused.
        do {
            try f.runner().resume(bundleURL: f.bundle, request: .init(restartFrom: .patch))
            Issue.record("restart from patch accepted a patched tree")
        } catch let VPhoneCreateRunError.artifactChanged(name, _, detail) {
            #expect(name == "restore_tree")
            #expect(detail.contains("patch"))
        }
        #expect(f.fake.executed.isEmpty)
        // Restarting from prepare rebuilds it.
        try f.runner().resume(bundleURL: f.bundle, request: .init(restartFrom: .prepare))
        #expect(f.fake.executed == allStages)
        let checkpoint = try f.load()
        #expect(checkpoint.record(.prepare).history.first?.supersededBecause == "restart requested from prepare")
        #expect(checkpoint.record(.restore).history.first?.status == .failed)
    }

    @Test func restartAfterNextUnfinishedStageIsRejected() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.fake.setFault(.patch, .beforeExecution)
        #expect(throws: VPhoneCreateRunError.self) { try f.create(f.runner()) }
        #expect(throws: VPhoneCreateRunError.self) {
            try f.runner().resume(bundleURL: f.bundle, request: .init(restartFrom: .cfw))
        }
    }

    // MARK: Identity

    @Test func movedBundleIsRefused() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.fake.setFault(.restore, .beforeExecution)
        #expect(throws: VPhoneCreateRunError.self) { try f.create(f.runner()) }
        let moved = f.root.appendingPathComponent("vm-moved")
        try FileManager.default.moveItem(at: f.bundle, to: moved)
        f.fake.resetCalls()
        #expect { try f.runner().resume(bundleURL: moved) } throws: { error in
            if case VPhoneCreateRunError.identityMismatch = error { return true }
            return false
        }
        #expect(f.fake.executed.isEmpty)
    }

    @Test func clonedOrReplacedBundleIsRefused() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.fake.setFault(.cfw, .beforeExecution)
        #expect(throws: VPhoneCreateRunError.self) { try f.create(f.runner()) }
        // Replace the directory at the same path with a copy (new inode).
        let original = f.root.appendingPathComponent("vm-original")
        try FileManager.default.moveItem(at: f.bundle, to: original)
        try FileManager.default.copyItem(at: original, to: f.bundle)
        f.fake.resetCalls()
        #expect { try f.runner().resume(bundleURL: f.bundle) } throws: { error in
            if case let VPhoneCreateRunError.identityMismatch(detail) = error { return detail.contains("replaced") }
            return false
        }
        #expect(f.fake.executed.isEmpty)
    }

    @Test func changedMachineIdentifierIsRefused() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.fake.setFault(.cfw, .beforeExecution)
        #expect(throws: VPhoneCreateRunError.self) { try f.create(f.runner()) }
        try VPhoneVirtualMachineManifest(machineIdentifier: Data("machine-2".utf8), cpuCount: 2, memorySize: 1024, romImages: nil)
            .write(to: f.bundle.appendingPathComponent("config.plist"))
        #expect { try f.runner().resume(bundleURL: f.bundle) } throws: { error in
            if case let VPhoneCreateRunError.identityMismatch(detail) = error { return detail.contains("machineIdentifier") }
            return false
        }
    }

    // MARK: Corrupt checkpoints

    private func corrupt(_ mutate: (inout [String: Any]) -> Void) throws -> (Fixture, Data?) {
        let f = try Fixture()
        f.fake.setFault(.restore, .beforeExecution)
        #expect(throws: VPhoneCreateRunError.self) { try f.create(f.runner()) }
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: f.checkpointURL)) as! [String: Any]
        mutate(&object)
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: f.checkpointURL)
        f.fake.resetCalls()
        return (f, data)
    }

    private func expectRejectedBeforeExecution(_ f: Fixture, _ bytes: Data?) {
        #expect(throws: (any Error).self) { try f.runner().resume(bundleURL: f.bundle) }
        #expect(throws: (any Error).self) { try VPhoneCreateCheckpointStore.load(bundleURL: f.bundle) }
        #expect(f.fake.executed.isEmpty)
        #expect(f.fake.verified.isEmpty)
        #expect(f.fake.probed.isEmpty)
        #expect(f.checkpointBytes() == bytes)
    }

    @Test func truncatedCheckpointIsRejected() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.fake.setFault(.restore, .beforeExecution)
        #expect(throws: VPhoneCreateRunError.self) { try f.create(f.runner()) }
        let bytes = try Data(contentsOf: f.checkpointURL)
        let truncated = bytes.prefix(bytes.count / 2)
        try truncated.write(to: f.checkpointURL)
        f.fake.resetCalls()
        expectRejectedBeforeExecution(f, Data(truncated))
    }

    @Test func futureSchemaIsRejected() throws {
        let (f, bytes) = try corrupt { $0["schema_version"] = 2 }
        defer { f.cleanup() }
        #expect(throws: VPhoneCreateCheckpointError.unsupportedSchema(2)) { try VPhoneCreateCheckpointStore.load(bundleURL: f.bundle) }
        expectRejectedBeforeExecution(f, bytes)
    }

    @Test func duplicateStageIsRejected() throws {
        let (f, bytes) = try corrupt { object in
            var stages = object["stages"] as! [[String: Any]]
            stages[6] = stages[5]
            object["stages"] = stages
        }
        defer { f.cleanup() }
        expectRejectedBeforeExecution(f, bytes)
    }

    @Test func unknownStageIsRejected() throws {
        let (f, bytes) = try corrupt { object in
            var stages = object["stages"] as! [[String: Any]]
            stages[6]["stage"] = "deploy"
            object["stages"] = stages
        }
        defer { f.cleanup() }
        expectRejectedBeforeExecution(f, bytes)
    }

    @Test func succeededWithoutVerifierIsRejected() throws {
        let (f, bytes) = try corrupt { object in
            var stages = object["stages"] as! [[String: Any]]
            stages[0].removeValue(forKey: "verifier_version")
            object["stages"] = stages
        }
        defer { f.cleanup() }
        expectRejectedBeforeExecution(f, bytes)
    }

    @Test func notApplicableWithoutVariantRuleIsRejected() throws {
        let (f, bytes) = try corrupt { object in
            var stages = object["stages"] as! [[String: Any]]
            stages[3]["status"] = "not_applicable"  // cfw on jb
            object["stages"] = stages
        }
        defer { f.cleanup() }
        expectRejectedBeforeExecution(f, bytes)
    }

    @Test func artifactPathEscapingBundleIsRejected() throws {
        let (f, bytes) = try corrupt { object in
            var artifacts = object["artifacts"] as! [[String: Any]]
            artifacts[0]["relative_path"] = "../outside"
            object["artifacts"] = artifacts
        }
        defer { f.cleanup() }
        expectRejectedBeforeExecution(f, bytes)
    }

    @Test func symlinkedCheckpointIsRejected() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.fake.setFault(.restore, .beforeExecution)
        #expect(throws: VPhoneCreateRunError.self) { try f.create(f.runner()) }
        let real = f.root.appendingPathComponent("real.json")
        try FileManager.default.moveItem(at: f.checkpointURL, to: real)
        try FileManager.default.createSymbolicLink(at: f.checkpointURL, withDestinationURL: real)
        f.fake.resetCalls()
        #expect(throws: (any Error).self) { try f.runner().resume(bundleURL: f.bundle) }
        #expect(f.fake.executed.isEmpty)
    }

    // MARK: C4 transaction

    @Test(arguments: ["building", "publishing", "rollingBack"])
    func uncommittedFirmwareTransactionRequiresRecovery(phase: String) throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.fake.setFault(.patch, .beforeExecution)
        #expect(throws: VPhoneCreateRunError.self) { try f.create(f.runner()) }
        let root = f.bundle.appendingPathComponent(".firmware-transaction")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data(#"{"version":1,"phase":"\#(phase)"}"#.utf8).write(to: root.appendingPathComponent("journal.json"))
        let before = f.checkpointBytes()
        f.fake.resetCalls()
        #expect { try f.runner().resume(bundleURL: f.bundle) } throws: { error in
            guard case let VPhoneCreateRunError.recoveryRequired(requirement) = error else { return false }
            return requirement.kind == "firmware_transaction" && requirement.detail.contains(phase)
                && requirement.action.contains("--recover")
        }
        #expect(f.fake.executed.isEmpty)
        #expect(f.checkpointBytes() == before)
        #expect(try f.load().record(.patch).status == .failed)
    }

    @Test func patchFailureLeavingTransactionIsRecordedAsRecoveryRequired() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.fake.setFault(.patch, .leaveFirmwareTransaction)
        #expect(throws: VPhoneCreateRunError.self) { try f.create(f.runner()) }
        let checkpoint = try f.load()
        #expect(checkpoint.record(.patch).status == .failed)
        #expect(checkpoint.recoveryRequired?.kind == "firmware_transaction")
        #expect(checkpoint.overallStatus == .recoveryRequired)
        // Explicit recovery (simulated by removing the transaction) unblocks resume.
        try FileManager.default.removeItem(at: f.bundle.appendingPathComponent(".firmware-transaction"))
        f.fake.resetCalls()
        let resumed = try f.runner().resume(bundleURL: f.bundle)
        #expect(f.fake.executed.first == .patch)
        #expect(resumed.recoveryRequired == nil)
    }

    // MARK: Live state re-probe

    @Test func busyLiveStateStopsResumeUntilProbeIsIdle() throws {
        let f = try Fixture(); defer { f.cleanup() }
        var fired = false
        let crashDuringRestore: (VPhoneCreateCheckpointStore.WriteStep, VPhoneCreateCheckpoint) throws -> Void = { step, checkpoint in
            if !fired, step == .writeTemporary, checkpoint.record(.restore).status.isDone { fired = true; throw InjectedWriteFailure() }
        }
        #expect(throws: VPhoneCreateRunError.self) { try f.create(f.runner(inject: crashDuringRestore)) }
        #expect(try f.load().record(.restore).status == .running)
        f.fake.probeResults[.restore] = .busy(detail: "restore-update still running for ECID", action: "stop pid 1")
        let before = f.checkpointBytes()
        f.fake.resetCalls()
        #expect { try f.runner().resume(bundleURL: f.bundle) } throws: { error in
            guard case let VPhoneCreateRunError.recoveryRequired(requirement) = error else { return false }
            return requirement.kind == "live_state" && requirement.stage == .restore
        }
        #expect(f.fake.probed == [.restore])
        #expect(f.fake.executed.isEmpty)
        #expect(f.checkpointBytes() == before)

        f.fake.probeResults[.restore] = nil
        f.fake.resetCalls()
        let resumed = try f.runner().resume(bundleURL: f.bundle)
        #expect(f.fake.executed.first == .restore)
        #expect(resumed.record(.restore).history.first?.supersededBecause.contains("interrupted") == true)
        #expect(resumed.attempts.last?.checks["probe.restore"]?.contains("no live state") == true)
    }

    // MARK: Locks

    @Test func heldRunLockRefusesResumeWithoutWriting() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.fake.setFault(.restore, .beforeExecution)
        #expect(throws: VPhoneCreateRunError.self) { try f.create(f.runner()) }
        let before = f.checkpointBytes()
        let holder = try VPhoneCreateCheckpointStore.open(bundleURL: f.bundle)
        f.fake.resetCalls()
        #expect { try f.runner().resume(bundleURL: f.bundle) } throws: { error in
            if case VPhoneCreateRunError.runInProgress = error { return true }
            return false
        }
        #expect(VPhoneCreateCheckpointStore.isRunLockHeld(bundleURL: f.bundle))
        withExtendedLifetime(holder) {}
        #expect(f.fake.executed.isEmpty)
        #expect(f.checkpointBytes() == before)
    }

    @Test func runLockHeldByChildProcessRefusesUntilItExits() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.fake.setFault(.cfw, .beforeExecution)
        #expect(throws: VPhoneCreateRunError.self) { try f.create(f.runner()) }
        let before = f.checkpointBytes()
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        child.arguments = [
            "python3", "-c",
            "import os,fcntl,sys,time; f=os.open(sys.argv[1],os.O_RDONLY); fcntl.flock(f,fcntl.LOCK_EX); print('ready',flush=True); time.sleep(30)",
            f.bundle.appendingPathComponent(".create-checkpoint").path,
        ]
        let pipe = Pipe()
        child.standardOutput = pipe
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        #expect(!pipe.fileHandleForReading.availableData.isEmpty)
        f.fake.resetCalls()
        #expect { try f.runner().resume(bundleURL: f.bundle) } throws: { error in
            if case VPhoneCreateRunError.runInProgress = error { return true }
            return false
        }
        #expect(f.fake.executed.isEmpty)
        #expect(f.checkpointBytes() == before)
        child.terminate()
        child.waitUntilExit()
        try f.runner().resume(bundleURL: f.bundle)
        #expect(f.fake.executed.first == .cfw)
    }

    @Test func heldBundleLockRefusesResumeWithoutWriting() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.fake.setFault(.restore, .beforeExecution)
        #expect(throws: VPhoneCreateRunError.self) { try f.create(f.runner()) }
        let before = f.checkpointBytes()
        let vm = try VPhoneVMLock(directory: f.bundle, operation: VPhoneVMOperation.boot)
        f.fake.resetCalls()
        #expect { try f.runner().resume(bundleURL: f.bundle) } throws: { error in
            if case VPhoneCreateRunError.bundleBusy = error { return true }
            return false
        }
        withExtendedLifetime(vm) {}
        #expect(f.fake.executed.isEmpty)
        #expect(f.checkpointBytes() == before)
    }

    @Test func bundleLockTakenBetweenStagesFailsTheWriteAndStops() throws {
        let f = try Fixture(); defer { f.cleanup() }
        final class Holder: @unchecked Sendable { var lock: VPhoneVMLock? }
        let holder = Holder()
        f.fake.onExecute = { stage in
            if stage == .patch { holder.lock = try? VPhoneVMLock(directory: f.bundle, operation: VPhoneVMOperation.boot) }
        }
        #expect { try f.create(f.runner()) } throws: { error in
            if case VPhoneCreateRunError.checkpointWriteFailed = error { return true }
            return false
        }
        #expect(holder.lock != nil)
        #expect(f.fake.executed == [.prepare, .patch])
        holder.lock = nil
        #expect(try f.load().record(.patch).status == .running)
    }

    @Test func concurrentResumeAdmitsOneWriter() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.fake.setFault(.cfw, .beforeExecution)
        #expect(throws: VPhoneCreateRunError.self) { try f.create(f.runner()) }
        f.fake.resetCalls()

        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var blocked = false
        f.fake.onExecute = { _ in
            if !blocked { blocked = true; entered.signal(); release.wait() }
        }
        final class Box: @unchecked Sendable { var error: Error?; var result: VPhoneCreateCheckpoint? }
        let first = Box()
        let done = DispatchSemaphore(value: 0)
        let runner = f.runner()
        nonisolated(unsafe) let unsafeRunner = runner
        let bundle = f.bundle
        Thread.detachNewThread {
            do { first.result = try unsafeRunner.resume(bundleURL: bundle) } catch { first.error = error }
            done.signal()
        }
        entered.wait()
        let beforeSecond = f.checkpointBytes()
        #expect { try f.runner().resume(bundleURL: f.bundle) } throws: { error in
            if case VPhoneCreateRunError.runInProgress = error { return true }
            return false
        }
        #expect(f.checkpointBytes() == beforeSecond)
        release.signal()
        done.wait()
        #expect(first.error == nil)
        #expect(f.fake.executed == [.cfw, .firstBoot, .jbFinalize, .verification])
        #expect(first.result?.overallStatus == .completedUnverified)
    }

    // MARK: not_applicable

    @Test(arguments: [
        ("less", [VPhoneCreateStage.cfw, .jbFinalize]),
        ("regular", [.jbFinalize]),
        ("dev", [.jbFinalize]),
        ("jb", []),
        ("exp", []),
    ])
    func notApplicableFollowsVariantRules(variant: String, skipped: [VPhoneCreateStage]) throws {
        let f = try Fixture(); defer { f.cleanup() }
        let checkpoint = try f.create(f.runner(), variant: variant)
        #expect(checkpoint.stages.filter { $0.status == .notApplicable }.map(\.stage) == skipped)
        #expect(checkpoint.stages.filter { $0.status == .notApplicable }.allSatisfy { $0.reason != nil })
        #expect(f.fake.executed == allStages.filter { !skipped.contains($0) })
    }

    @Test func pendingStageIsNeverTreatedAsNotApplicable() throws {
        var checkpoint = VPhoneCreateCheckpoint(
            identity: .init(name: "vm", path: "/vm", directoryId: "1:2"), options: Fixture.options("regular"),
            tool: .init(executableSha256: nil, stageContractVersion: 1), now: Date())
        #expect(checkpoint.nextStage == .prepare)
        checkpoint.update(.jbFinalize) { $0.status = .pending; $0.reason = nil }
        #expect(throws: VPhoneCreateCheckpointError.self) { try checkpoint.validate() }
    }

    // MARK: Options and tool

    @Test func optionChangeAffectingCompletedStageIsRefused() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.fake.setFault(.restore, .beforeExecution)
        #expect(throws: VPhoneCreateRunError.self) { try f.create(f.runner()) }
        f.fake.resetCalls()
        #expect { try f.runner().resume(bundleURL: f.bundle, request: .init(overrides: .init(iphoneSource: "/ipsw/other.ipsw"))) } throws: { error in
            guard case let VPhoneCreateRunError.optionsChanged(lines) = error else { return false }
            return lines.contains { $0.contains("iphone_source") }
        }
        #expect { try f.runner().resume(bundleURL: f.bundle, request: .init(overrides: .init(variant: "regular"))) } throws: { error in
            guard case let VPhoneCreateRunError.optionsChanged(lines) = error else { return false }
            return lines.contains { $0.contains("variant") }
        }
        #expect(f.fake.executed.isEmpty)
        // spoof_build affects cfw, which has not run: accepted and recorded.
        let resumed = try f.runner().resume(bundleURL: f.bundle, request: .init(overrides: .init(spoofBuild: "23A1")))
        #expect(resumed.effectiveOptions.spoofBuild == "23A1")
        #expect(resumed.inputsDigest == resumed.effectiveOptions.digest)
    }

    @Test func variantChangeBeforePatchRecomputesApplicability() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.fake.setFault(.patch, .beforeExecution)
        #expect(throws: VPhoneCreateRunError.self) { try f.create(f.runner(), variant: "regular") }
        #expect(try f.load().record(.jbFinalize).status == .notApplicable)
        let resumed = try f.runner().resume(bundleURL: f.bundle, request: .init(overrides: .init(variant: "jb")))
        #expect(resumed.record(.jbFinalize).status == .unverified)
    }

    @Test func toolChangeRequiresExplicitAcceptance() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.fake.setFault(.restore, .beforeExecution)
        #expect(throws: VPhoneCreateRunError.self) { try f.create(f.runner(tool: "tool-a")) }
        f.fake.resetCalls()
        #expect { try f.runner(tool: "tool-b").resume(bundleURL: f.bundle) } throws: { error in
            if case VPhoneCreateRunError.toolChanged = error { return true }
            return false
        }
        #expect(f.fake.executed.isEmpty)
        let resumed = try f.runner(tool: "tool-b").resume(bundleURL: f.bundle, request: .init(acceptToolChange: true))
        #expect(resumed.attempts.last?.acceptedToolChange == true)
        #expect(resumed.tool.executableSha256 == "tool-b")
    }

    @Test func credentialsInSourcesAreNotStoredAndMustBeResupplied() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let secret = "https://user:hunter2@example.invalid/iPhone.ipsw?token=abc"
        f.fake.setFault(.prepare, .beforeExecution)
        #expect(throws: VPhoneCreateRunError.self) { try f.create(f.runner(), iphone: secret) }
        let text = String(decoding: f.checkpointBytes() ?? Data(), as: UTF8.self)
        #expect(!text.contains("hunter2"))
        #expect(!text.contains("token=abc"))
        #expect(throws: VPhoneCreateRunError.self) { try f.runner().resume(bundleURL: f.bundle) }
        let resumed = try f.runner().resume(bundleURL: f.bundle, request: .init(overrides: .init(iphoneSource: secret)))
        #expect(resumed.effectiveOptions.iphoneSource?.redacted == true)
    }

    // MARK: Retention

    @Test func recoveryInputsAreKeptUntilRetainingStagesFinish() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.fake.setFault(.firstBoot, .afterExecution)
        #expect(throws: VPhoneCreateRunError.self) { try f.create(f.runner()) }
        #expect(FileManager.default.fileExists(atPath: f.bundle.appendingPathComponent("Restore").path))
        #expect(f.fake.removed.isEmpty)
        #expect(try f.load().artifacts.filter { $0.name == "restore_tree" }.allSatisfy { $0.availability == .available })

        try f.runner().resume(bundleURL: f.bundle)
        #expect(f.fake.removed == ["restore_tree"])
        #expect(!FileManager.default.fileExists(atPath: f.bundle.appendingPathComponent("Restore").path))
        let records = try f.load().artifacts.filter { $0.name == "restore_tree" }
        #expect(records.allSatisfy { $0.availability == .removed && $0.rebuild?.contains("--restart-from prepare") == true })
    }

    @Test func keepArtifactsSkipsRemoval() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.create(f.runner(keepArtifacts: true), variant: "regular")
        #expect(f.fake.removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: f.bundle.appendingPathComponent("Restore").path))
    }

    @Test func removableArtifactsFollowSynthesizedStageStates() {
        var checkpoint = VPhoneCreateCheckpoint(
            identity: .init(name: "vm", path: "/vm", directoryId: "1:2"), options: Fixture.options("jb"),
            tool: .init(executableSha256: nil, stageContractVersion: 1), now: Date())
        checkpoint.artifacts = [.init(
            name: "restore_tree", relativePath: "Restore", kind: .treeMetadata, fingerprint: "x", sizeBytes: 1,
            availability: .available, recordedBy: .prepare, retainUntil: [.patch, .restore, .cfw, .firstBoot, .verification])]
        for stage in [VPhoneCreateStage.prepare, .patch, .restore, .cfw] { checkpoint.update(stage) { $0.status = .succeeded } }
        #expect(checkpoint.removableArtifacts.isEmpty)  // first_boot, verification pending
        checkpoint.update(.firstBoot) { $0.status = .unverified }
        #expect(checkpoint.removableArtifacts.isEmpty)  // verification pending
        checkpoint.update(.verification) { $0.status = .failed }
        #expect(checkpoint.removableArtifacts.isEmpty)
        checkpoint.update(.verification) { $0.status = .succeeded }
        // jb_finalize is not a retaining stage; its pending state does not keep the tree.
        #expect(checkpoint.removableArtifacts.map(\.name) == ["restore_tree"])
    }

    // MARK: Write failures

    @Test(arguments: [
        VPhoneCreateCheckpointStore.WriteStep.writeTemporary, .syncFile, .rename, .syncDirectory,
    ])
    func writeFailureBeforeStageStopsWithoutExecuting(step: VPhoneCreateCheckpointStore.WriteStep) throws {
        let f = try Fixture(); defer { f.cleanup() }
        let inject: (VPhoneCreateCheckpointStore.WriteStep, VPhoneCreateCheckpoint) throws -> Void = { current, checkpoint in
            if current == step, checkpoint.record(.prepare).status == .running { throw InjectedWriteFailure() }
        }
        #expect { try f.create(f.runner(inject: inject)) } throws: { error in
            if case VPhoneCreateRunError.checkpointWriteFailed = error { return true }
            return false
        }
        #expect(f.fake.executed.isEmpty)
        let checkpoint = try f.load()
        // syncDirectory fails after the rename, so the running record is on disk.
        #expect(checkpoint.record(.prepare).status == (step == .syncDirectory ? .running : .pending))
        #expect(checkpoint.overallStatus != .succeeded)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: f.bundle.appendingPathComponent(".create-checkpoint").path)
            .filter { $0.hasPrefix(".write-") }
        #expect(leftovers.isEmpty)
    }

    @Test func failureRecordWriteErrorKeepsOriginalError() throws {
        let f = try Fixture(); defer { f.cleanup() }
        f.fake.setFault(.restore, .afterExecution)
        let inject: (VPhoneCreateCheckpointStore.WriteStep, VPhoneCreateCheckpoint) throws -> Void = { step, checkpoint in
            if step == .rename, checkpoint.record(.restore).status == .failed { throw InjectedWriteFailure() }
        }
        #expect { try f.create(f.runner(inject: inject)) } throws: { error in
            guard case let VPhoneCreateRunError.checkpointWriteFailed(_, original) = error else { return false }
            return original?.contains("fault after restore") == true
        }
        // The durable record stays running: resume re-probes restore instead of trusting it.
        #expect(try f.load().record(.restore).status == .running)
        f.fake.resetCalls()
        try f.runner().resume(bundleURL: f.bundle)
        #expect(f.fake.probed.first == .restore)
        #expect(f.fake.executed.first == .restore)
    }

    /// The runtime record is diagnostic (see `VPhoneVMRuntimeState`): no lock
    /// holder deletes it on release, and readers check the kernel lock and pid
    /// liveness. Checkpoint writes follow the same rule; what must not remain is
    /// the lock itself, on the success path and on a failed write alike.
    @Test func checkpointWritesReleaseTheBundleLockAndLeaveOnlyADiagnosticRecord() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.create(f.runner(), variant: "regular")
        #expect(VPhoneVMRuntimeState.read(in: f.bundle)?.operation == VPhoneVMOperation.createCheckpoint)
        #expect(!VPhoneVMLockProbe.isLockHeld(directory: f.bundle))

        let g = try Fixture(); defer { g.cleanup() }
        g.fake.setFault(.restore, .afterExecution)
        let inject: (VPhoneCreateCheckpointStore.WriteStep, VPhoneCreateCheckpoint) throws -> Void = { step, checkpoint in
            if step == .rename, checkpoint.record(.restore).status == .failed { throw InjectedWriteFailure() }
        }
        #expect(throws: VPhoneCreateRunError.self) { try g.create(g.runner(inject: inject)) }
        #expect(VPhoneVMRuntimeState.read(in: g.bundle)?.operation == VPhoneVMOperation.createCheckpoint)
        #expect(!VPhoneVMLockProbe.isLockHeld(directory: g.bundle))

        // The leftover record does not block the next holder, which replaces it.
        let vm = try VPhoneVMLock(directory: g.bundle, operation: VPhoneVMOperation.boot)
        #expect(VPhoneVMRuntimeState.read(in: g.bundle)?.operation == VPhoneVMOperation.boot)
        withExtendedLifetime(vm) {}
    }

    @Test func missingCheckpointIsNotResumable() throws {
        let f = try Fixture(); defer { f.cleanup() }
        #expect(throws: VPhoneCreateCheckpointError.self) { try f.runner().resume(bundleURL: f.bundle) }
    }

    @Test func sourceRecordRedactsOnlyURLSecrets() {
        #expect(VPhoneCreateSourceRecord("/local/iPhone.ipsw").redacted == false)
        #expect(VPhoneCreateSourceRecord("https://updates.cdn-apple.com/a/iPhone.ipsw").redacted == false)
        let secret = VPhoneCreateSourceRecord("https://u:p@h/x.ipsw?t=1")
        #expect(secret.redacted)
        #expect(secret.display == "https://h/x.ipsw")
    }
}
