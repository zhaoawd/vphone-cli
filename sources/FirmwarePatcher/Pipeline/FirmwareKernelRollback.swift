import Darwin
import Foundation
import VPhoneKernelIOTrace
import VPhoneCore

/// Historical bytes select an expected result. Only a live verified producer
/// can authorize publication; neither this Codable selection nor an archive can.
struct FirmwareKernelRollbackSelection: Codable, Equatable, Sendable {
    let targetTransactionID: String
    let targetEvidenceSHA256: String
    let targetDesired: FirmwareDesiredPlanStore.Record
    let targetPayloadSHA256: String
    let targetIM4PSHA256: String
    let sourceVersion: String
    let sourceExecutableSHA256: String
    let liveDesiredSHA256: String
    let bindingSHA256: String

    func validateStructure(journal: FirmwareTransaction.Journal) throws {
        guard journal.version == 4, journal.kernelOnly == true,
              UUID(uuidString: targetTransactionID)?.uuidString.lowercased() == targetTransactionID,
              targetTransactionID != journal.id, journal.plan == targetDesired.plan,
              journal.options["generationID"] == targetDesired.generationID,
              try journal.options["desiredSHA256"] == targetDesired.sha256,
              [targetEvidenceSHA256, targetPayloadSHA256, targetIM4PSHA256,
               sourceExecutableSHA256, liveDesiredSHA256, bindingSHA256].allSatisfy(Self.isSHA256) else {
            throw FirmwareGeneration.fail("Invalid kernel rollback selection contract")
        }
    }

    func validate(in directory: URL) throws {
        try FirmwareDesiredPlanStore.validate(targetDesired, in: directory)
        guard case .ready(let live) = try FirmwareDesiredPlanStore.read(in: directory),
              try live.sha256 == liveDesiredSHA256 else { throw FirmwareDesiredPlanStore.Failure.changedSincePreview }
        try Self.requireCompatible(target: targetDesired, live: live)
        let history = try FirmwareKernelHistory.read(in: directory, transactionID: targetTransactionID)
        guard history.evidenceSHA256 == targetEvidenceSHA256,
              history.desired == targetDesired, history.payloadSHA256 == targetPayloadSHA256,
              history.im4pSHA256 == targetIM4PSHA256,
              history.version == sourceVersion, history.executableSHA256 == sourceExecutableSHA256 else {
            throw FirmwareGeneration.fail("Kernel rollback target changed since preview")
        }
    }

    static func requireCompatible(target: FirmwareDesiredPlanStore.Record, live: FirmwareDesiredPlanStore.Record) throws {
        let a = target.plan, b = live.plan, x = a.gates, y = b.gates
        func nonKernel(_ entries: [VariantPlanResolver.Entry]) -> [VariantPlanResolver.Entry] {
            entries.filter { !$0.swiftSteps.contains(where: { $0.hasPrefix("kernelcache.") }) }
        }
        guard target.generationID == live.generationID, target.identity == live.identity,
              target.catalogSHA256 == live.catalogSHA256, target.upstreamTarget == live.upstreamTarget,
              a.variant == b.variant, a.upstreamTag == b.upstreamTag,
              x.iosBaseIs18 == y.iosBaseIs18, x.iosBaseIs27 == y.iosBaseIs27,
              x.cloudOSIsFridaCapable == y.cloudOSIsFridaCapable,
              x.experimentalV2RootRemount == y.experimentalV2RootRemount, x.guestEnvironmentV2 == y.guestEnvironmentV2,
              nonKernel(a.selected) == nonKernel(b.selected),
              nonKernel(a.excludedByVersion) == nonKernel(b.excludedByVersion),
              nonKernel(a.excludedByOptIn) == nonKernel(b.excludedByOptIn),
              nonKernel(a.excludedByVariant) == nonKernel(b.excludedByVariant),
              nonKernel(a.guestUncovered) == nonKernel(b.guestUncovered),
              nonKernel(a.notImplemented) == nonKernel(b.notImplemented),
              a.enabledSteps.filter({ !$0.hasPrefix("kernelcache.") }) == b.enabledSteps.filter({ !$0.hasPrefix("kernelcache.") }) else {
            throw FirmwareGeneration.fail("Kernel rollback requires the same generation, context and non-kernel selection")
        }
    }
    static func isSHA256(_ value: String) -> Bool { value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
}

/// Strict history reader deliberately does not compare a historical whole-disk
/// digest to the post-boot live disk. Fresh production is required at publish.
enum FirmwareKernelHistory {
    static let protocolName = "vphone.kernel-rollback.v1"
    static let artifactName = "installed-kernel.im4p"
    struct Target {
        let transactionID: String
        let desired: FirmwareDesiredPlanStore.Record
        let version: String
        let executableSHA256: String
        let payloadSHA256: String
        let im4pSHA256: String
        let evidenceSHA256: String
    }
    static func read(in directory: URL, transactionID: String) throws -> Target {
        guard UUID(uuidString: transactionID)?.uuidString.lowercased() == transactionID else {
            throw FirmwareGeneration.fail("Kernel rollback target must be a canonical transaction UUID")
        }
        let history = directory.appendingPathComponent(".firmware-history")
        let root = history.appendingPathComponent(transactionID)
        try FirmwareGeneration.ensureDirectory(history, create: false)
        try FirmwareGeneration.ensureDirectory(root, create: false)
        func read(_ name: String, limit: Int = 64 << 20) throws -> Data {
            let file = root.appendingPathComponent(name)
            var info = stat()
            guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else {
                throw FirmwareGeneration.fail("Historical evidence must be one ordinary unlinked file")
            }
            return try VPhoneCreateDigest.strictFileData(file, maximumBytes: limit)
        }
        let journalBytes = try read("journal.json", limit: 16 << 20)
        let journal = try FirmwareTransaction.readJournal(at: root.appendingPathComponent("journal.json"))
        guard journal.id == transactionID, journal.phase == .committed, journal.kernelOnly == true,
              let binding = journal.planBinding, let plan = journal.plan,
              let generationID = journal.options["generationID"], let disk = journal.kernelDisk,
              disk.direction == .forward, !disk.pending, disk.cursor == disk.offsets.count else {
            throw FirmwareGeneration.fail("Kernel rollback target is not a committed kernel transaction")
        }
        try binding.validate(journal: journal, directory: directory, currentCatalog: true)
        let generation = try FirmwareGeneration.loadVerified(in: directory, id: generationID)
        let desired = FirmwareDesiredPlanStore.Record(schemaVersion: 1,
            upstreamTarget: binding.payload.upstreamTarget, catalogSHA256: binding.payload.catalogSHA256,
            planSHA256: binding.planSHA256, generationID: generationID, identity: generation.content.identity, plan: plan)
        try FirmwareDesiredPlanStore.validate(desired, in: directory)
        guard try desired.sha256 == journal.options["desiredSHA256"] else { throw FirmwareGeneration.fail("Historical desired plan association differs") }
        let reportBytes = try read("report.json"), publicationBytes = try read("component-receipts.json")
        let proofBytes = try read("installed-component-proof.json")
        guard VPhoneCreateDigest.sha256(reportBytes) == journal.reportSHA256,
              VPhoneCreateDigest.sha256(publicationBytes) == journal.componentReceiptsSHA256 else {
            throw FirmwareGeneration.fail("Historical report or receipt differs from journal")
        }
        let report = try JSONDecoder().decode(PatchRunReport.self, from: reportBytes)
        try PatchDeclarationGate.enforceKernel(report: report, plan: plan)
        let publication = try JSONDecoder().decode(FirmwareTransaction.ComponentPublication.self, from: publicationBytes)
        guard publication.schemaVersion == 1, publication.transactionID == transactionID,
              publication.records.isEmpty, publication.filesystem == nil, publication.filesystemProofSHA256 == nil,
              publication.originLayer == .kernel, publication.originProofSHA256 == VPhoneCreateDigest.sha256(proofBytes),
              let receipt = publication.installed, receipt.schemaVersion == 1,
              receipt.scope == .installedComponent, receipt.state == .committed, receipt.component.lowercased() == "kernelcache",
              receipt.generationID == generationID, receipt.planSHA256 == binding.planSHA256,
              receipt.desiredSHA256 == journal.options["desiredSHA256"],
              receipt.outputs == [.init(path: "Disk.img", sha256: disk.candidateSHA256)],
              receipt.effects.map(\.record) == report.allRecords,
              journal.metadata?.contains(where: { $0.name == FirmwareTransaction.ComponentPublication.filename && $0.output == journal.componentReceiptsSHA256 }) == true else {
            throw FirmwareGeneration.fail("Historical kernel receipt relationship differs")
        }
        guard let proof = try JSONSerialization.jsonObject(with: proofBytes) as? [String: Any],
              proof["schemaVersion"] as? Int == 1,
              proof["rollbackProtocol"] as? String == protocolName,
              proof["producer"] as? String == "current-bundle-kernel-update",
              proof["transactionID"] as? String == transactionID,
              proof["imageSHA256"] as? String == disk.candidateSHA256,
              let version = proof["version"] as? String,
              let executable = proof["executableSHA256"] as? String, FirmwareKernelRollbackSelection.isSHA256(executable),
              let envelope = proof["containerEnvelopeSHA256"] as? String, FirmwareKernelRollbackSelection.isSHA256(envelope),
              let inputSHA = proof["inputSHA256"] as? String,
              let payloadSHA = proof["payloadSHA256"] as? String, FirmwareKernelRollbackSelection.isSHA256(payloadSHA),
              let im4pSHA = proof["im4pSHA256"] as? String, FirmwareKernelRollbackSelection.isSHA256(im4pSHA) else {
            throw FirmwareGeneration.fail("Historical producer lacks the supported rollback evidence protocol; old bundles require a verified producer adapter")
        }
        if let rollback = journal.rollbackSelection {
            guard proof["operation"] as? String == "kernel-rollback",
                  proof["targetTransactionID"] as? String == rollback.targetTransactionID,
                  try proof["targetDesiredSHA256"] as? String == rollback.targetDesired.sha256,
                  proof["liveDesiredSHA256"] as? String == rollback.liveDesiredSHA256,
                  proof["bindingSHA256"] as? String == rollback.bindingSHA256,
                  proof["targetEvidenceSHA256"] as? String == rollback.targetEvidenceSHA256,
                  version == rollback.sourceVersion, executable == rollback.sourceExecutableSHA256,
                  im4pSHA == rollback.targetIM4PSHA256, payloadSHA == rollback.targetPayloadSHA256 else {
                throw FirmwareGeneration.fail("Historical rollback proof differs from its schema4 selection")
            }
        }
        let artifact = try read(artifactName, limit: 512 << 20)
        let payload = try VPhoneKernelcacheSwap.rollbackArtifactPayload(artifact)
        guard VPhoneCreateDigest.sha256(artifact) == im4pSHA, VPhoneCreateDigest.sha256(payload) == payloadSHA else {
            throw FirmwareGeneration.fail("Historical kernel artifact differs from proof")
        }
        let roots = try FirmwareGeneration.originalURLs(in: directory, id: generationID)
        guard let restore = roots.first(where: { $0.lastPathComponent.contains("Restore") }),
              let variant = FirmwarePipeline.Variant(rawValue: plan.variant) else { throw FirmwareGeneration.fail("Historical generation source missing") }
        let pipeline = FirmwarePipeline(vmDirectory: directory, variant: variant, verbose: false)
        guard let component = pipeline.buildComponentList().first(where: { $0.name.lowercased() == "kernelcache" }) else {
            throw FirmwareGeneration.fail("Historical kernel component descriptor missing")
        }
        let input = try pipeline.findFile(in: restore, patterns: component.searchPatterns, label: "kernelcache")
        guard try FirmwareGeneration.fileSHA256(input) == inputSHA else { throw FirmwareGeneration.fail("Historical producer input differs from generation") }
        for effect in receipt.effects {
            let owners = plan.selected.filter { ($0.recordRules ?? []).contains { $0.matches(effect.record) } }
            guard owners.count == 1, owners[0].id == effect.declarationID, effect.outputPath == "Disk.img" else {
                throw FirmwareGeneration.fail("Historical effect declaration differs")
            }
            try FirmwareComponentReceipt.verifyEffect(effect.record, payload: payload)
        }
        let digest = VPhoneCreateDigest.sha256(journalBytes + reportBytes + publicationBytes + proofBytes + Data(im4pSHA.utf8))
        return Target(transactionID: transactionID, desired: desired, version: version, executableSHA256: executable,
            payloadSHA256: payloadSHA, im4pSHA256: im4pSHA, evidenceSHA256: digest)
    }
}

public enum FirmwareKernelRollback {
    public struct Target: Encodable, Sendable {
        public let transactionID: String
        public let planSHA256: String?
        public let payloadSHA256: String?
        public let eligible: Bool
        public let reason: String?
        public let eligibilityScope = "historical-selection-only; publication requires fresh verified producer"
        public let sourceVersion: String?
        public let executableSHA256: String?
        public let generationID: String?
        public let im4pSHA256: String?
    }
    public struct Prepared: Sendable {
        public let transactionID: String
        public let targetPlanSHA256: String
        public let targetPayloadSHA256: String
        public let liveDesiredSHA256: String
        let update: FirmwareKernelUpdate.Prepared
    }
    public static func targets(in directory: URL) throws -> [Target] {
        guard case .ready(let live) = try FirmwareDesiredPlanStore.read(in: directory),
              let binding = try VPhoneMachineBinding.snapshot(directory) else { throw FirmwareGeneration.fail("Kernel rollback requires a bound current desired plan") }
        let root = directory.appendingPathComponent(".firmware-history")
        if !FileManager.default.fileExists(atPath: root.path) { return [] }
        try FirmwareGeneration.ensureDirectory(root, create: false)
        return try FileManager.default.contentsOfDirectory(atPath: root.path).sorted().map { id in
            do {
                let target = try FirmwareKernelHistory.read(in: directory, transactionID: id)
                try FirmwareKernelRollbackSelection.requireCompatible(target: target.desired, live: live)
                guard target.version == binding.binding.bundle else { throw FirmwareGeneration.fail("Target requires another verified producer; cross-bundle rollback is unsupported") }
                return Target(transactionID: id, planSHA256: target.desired.planSHA256, payloadSHA256: target.payloadSHA256, eligible: true, reason: nil, sourceVersion: target.version, executableSHA256: target.executableSHA256, generationID: target.desired.generationID, im4pSHA256: target.im4pSHA256)
            } catch { return Target(transactionID: id, planSHA256: nil, payloadSHA256: nil, eligible: false, reason: String(describing: error), sourceVersion: nil, executableSHA256: nil, generationID: nil, im4pSHA256: nil) }
        }
    }
    public static func prepare(in directory: URL, transactionID: String) throws -> Prepared {
        return try KernelIOTrace.measure("kernelRollback.prepare") { _ in
            let directory = directory.standardizedFileURL
            guard directory == directory.resolvingSymlinksInPath(),
                  case .ready(let live) = try FirmwareDesiredPlanStore.read(in: directory),
                  let binding = try VPhoneMachineBinding.snapshot(directory) else { throw FirmwareGeneration.fail("Kernel rollback requires a bound current desired plan") }
            let target = try FirmwareKernelHistory.read(in: directory, transactionID: transactionID)
            try FirmwareKernelRollbackSelection.requireCompatible(target: target.desired, live: live)
            guard target.version == binding.binding.bundle else { throw FirmwareGeneration.fail("Cross-bundle kernel rollback is unsupported") }
            let selection = FirmwareKernelRollbackSelection(targetTransactionID: transactionID, targetEvidenceSHA256: target.evidenceSHA256,
                targetDesired: target.desired, targetPayloadSHA256: target.payloadSHA256, targetIM4PSHA256: target.im4pSHA256,
                sourceVersion: target.version, sourceExecutableSHA256: target.executableSHA256,
                liveDesiredSHA256: try live.sha256, bindingSHA256: binding.sha256)
            try selection.validate(in: directory)
            try FirmwareTransaction.checkMounts(directory, detach: false)
            let update = FirmwareKernelUpdate.Prepared(directory: directory, plan: target.desired.plan,
                generation: try FirmwareGeneration.loadVerified(in: directory, id: live.generationID), desiredSHA256: try target.desired.sha256,
                diskSHA256: try FirmwareGeneration.fileSHA256(directory.appendingPathComponent("Disk.img")),
                sourceVersion: binding.binding.bundle, binding: binding, rollback: selection)
            return Prepared(transactionID: transactionID, targetPlanSHA256: target.desired.planSHA256,
                targetPayloadSHA256: target.payloadSHA256, liveDesiredSHA256: try live.sha256, update: update)
        }
    }
    public static func publish(_ prepared: Prepared) throws -> FirmwareComponentReceipt.Record { try FirmwareKernelUpdate.publish(prepared.update) }
}
