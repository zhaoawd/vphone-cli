import Darwin
import Foundation
import Img4tool
import VPhoneCore

/// A preview contains data only. Publication reacquires Store -> VM -> worker
/// and revalidates the source, desired plan, generation and complete disk bytes.
public enum FirmwareKernelUpdate {
    public struct Prepared: Sendable {
        public let directory: URL
        public let plan: VariantPlanResolver.VariantPlan
        public let generation: FirmwareGeneration.Manifest
        public let desiredSHA256: String
        public let diskSHA256: String
        public let sourceVersion: String
        let binding: VPhoneMachineBinding.Snapshot
        var rollback: FirmwareKernelRollbackSelection? = nil
    }

    public static func prepare(in directory: URL, plan: VariantPlanResolver.VariantPlan,
        generation: FirmwareGeneration.Manifest) throws -> Prepared {
        let directory = directory.standardizedFileURL
        guard directory == directory.resolvingSymlinksInPath(),
              case .ready(let desired) = try FirmwareDesiredPlanStore.read(in: directory),
              desired.plan == plan, desired.generationID == generation.id,
              try FirmwareGeneration.loadVerified(in: directory, id: generation.id) == generation,
              let binding = try VPhoneMachineBinding.snapshot(directory) else {
            throw FirmwareGeneration.fail("Kernel preview requires the current bound plan, generation and host source")
        }
        try FirmwareTransaction.checkMounts(directory, detach: false)
        return try Prepared(directory: directory, plan: plan, generation: generation,
            desiredSHA256: desired.sha256, diskSHA256: FirmwareGeneration.fileSHA256(directory.appendingPathComponent("Disk.img")),
            sourceVersion: binding.binding.bundle, binding: binding)
    }

    public static func publish(_ prepared: Prepared) throws -> FirmwareComponentReceipt.Record {
        try FirmwareInstalledOrigin.withTrustedStore(version: prepared.sourceVersion, machine: prepared.directory) { session, expected in
            guard expected == prepared.binding else { throw FirmwareGeneration.fail("Kernel preview binding changed") }
            return try publish(prepared, session: session, expected: expected)
        }
    }

    /// Recovery never reruns the producer or obtains origin authority from the
    /// archived report. The VM lock and worker lock protect exact-byte recovery.
    public static func recover(in directory: URL) throws -> URL? {
        try VPhoneBundleGuard.withBundleLock(directory: directory, operation: VPhoneVMOperation.fwPatch) { _ in
            // Only mounts inside the pending transaction may be detached by
            // recovery; an externally attached configured disk remains a refusal.
            let raw = try FirmwareTransaction.run("/usr/bin/hdiutil", ["info", "-plist"])
            try requireReleasedDisk(in: directory, observation: raw)
            return try FirmwareTransaction.recover(vmDirectory: directory)
        }
    }

    static func requireReleasedDisk(in directory: URL, observation: Data) throws {
        let object = try PropertyListSerialization.propertyList(from: observation, format: nil) as? [String: Any]
        let disk = directory.appendingPathComponent("Disk.img").resolvingSymlinksInPath().path
        guard let images = object?["images"] as? [[String: Any]],
              images.allSatisfy({ $0["image-path"] is String }),
              !images.contains(where: { ($0["image-path"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == disk } == true }) else {
            throw FirmwareGeneration.fail("Configured disk remains attached or its attachment state is unknown; release it before kernel recovery")
        }
    }

    struct Operations {
        var producer: (FirmwarePipeline, Data, VariantPlanResolver.VariantPlan) throws -> (Data, [ComponentReport]) = {
            try $0.reproduceInstalledComponentReport("kernelcache", input: $1, plan: $2)
        }
        var region: (Data) throws -> FirmwareKernelRegion.Region = FirmwareKernelRegion.inspect
        var volumes: (FirmwareTransaction, Bool) -> FirmwareInstalledReadback.Operations? = { _, _ in nil }
        var mounts: (URL, Bool) throws -> Void = FirmwareTransaction.checkMounts
        var inject: (FirmwareTransaction.Event) throws -> Void = { _ in }
    }

    static func publish(_ prepared: Prepared, session: FirmwareInstalledOrigin.Session,
        expected: VPhoneMachineBinding.Snapshot, operations: Operations = Operations()) throws -> FirmwareComponentReceipt.Record {
        let directory = prepared.directory
        try recheck(prepared, session: session, mounts: operations.mounts)
        let inputs = try FirmwareGeneration.originalURLs(in: directory, id: prepared.generation.id)
        let transaction = try FirmwareTransaction(vmDirectory: directory, inputs: inputs,
            options: ["variant": prepared.plan.variant, "generationID": prepared.generation.id, "desiredSHA256": prepared.desiredSHA256],
            plan: prepared.plan, versionInputs: FirmwareVersionInputs.read(in: directory), kernelOnly: true,
            rollbackSelection: prepared.rollback, inject: operations.inject, mounts: operations.mounts)
        do {
            return try transaction.withWorkerLock {
                try recheck(prepared, session: session, mounts: operations.mounts)
                var reports: [ComponentReport] = []
                let produced = try session.produceBinary(component: "kernelcache", transaction: transaction) { pipeline, bytes, plan in
                    let (payload, result) = try operations.producer(pipeline, bytes, plan)
                    reports = result
                    return (payload, result.flatMap(\.records))
                }
                let report = PatchRunReport(variant: prepared.plan.variant, gates: prepared.plan.gates, components: reports, ablation: [])
                try PatchDeclarationGate.enforceKernel(report: report, plan: prepared.plan)
                let region = try operations.region(produced.payload)
                let disk = directory.appendingPathComponent("Disk.img")
                let candidate = transaction.work.appendingPathComponent("kernel-candidate.img")
                try FileManager.default.copyItem(at: disk, to: candidate)
                guard try FirmwareGeneration.fileSHA256(candidate) == prepared.diskSHA256 else { throw FirmwareGeneration.fail("Kernel disk changed during clone") }
                let source = try VPhoneCreateDigest.strictFileData(produced.input, maximumBytes: 512 << 20)
                guard VPhoneCreateDigest.sha256(source) == produced.inputSHA256 else {
                    throw FirmwareGeneration.fail("Kernel generation input changed before repack")
                }
                let replacement = try VPhoneKernelcacheSwap.repackKernelPayload(produced.payload, sourceIM4P: source)
                if let rollback = prepared.rollback {
                    guard VPhoneCreateDigest.sha256(produced.payload) == rollback.targetPayloadSHA256,
                          VPhoneCreateDigest.sha256(replacement) == rollback.targetIM4PSHA256 else {
                        throw FirmwareGeneration.fail("Fresh verified producer differs from the historical rollback target")
                    }
                }
                try FirmwareGeneration.write(replacement, to: transaction.root.appendingPathComponent(FirmwareKernelHistory.artifactName))
                var currentEnvelope: Data?
                try FirmwareKernelMount.withVolumes(image: candidate, transaction: transaction, writable: true, operations: operations.volumes(transaction, true)) { roots in
                    guard let preboot = roots["preboot"], let system = roots["system"] else { throw FirmwareGeneration.fail("Kernel candidate volumes missing") }
                    let target = try FirmwareKernelMount.uniqueKernel(in: preboot)
                    try FirmwareKernelDSC.validate(system: system, region: region)
                    let current = try VPhoneCreateDigest.strictFileData(target, maximumBytes: 512 << 20)
                    currentEnvelope = try VPhoneKernelcacheSwap.containerEnvelope(current)
                    if let updated = try VPhoneKernelcacheSwap.replacingPayload(in: current, with: replacement) {
                        // Preserve the existing file's metadata, including owner
                        // and mode. Only candidate payload bytes are replaced.
                        let fd = open(target.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
                        guard fd >= 0 else { throw POSIXError(.EIO) }
                        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                        defer { try? handle.close() }
                        try handle.seek(toOffset: 0); try handle.write(contentsOf: updated)
                        try handle.truncate(atOffset: UInt64(updated.count)); try handle.synchronize()
                        guard try VPhoneCreateDigest.strictFileData(target, maximumBytes: 512 << 20) == updated else {
                            throw FirmwareGeneration.fail("Candidate Preboot write did not read back")
                        }
                    }
                }
                guard let currentEnvelope else { throw FirmwareGeneration.fail("Current kernel container envelope is missing") }
                try recheck(prepared, session: session, mounts: operations.mounts)
                try transaction.prepareKernelDisk(candidate: candidate)
                try transaction.saveReport(report)
                try transaction.prepareKernelReceipts(report: report)
                let imageSHA = try FirmwareGeneration.fileSHA256(candidate)
                let effects = try produced.records.map { record -> FirmwareComponentReceipt.Effect in
                    let owners = prepared.plan.selected.filter { ($0.recordRules ?? []).contains { $0.matches(record) } }
                    guard owners.count == 1, let owner = owners.first else { throw FirmwareGeneration.fail("Kernel effect has no unique selected declaration") }
                    return .init(declarationID: owner.id, outputPath: "Disk.img", record: record)
                }
                let receipt = FirmwareComponentReceipt.Record(schemaVersion: 1, component: "kernelcache", scope: .installedComponent,
                    state: .committed, generationID: prepared.generation.id, planSHA256: try FirmwareGeneration.planDigest(prepared.plan),
                    desiredSHA256: prepared.desiredSHA256, outputs: [.init(path: "Disk.img", sha256: imageSHA)], effects: effects)
                var proofFields: [String: Any] = ["schemaVersion": 1, "producer": "current-bundle-kernel-update",
                    "version": session.version, "executableSHA256": session.executableSHA256,
                    "inputSHA256": produced.inputSHA256, "payloadSHA256": VPhoneCreateDigest.sha256(produced.payload),
                    "im4pSHA256": VPhoneCreateDigest.sha256(replacement),
                    "imageSHA256": imageSHA, "transactionID": transaction.journalSnapshot.id,
                    "rollbackProtocol": FirmwareKernelHistory.protocolName,
                    "containerEnvelopeSHA256": VPhoneCreateDigest.sha256(currentEnvelope)]
                if let rollback = prepared.rollback {
                    proofFields["operation"] = "kernel-rollback"
                    proofFields["targetTransactionID"] = rollback.targetTransactionID
                    proofFields["targetDesiredSHA256"] = try rollback.targetDesired.sha256
                    proofFields["liveDesiredSHA256"] = rollback.liveDesiredSHA256
                    proofFields["bindingSHA256"] = rollback.bindingSHA256
                    proofFields["targetEvidenceSHA256"] = rollback.targetEvidenceSHA256
                }
                let proof = try JSONSerialization.data(withJSONObject: proofFields, options: [.sortedKeys])
                _ = try transaction.commit(origin: .init(transactionID: transaction.journalSnapshot.id, layer: .kernel, expected: expected,
                    binding: expected.binding.replacingOrigin(.kernel, with: session.version), receipt: receipt, proof: proof,
                    recheck: { point in
                        try session.recheck()
                        guard try FirmwareGeneration.fileSHA256(produced.input) == produced.inputSHA256 else { throw FirmwareGeneration.fail("Kernel generation input changed") }
                        let image = point == .candidate ? candidate : disk
                        guard try FirmwareGeneration.fileSHA256(image) == imageSHA else { throw FirmwareGeneration.fail("Kernel image differs from candidate") }
                        try FirmwareKernelMount.withVolumes(image: image, transaction: transaction, writable: false, operations: operations.volumes(transaction, false)) { roots in
                            guard let preboot = roots["preboot"], let system = roots["system"] else { throw FirmwareGeneration.fail("Kernel readback volumes missing") }
                            let target = try FirmwareKernelMount.uniqueKernel(in: preboot)
                            let data = try VPhoneCreateDigest.strictFileData(target, maximumBytes: 512 << 20)
                            guard try VPhoneKernelcacheSwap.containerEnvelope(data) == currentEnvelope else {
                                throw FirmwareGeneration.fail("Installed kernel IM4M/IM4R envelope differs from the current disk")
                            }
                            let im4p = try IMG4(data).im4p()
                            guard im4p.data == replacement else { throw FirmwareGeneration.fail("Installed kernel metadata differs from pristine-source repack") }
                            let payload = try im4p.payload()
                            guard payload == produced.payload else { throw FirmwareGeneration.fail("Installed kernel differs from actual producer") }
                            for effect in effects { try FirmwareComponentReceipt.verifyEffect(effect.record, payload: payload) }
                            try FirmwareKernelDSC.validate(system: system, region: region)
                        }
                        try session.recheck()
                    }))
                return receipt
            }
        } catch { transaction.recordFailure(error); throw error }
    }

    private static func recheck(_ prepared: Prepared, session: FirmwareInstalledOrigin.Session, mounts: (URL, Bool) throws -> Void) throws {
        try session.recheck()
        if let rollback = prepared.rollback {
            try rollback.validate(in: prepared.directory)
            guard session.executableSHA256 == rollback.sourceExecutableSHA256 else { throw FirmwareGeneration.fail("Kernel rollback producer code differs") }
        } else {
            guard case .ready(let desired) = try FirmwareDesiredPlanStore.read(in: prepared.directory),
                  try desired.sha256 == prepared.desiredSHA256, desired.plan == prepared.plan else {
                throw FirmwareGeneration.fail("Kernel preview desired plan changed")
            }
        }
        guard session.version == prepared.sourceVersion,
              try FirmwareGeneration.loadVerified(in: prepared.directory, id: prepared.generation.id) == prepared.generation,
              try FirmwareGeneration.fileSHA256(prepared.directory.appendingPathComponent("Disk.img")) == prepared.diskSHA256 else {
            throw FirmwareGeneration.fail("Kernel preview changed before publication")
        }
        try mounts(prepared.directory, false)
        try FirmwareGeneration.checkCancellation()
    }
}
