import Darwin
import Foundation

// MARK: - Stage seams

/// What an executor, verifier or prober may read about the run.
public struct VPhoneCreateStageContext: Sendable {
    public let bundleURL: URL
    public let bundleName: String
    public let options: VPhoneCreateEffectiveOptions
    /// Clear-text firmware sources for this attempt (nil when not supplied and
    /// not recoverable from the checkpoint).
    public let iphoneSource: String?
    public let cloudosSource: String?
    public let checkpoint: VPhoneCreateCheckpoint

    public init(
        bundleURL: URL, bundleName: String, options: VPhoneCreateEffectiveOptions,
        iphoneSource: String?, cloudosSource: String?, checkpoint: VPhoneCreateCheckpoint
    ) {
        self.bundleURL = bundleURL
        self.bundleName = bundleName
        self.options = options
        self.iphoneSource = iphoneSource
        self.cloudosSource = cloudosSource
        self.checkpoint = checkpoint
    }
}

/// Performs stages. The live implementation drives fw prepare, the firmware
/// pipeline, DFU restore, CFW install and boots; tests substitute a fake.
public protocol VPhoneCreateStageExecutor {
    /// Runs one stage and returns evidence observed while running. Throw
    /// `CancellationError` to record `cancelled`, anything else for `failed`.
    func execute(_ stage: VPhoneCreateStage, context: VPhoneCreateStageContext) throws -> [String: String]
    /// Artifact names a rerun of `stage` rewrites even after a partial run, so a
    /// changed fingerprint is not a reason to refuse that rerun.
    func artifactsRewrittenOnRerun(_ stage: VPhoneCreateStage) -> Set<String>
    /// Removes an artifact no remaining stage needs. Returns false when skipped.
    func removeArtifact(_ artifact: VPhoneCreateArtifactRecord, context: VPhoneCreateStageContext) -> Bool
}

public enum VPhoneCreateVerification: Equatable, Sendable {
    case verified(artifacts: [VPhoneCreateArtifactSpec], evidence: [String: String])
    /// The executor completed but no evidence can confirm the result.
    case unverified(reason: String, artifacts: [VPhoneCreateArtifactSpec], evidence: [String: String])
    case rejected(String)
}

/// Read-only checks that decide whether a stage's result is accepted. Called
/// after the executor and again for every skipped stage on resume.
public protocol VPhoneCreateStageVerifier {
    var version: String { get }
    func verify(
        _ stage: VPhoneCreateStage, context: VPhoneCreateStageContext, evidence: [String: String]
    ) -> VPhoneCreateVerification
}

public enum VPhoneCreateProbeResult: Equatable, Sendable {
    case idle(evidence: String)
    case busy(detail: String, action: String)
}

/// Read-only probe of live state an earlier run of a stage may have left
/// (a DFU child, a restore process, an attached disk image). A checkpoint
/// entry alone never decides that a stage can be rerun.
public protocol VPhoneCreateStateProber {
    func probe(_ stage: VPhoneCreateStage, context: VPhoneCreateStageContext) -> VPhoneCreateProbeResult
}

// MARK: - Errors

public enum VPhoneCreateRunError: Error, CustomStringConvertible, LocalizedError {
    case io(String, Int32)
    case runInProgress(String)
    case bundleBusy(String)
    case identityMismatch(String)
    case artifactMissing(String)
    case artifactChanged(name: String, recordedBy: VPhoneCreateStage, detail: String)
    case artifactUnavailable(name: String, neededBy: VPhoneCreateStage, rebuild: String?)
    case verificationFailed(stage: VPhoneCreateStage, detail: String)
    case recoveryRequired(VPhoneCreateRecoveryRequirement)
    case optionsChanged([String])
    case toolChanged(recorded: String?, current: String?)
    case contractChanged(recorded: Int, current: Int)
    case invalidRestart(String)
    case sourceRequired(String)
    case stageFailed(stage: VPhoneCreateStage, detail: String)
    case stageCancelled(stage: VPhoneCreateStage, detail: String)
    case checkpointWriteFailed(write: String, original: String?)

    public var description: String {
        switch self {
        case let .io(what, code):
            "\(what): \(String(cString: strerror(code)))"
        case let .runInProgress(path):
            "another vm create or resume holds the create checkpoint of \(path)"
        case let .bundleBusy(detail):
            "bundle is busy: \(detail)"
        case let .identityMismatch(detail):
            "bundle identity does not match the checkpoint: \(detail)"
        case let .artifactMissing(path):
            "artifact missing: \(path)"
        case let .artifactChanged(name, stage, detail):
            "artifact \(name) recorded by \(stage.rawValue) changed: \(detail)"
        case let .artifactUnavailable(name, stage, rebuild):
            "artifact \(name) needed by \(stage.rawValue) was removed" + (rebuild.map { "; rebuild with: \($0)" } ?? "")
        case let .verificationFailed(stage, detail):
            "re-verification of completed stage \(stage.rawValue) failed: \(detail)"
        case let .recoveryRequired(requirement):
            "recovery required (\(requirement.kind)"
                + (requirement.stage.map { ", stage \($0.rawValue)" } ?? "")
                + "): \(requirement.detail); \(requirement.action)"
        case let .optionsChanged(lines):
            "options differ from the checkpoint and affect stages that already ran: " + lines.joined(separator: "; ")
        case let .toolChanged(recorded, current):
            "vphone-cli executable changed since the checkpoint (\(recorded ?? "unknown") -> \(current ?? "unknown")); "
                + "pass --accept-tool-change to resume with this build"
        case let .contractChanged(recorded, current):
            "stage contract version changed (\(recorded) -> \(current)); this checkpoint cannot be resumed"
        case let .invalidRestart(detail):
            "invalid --restart-from: \(detail)"
        case let .sourceRequired(detail):
            detail
        case let .stageFailed(stage, detail):
            "stage \(stage.rawValue) failed: \(detail)"
        case let .stageCancelled(stage, detail):
            "stage \(stage.rawValue) cancelled: \(detail)"
        case let .checkpointWriteFailed(write, original):
            "checkpoint write failed: \(write)" + (original.map { " (while recording: \($0))" } ?? "")
        }
    }

    public var errorDescription: String? { description }

    /// True for refusals `resume` throws before its first checkpoint write, so
    /// the checkpoint on disk is exactly what it was before the command.
    /// `create` never throws these after its checkpoint exists.
    public var isRefusalBeforeWrite: Bool {
        switch self {
        case .runInProgress, .bundleBusy, .identityMismatch, .artifactChanged, .artifactUnavailable,
             .verificationFailed, .recoveryRequired, .optionsChanged, .toolChanged, .contractChanged,
             .invalidRestart, .sourceRequired:
            true
        case .io, .artifactMissing, .stageFailed, .stageCancelled, .checkpointWriteFailed:
            false
        }
    }
}

// MARK: - Runner

/// Runs create stages through replaceable seams and keeps the checkpoint.
///
/// A stage becomes `succeeded` only when the executor returned and the
/// verifier accepted. Resume follows a fixed order and makes no write until
/// every check has passed.
public struct VPhoneCreateRunner {
    public struct OptionOverrides: Sendable {
        public var variant: String?
        public var iphoneSource: String?
        public var cloudosSource: String?
        public var spoofBuild: String?
        public var forceDscMaxSlide: Bool?
        public var enableFrida: Bool?
        public var diskSizeGb: UInt64?

        public init(
            variant: String? = nil, iphoneSource: String? = nil, cloudosSource: String? = nil,
            spoofBuild: String? = nil, forceDscMaxSlide: Bool? = nil, enableFrida: Bool? = nil,
            diskSizeGb: UInt64? = nil
        ) {
            self.variant = variant
            self.iphoneSource = iphoneSource
            self.cloudosSource = cloudosSource
            self.spoofBuild = spoofBuild
            self.forceDscMaxSlide = forceDscMaxSlide
            self.enableFrida = enableFrida
            self.diskSizeGb = diskSizeGb
        }
    }

    public struct ResumeRequest: Sendable {
        public var overrides: OptionOverrides
        public var restartFrom: VPhoneCreateStage?
        public var acceptToolChange: Bool

        public init(overrides: OptionOverrides = .init(), restartFrom: VPhoneCreateStage? = nil, acceptToolChange: Bool = false) {
            self.overrides = overrides
            self.restartFrom = restartFrom
            self.acceptToolChange = acceptToolChange
        }
    }

    public var executor: any VPhoneCreateStageExecutor
    public var verifier: any VPhoneCreateStageVerifier
    public var prober: any VPhoneCreateStateProber
    public var storeHooks: VPhoneCreateCheckpointStore.Hooks
    public var toolFingerprint: () -> String?
    public var bundleLockHeld: (URL) -> Bool
    public var now: () -> Date
    public var log: (String) -> Void
    public var keepArtifacts: Bool

    public init(
        executor: any VPhoneCreateStageExecutor,
        verifier: any VPhoneCreateStageVerifier,
        prober: any VPhoneCreateStateProber,
        storeHooks: VPhoneCreateCheckpointStore.Hooks = .init(),
        toolFingerprint: @escaping () -> String? = { nil },
        bundleLockHeld: @escaping (URL) -> Bool = { VPhoneVMLockProbe.isLockHeld(directory: $0) },
        now: @escaping () -> Date = Date.init,
        log: @escaping (String) -> Void = { print($0) },
        keepArtifacts: Bool = false
    ) {
        self.executor = executor
        self.verifier = verifier
        self.prober = prober
        self.storeHooks = storeHooks
        self.toolFingerprint = toolFingerprint
        self.bundleLockHeld = bundleLockHeld
        self.now = now
        self.log = log
        self.keepArtifacts = keepArtifacts
    }

    // MARK: Fresh create

    /// Starts the checkpoint of a bundle that was just created and runs every stage.
    @discardableResult
    public func create(
        bundleURL: URL, options: VPhoneCreateEffectiveOptions, iphoneSource: String?, cloudosSource: String?
    ) throws -> VPhoneCreateCheckpoint {
        let bundleURL = bundleURL.standardizedFileURL
        let store = try VPhoneCreateCheckpointStore.initialize(bundleURL: bundleURL, hooks: storeHooks)
        let identity = VPhoneCreateBundleIdentity(
            name: bundleURL.lastPathComponent, path: bundleURL.path,
            directoryId: try VPhoneCreateDigest.directoryId(bundleURL),
            machineIdentifierSha256: VPhoneCreateDigest.machineIdentifierDigest(bundleURL))
        var checkpoint = VPhoneCreateCheckpoint(
            identity: identity, options: options,
            tool: .init(executableSha256: toolFingerprint(), stageContractVersion: VPhoneCreateCheckpoint.stageContractVersion),
            now: now())
        try commit(store, checkpoint, original: nil)
        return try runStages(store: store, checkpoint: &checkpoint, iphoneSource: iphoneSource, cloudosSource: cloudosSource)
    }

    // MARK: Resume

    @discardableResult
    public func resume(bundleURL: URL, request: ResumeRequest = .init()) throws -> VPhoneCreateCheckpoint {
        let bundleURL = bundleURL.standardizedFileURL

        // 1. Occupancy: only one create/resume run, and no other bundle operation.
        let store = try VPhoneCreateCheckpointStore.open(bundleURL: bundleURL, hooks: storeHooks)
        if bundleLockHeld(bundleURL) {
            throw VPhoneCreateRunError.bundleBusy("another process holds the bundle lock of \(bundleURL.path); stop it first")
        }

        // 2. Load, validate, identity.
        let (stored, storedData) = try VPhoneCreateCheckpointStore.load(bundleURL: bundleURL)
        try verifyIdentity(stored, bundleURL: bundleURL)
        guard let next = stored.nextStage ?? request.restartFrom else {
            log("[create] nothing to resume: overall \(stored.overallStatus.rawValue)")
            return stored
        }
        let firstToRun: VPhoneCreateStage
        if let restart = request.restartFrom {
            guard restart <= next else {
                throw VPhoneCreateRunError.invalidRestart("\(restart.rawValue) is after the next unfinished stage \(next.rawValue)")
            }
            firstToRun = restart
        } else {
            firstToRun = next
        }

        // 3. Pending firmware transaction and live state of earlier runs.
        if let requirement = Self.firmwareTransactionRequirement(bundleURL: bundleURL) {
            throw VPhoneCreateRunError.recoveryRequired(requirement)
        }
        var overrides = request.overrides
        var options = stored.effectiveOptions
        if let variant = overrides.variant { options.variant = variant }
        if let source = overrides.iphoneSource { options.iphoneSource = .init(source) }
        if let source = overrides.cloudosSource { options.cloudosSource = .init(source) }
        if let spoof = overrides.spoofBuild { options.spoofBuild = spoof }
        if let value = overrides.forceDscMaxSlide { options.forceDscMaxSlide = value }
        if let value = overrides.enableFrida { options.enableFrida = value }
        if let value = overrides.diskSizeGb { options.diskSizeGb = value }
        if overrides.iphoneSource == nil, let record = stored.effectiveOptions.iphoneSource, !record.redacted {
            overrides.iphoneSource = record.display
        }
        if overrides.cloudosSource == nil, let record = stored.effectiveOptions.cloudosSource, !record.redacted {
            overrides.cloudosSource = record.display
        }
        let probeContext = context(bundleURL: bundleURL, checkpoint: stored, overrides: overrides)
        var checks: [String: String] = [:]
        for record in stored.stages where record.stage >= firstToRun && record.status != .pending && record.status != .notApplicable {
            switch prober.probe(record.stage, context: probeContext) {
            case let .idle(evidence):
                checks["probe.\(record.stage.rawValue)"] = evidence
            case let .busy(detail, action):
                throw VPhoneCreateRunError.recoveryRequired(.init(
                    kind: "live_state", stage: record.stage, detail: detail, action: action))
            }
        }

        // 4. Options, tool and contract.
        var refused: [String] = []
        for change in stored.effectiveOptions.changes(to: options) {
            let touched = stored.stages.filter {
                $0.stage >= change.stage && $0.stage < firstToRun && $0.status != .notApplicable
            }
            if !touched.isEmpty {
                refused.append("\(change.field) affects \(change.stage.rawValue), already \(touched[0].status.rawValue)")
            }
        }
        guard refused.isEmpty else { throw VPhoneCreateRunError.optionsChanged(refused) }
        guard stored.tool.stageContractVersion == VPhoneCreateCheckpoint.stageContractVersion else {
            throw VPhoneCreateRunError.contractChanged(
                recorded: stored.tool.stageContractVersion, current: VPhoneCreateCheckpoint.stageContractVersion)
        }
        let currentTool = toolFingerprint()
        let toolChanged = stored.tool.executableSha256 != currentTool
        if toolChanged, !request.acceptToolChange {
            throw VPhoneCreateRunError.toolChanged(recorded: stored.tool.executableSha256, current: currentTool)
        }
        if firstToRun == .prepare {
            if let record = options.iphoneSource, record.redacted, overrides.iphoneSource == nil {
                throw VPhoneCreateRunError.sourceRequired("prepare must rerun and the recorded iPhone source is redacted; pass --iphone-source again")
            }
            if let record = options.cloudosSource, record.redacted, overrides.cloudosSource == nil {
                throw VPhoneCreateRunError.sourceRequired("prepare must rerun and the recorded cloudOS source is redacted; pass --cloudos-source again")
            }
        }

        // 5. Re-verify every stage that will be skipped, then its artifacts.
        for record in stored.stages where record.stage < firstToRun && (record.status == .succeeded || record.status == .unverified) {
            switch verifier.verify(record.stage, context: probeContext, evidence: record.evidence) {
            case .verified:
                checks["verify.\(record.stage.rawValue)"] = "verified"
            case let .unverified(reason, _, _):
                guard record.status == .unverified else {
                    throw VPhoneCreateRunError.verificationFailed(stage: record.stage, detail: "now unverified: \(reason)")
                }
                checks["verify.\(record.stage.rawValue)"] = "unverified: \(reason)"
            case let .rejected(reason):
                throw VPhoneCreateRunError.verificationFailed(stage: record.stage, detail: reason)
            }
        }
        let rerun = VPhoneCreateStage.allCases.filter { $0 >= firstToRun }
        let rewritten = rerun.reduce(into: Set<String>()) { $0.formUnion(executor.artifactsRewrittenOnRerun($1)) }
        for name in Set(stored.artifacts.map(\.name)).sorted() {
            let records = stored.artifacts.filter { $0.name == name }
            if records.contains(where: { $0.availability == .removed }) {
                // The first rerun stage that rewrites the artifact regenerates it,
                // so only consumers up to and including that stage need the
                // removed copy. Skipped stages are done and re-verified above.
                let regenerator = rerun.first { executor.artifactsRewrittenOnRerun($0).contains(name) }
                let consumers = records.flatMap(\.retainUntil).filter { $0 >= firstToRun }
                let needed = consumers.filter { consumer in regenerator.map { consumer <= $0 } ?? true }.min()
                if let needed {
                    throw VPhoneCreateRunError.artifactUnavailable(name: name, neededBy: needed, rebuild: records.first?.rebuild)
                }
                if let regenerator, !consumers.isEmpty {
                    checks["artifact.\(name)"] = "removed; regenerated by \(regenerator.rawValue) before "
                        + Set(consumers).sorted().map(\.rawValue).joined(separator: ", ")
                }
                continue
            }
            guard !rewritten.contains(name),
                  let baseline = records.filter({ $0.recordedBy < firstToRun }).max(by: { $0.recordedBy < $1.recordedBy }),
                  let expected = baseline.fingerprint
            else { continue }
            let actual: String
            do {
                actual = try VPhoneCreateDigest.fingerprint(baseline.kind, at: bundleURL.appendingPathComponent(baseline.relativePath)).fingerprint
            } catch {
                throw VPhoneCreateRunError.artifactChanged(name: name, recordedBy: baseline.recordedBy, detail: "\(error)")
            }
            guard actual == expected else {
                let later = records.filter { $0.recordedBy >= firstToRun }.map(\.recordedBy.rawValue)
                throw VPhoneCreateRunError.artifactChanged(
                    name: name, recordedBy: baseline.recordedBy,
                    detail: "fingerprint \(expected.prefix(12)) -> \(actual.prefix(12))"
                        + (later.isEmpty ? "" : " (also written by \(later.joined(separator: ", ")); restart from an earlier stage)"))
            }
            checks["artifact.\(name)"] = "matches \(baseline.recordedBy.rawValue)"
        }

        // 6. Start a new attempt; the previous checkpoint bytes are archived first.
        var checkpoint = stored
        let archived = try archive(store, previous: storedData, attemptId: stored.attemptId, checkpoint: stored)
        checkpoint.attemptId = UUID().uuidString.lowercased()
        checkpoint.resumedFrom = .init(
            attemptId: stored.attemptId, checkpointSha256: VPhoneCreateDigest.sha256(storedData), archivedAs: archived)
        checkpoint.attempts.append(.init(
            attemptId: checkpoint.attemptId, kind: "resume", startedAt: now(), pid: getpid(),
            restartFrom: request.restartFrom, acceptedToolChange: toolChanged, checks: checks))
        checkpoint.recoveryRequired = nil
        checkpoint.effectiveOptions = options
        checkpoint.inputsDigest = options.digest
        checkpoint.tool.executableSha256 = currentTool
        for stage in rerun {
            let status = checkpoint.record(stage).status
            let why = switch status {
            case .running: "interrupted: running when its process exited"
            case .failed, .cancelled: "rerun after \(status.rawValue)"
            default: "restart requested from \(firstToRun.rawValue)"
            }
            checkpoint.update(stage) { $0.supersede(because: why, variant: options.variant) }
        }
        checkpoint.artifacts.removeAll { $0.recordedBy >= firstToRun }
        checkpoint.updatedAt = now()
        try commit(store, checkpoint, original: nil)
        log("[create] resuming \(bundleURL.lastPathComponent) from \(firstToRun.rawValue) (attempt \(checkpoint.attemptId))")

        // 7. Run.
        return try runStages(
            store: store, checkpoint: &checkpoint,
            iphoneSource: overrides.iphoneSource, cloudosSource: overrides.cloudosSource)
    }

    // MARK: Stage loop

    private func runStages(
        store: VPhoneCreateCheckpointStore, checkpoint: inout VPhoneCreateCheckpoint,
        iphoneSource: String?, cloudosSource: String?
    ) throws -> VPhoneCreateCheckpoint {
        let overrides = OptionOverrides(iphoneSource: iphoneSource, cloudosSource: cloudosSource)
        let bundleURL = store.bundleURL
        for stage in VPhoneCreateStage.allCases where !checkpoint.record(stage).status.isDone {
            let started = now()
            let inputs = Dictionary(uniqueKeysWithValues: latestArtifacts(checkpoint)
                .filter { $0.availability == .available }
                .compactMap { record in record.fingerprint.map { (record.name, $0) } })
            let attemptId = checkpoint.attemptId
            checkpoint.update(stage) {
                $0.status = .running
                $0.attemptId = attemptId
                $0.pid = getpid()
                $0.startedAt = started
                $0.inputs = inputs
            }
            checkpoint.updatedAt = started
            try commit(store, checkpoint, original: nil)
            log("\n=== \(stage.rawValue) ===")

            let evidence: [String: String]
            do {
                evidence = try executor.execute(stage, context: context(bundleURL: bundleURL, checkpoint: checkpoint, overrides: overrides))
            } catch {
                let cancelled = error is CancellationError
                try recordFailure(
                    store: store, checkpoint: &checkpoint, stage: stage, overrides: overrides,
                    status: cancelled ? .cancelled : .failed, executorResult: "threw", message: "\(error)")
                throw cancelled
                    ? VPhoneCreateRunError.stageCancelled(stage: stage, detail: "\(error)")
                    : VPhoneCreateRunError.stageFailed(stage: stage, detail: "\(error)")
            }

            let verification = verifier.verify(
                stage, context: context(bundleURL: bundleURL, checkpoint: checkpoint, overrides: overrides), evidence: evidence)
            let specs: [VPhoneCreateArtifactSpec]
            let extra: [String: String]
            let unverifiedReason: String?
            switch verification {
            case let .verified(artifacts, more):
                (specs, extra, unverifiedReason) = (artifacts, more, nil)
            case let .unverified(reason, artifacts, more):
                (specs, extra, unverifiedReason) = (artifacts, more, reason)
            case let .rejected(reason):
                try recordFailure(
                    store: store, checkpoint: &checkpoint, stage: stage, overrides: overrides,
                    status: .failed, executorResult: "completed", message: "verifier rejected: \(reason)")
                throw VPhoneCreateRunError.stageFailed(stage: stage, detail: "verifier rejected: \(reason)")
            }
            var records: [VPhoneCreateArtifactRecord] = []
            do {
                for spec in specs {
                    try VPhoneCreateCheckpoint.validateRelativePath(spec.relativePath)
                    let measured = try VPhoneCreateDigest.fingerprint(spec.kind, at: bundleURL.appendingPathComponent(spec.relativePath))
                    records.append(.init(
                        name: spec.name, relativePath: spec.relativePath, kind: spec.kind, fingerprint: measured.fingerprint,
                        sizeBytes: measured.size, availability: .available, recordedBy: stage, retainUntil: spec.retainUntil))
                }
            } catch {
                try recordFailure(
                    store: store, checkpoint: &checkpoint, stage: stage, overrides: overrides,
                    status: .failed, executorResult: "completed", message: "verifier artifact unreadable: \(error)")
                throw VPhoneCreateRunError.stageFailed(stage: stage, detail: "verifier artifact unreadable: \(error)")
            }
            let finished = now()
            let verifierVersion = verifier.version
            checkpoint.update(stage) {
                $0.status = unverifiedReason == nil ? .succeeded : .unverified
                $0.reason = unverifiedReason
                $0.executorResult = "completed"
                $0.verifierVersion = verifierVersion
                $0.evidence = evidence.merging(extra) { _, new in new }
                $0.outputs = records.map(\.name)
                $0.finishedAt = finished
            }
            checkpoint.artifacts.removeAll { $0.recordedBy == stage }
            checkpoint.artifacts.append(contentsOf: records)
            if checkpoint.bundleIdentity.machineIdentifierSha256 == nil {
                checkpoint.bundleIdentity.machineIdentifierSha256 = VPhoneCreateDigest.machineIdentifierDigest(bundleURL)
            }
            checkpoint.updatedAt = finished
            try commit(store, checkpoint, original: nil)
            if let unverifiedReason {
                log("[create] \(stage.rawValue): executor completed; result unverified: \(unverifiedReason)")
            } else {
                log("[create] \(stage.rawValue): succeeded and verified")
            }
            try reclaimArtifacts(store: store, checkpoint: &checkpoint, overrides: overrides)
        }
        return checkpoint
    }

    private func recordFailure(
        store: VPhoneCreateCheckpointStore, checkpoint: inout VPhoneCreateCheckpoint, stage: VPhoneCreateStage,
        overrides: OptionOverrides, status: VPhoneCreateStageStatus, executorResult: String, message: String
    ) throws {
        let finished = now()
        checkpoint.update(stage) {
            $0.status = status
            $0.executorResult = executorResult
            $0.error = message
            $0.finishedAt = finished
        }
        if let requirement = Self.firmwareTransactionRequirement(bundleURL: store.bundleURL) {
            checkpoint.recoveryRequired = requirement
        } else if case let .busy(detail, action) = prober.probe(
            stage, context: context(bundleURL: store.bundleURL, checkpoint: checkpoint, overrides: overrides)) {
            checkpoint.recoveryRequired = .init(kind: "live_state", stage: stage, detail: detail, action: action)
        }
        checkpoint.updatedAt = finished
        try commit(store, checkpoint, original: "\(stage.rawValue) \(status.rawValue): \(message)")
    }

    /// Latest record per artifact name.
    private func latestArtifacts(_ checkpoint: VPhoneCreateCheckpoint) -> [VPhoneCreateArtifactRecord] {
        Dictionary(grouping: checkpoint.artifacts, by: \.name).values
            .compactMap { $0.max { $0.recordedBy < $1.recordedBy } }
            .sorted { $0.name < $1.name }
    }

    private func reclaimArtifacts(
        store: VPhoneCreateCheckpointStore, checkpoint: inout VPhoneCreateCheckpoint, overrides: OptionOverrides
    ) throws {
        guard !keepArtifacts else { return }
        for name in Set(checkpoint.removableArtifacts.map(\.name)).sorted() {
            let records = checkpoint.artifacts.filter { $0.name == name }
            guard records.flatMap(\.retainUntil).allSatisfy({ checkpoint.record($0).status.isDone }),
                  let latest = records.max(by: { $0.recordedBy < $1.recordedBy }),
                  executor.removeArtifact(latest, context: context(bundleURL: store.bundleURL, checkpoint: checkpoint, overrides: overrides))
            else { continue }
            let producer = records.map(\.recordedBy).min() ?? latest.recordedBy
            for index in checkpoint.artifacts.indices where checkpoint.artifacts[index].name == name {
                checkpoint.artifacts[index].availability = .removed
                checkpoint.artifacts[index].removedReason = "removed after every retaining stage finished (default cleanup)"
                checkpoint.artifacts[index].rebuild =
                    "vphone-cli vm create --resume \(store.bundleURL.lastPathComponent) --restart-from \(producer.rawValue)"
            }
            checkpoint.updatedAt = now()
            try commit(store, checkpoint, original: "removal of \(name)")
            log("[create] removed \(latest.relativePath) (no remaining stage needs it)")
        }
    }

    // MARK: Helpers

    private func context(
        bundleURL: URL, checkpoint: VPhoneCreateCheckpoint, overrides: OptionOverrides
    ) -> VPhoneCreateStageContext {
        VPhoneCreateStageContext(
            bundleURL: bundleURL, bundleName: bundleURL.lastPathComponent, options: checkpoint.effectiveOptions,
            iphoneSource: overrides.iphoneSource, cloudosSource: overrides.cloudosSource, checkpoint: checkpoint)
    }

    private func commit(_ store: VPhoneCreateCheckpointStore, _ checkpoint: VPhoneCreateCheckpoint, original: String?) throws {
        do {
            try store.commit(checkpoint)
        } catch {
            throw VPhoneCreateRunError.checkpointWriteFailed(write: "\(error)", original: original)
        }
    }

    private func archive(
        _ store: VPhoneCreateCheckpointStore, previous: Data, attemptId: String, checkpoint: VPhoneCreateCheckpoint
    ) throws -> String {
        do {
            return try store.archive(previous: previous, attemptId: attemptId, checkpoint: checkpoint)
        } catch {
            throw VPhoneCreateRunError.checkpointWriteFailed(write: "\(error)", original: "archive of attempt \(attemptId)")
        }
    }

    private func verifyIdentity(_ checkpoint: VPhoneCreateCheckpoint, bundleURL: URL) throws {
        let identity = checkpoint.bundleIdentity
        guard identity.path == bundleURL.path else {
            throw VPhoneCreateRunError.identityMismatch("recorded path \(identity.path), current \(bundleURL.path)")
        }
        let current = try VPhoneCreateDigest.directoryId(bundleURL)
        guard identity.directoryId == current else {
            throw VPhoneCreateRunError.identityMismatch(
                "directory \(identity.directoryId) was replaced by \(current) (cloned, copied, imported or recreated bundle)")
        }
        if let recorded = identity.machineIdentifierSha256 {
            guard VPhoneCreateDigest.machineIdentifierDigest(bundleURL) == recorded else {
                throw VPhoneCreateRunError.identityMismatch("config.plist machineIdentifier differs from the recorded one")
            }
        }
    }

    /// A pending C4 firmware transaction, described from its journal when readable.
    public static func firmwareTransactionRequirement(bundleURL: URL) -> VPhoneCreateRecoveryRequirement? {
        let root = bundleURL.appendingPathComponent(".firmware-transaction")
        var info = stat()
        guard lstat(root.path, &info) == 0 else { return nil }
        var phase = "unknown (journal unreadable)"
        if let data = try? Data(contentsOf: root.appendingPathComponent("journal.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = object["phase"] as? String {
            phase = value
        }
        return .init(
            kind: "firmware_transaction", stage: .patch,
            detail: "uncommitted firmware transaction at \(root.path), phase \(phase)",
            action: "run `vphone-cli fw patch \(bundleURL.lastPathComponent) --recover`, then resume")
    }
}
