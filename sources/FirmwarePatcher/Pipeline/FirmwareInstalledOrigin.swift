import Foundation
import VPhoneKernelIOTrace
import Img4tool
import VPhoneBundleStore
import VPhoneCore

/// Qualified installation scopes are never Codable. Production acquisition
/// keeps Store -> VM -> transaction-worker lock order for the complete operation.
/// The host binder already takes Store -> VM in this order.
enum FirmwareInstalledOrigin {
    static func withTrustedStore<T>(version: String, machine: URL,
        body: (Session, VPhoneMachineBinding.Snapshot) throws -> T) throws -> T {
        try VPhoneCoreBundleStore().withRevalidatedExecutable(version: version, executable: .cli) { executable, verify in
            try withVerifiedSource(version: version, executable: executable,
                effectiveExecutable: VPhoneResources.runningExecutable(), recheck: verify) { session in
                try VPhoneBundleGuard.withBundleLock(directory: machine, operation: VPhoneVMOperation.fwPatch) { _ in
                    guard let expected = try VPhoneMachineBinding.snapshot(machine) else {
                        throw FirmwareGeneration.fail("Installed origin requires an existing host binding")
                    }
                    let resources = VPhoneResources.resolve(executablePath: executable.path)
                    return try VPhoneResources.withCreateResources(resources) { try body(session, expected) }
                }
            }
        }
    }

    /// Internal verifier seam: tests substitute only Store/code-sign validation,
    /// never the byte/effect association or transaction publication checks.
    static func withVerifiedSource<T>(version: String, executable: URL, effectiveExecutable: URL,
        recheck: @escaping () throws -> Void, body: (Session) throws -> T) throws -> T {
        guard VPhoneCoreBundleVersion.supportsTargetFeatures(version),
              executable.standardizedFileURL == effectiveExecutable.standardizedFileURL,
              executable == executable.resolvingSymlinksInPath() else {
            throw FirmwareGeneration.fail("Effective executable differs from the verified Core Bundle")
        }
        let session = try Session(version: version, executable: executable, verify: recheck)
        defer { session.active = false }
        try session.recheck()
        let result = try body(session)
        try session.recheck()
        return result
    }

    struct ProducedBinary {
        let session: Session
        let transactionID: String
        let component: String
        let input: URL
        let inputSHA256: String
        let payload: Data
        let records: [PatchRecord]
    }

    final class Session {
        let version: String
        let executable: URL
        let executableSHA256: String
        fileprivate var active = true
        private let verify: () throws -> Void
        fileprivate init(version: String, executable: URL, verify: @escaping () throws -> Void) throws {
            self.version = version
            self.executable = executable
            executableSHA256 = try FirmwareGeneration.fileSHA256(executable)
            self.verify = verify
        }
        func produceBinary(component: String, transaction: FirmwareTransaction) throws -> ProducedBinary {
            try produceBinary(component: component, transaction: transaction, producer: { pipeline, bytes, plan in
                try pipeline.reproduceInstalledComponent(component, input: bytes, plan: plan)
            })
        }

        // The only substituted operation in firmware-free tests is the actual
        // patch algorithm. Production always calls reproduceInstalledComponent.
        func produceBinary(component: String, transaction: FirmwareTransaction,
            producer: (FirmwarePipeline, Data, VariantPlanResolver.VariantPlan) throws -> (Data, [PatchRecord])) throws -> ProducedBinary {
            try recheck()
            let journal = transaction.journalSnapshot
            guard let plan = journal.plan, let variant = FirmwarePipeline.Variant(rawValue: plan.variant),
                  let id = journal.options["generationID"], journal.phase == .building,
                  component.lowercased() == "kernelcache" else {
                throw FirmwareGeneration.fail("Installed binary has no current frozen producer")
            }
            try journal.planBinding?.validate(journal: journal, directory: transaction.vmDirectory, currentCatalog: true)
            if let rollback = journal.rollbackSelection {
                try rollback.validateStructure(journal: journal)
                try rollback.validate(in: transaction.vmDirectory)
                guard version == rollback.sourceVersion, executableSHA256 == rollback.sourceExecutableSHA256 else {
                    throw FirmwareGeneration.fail("Kernel rollback requires the same live verified producer executable")
                }
            }
            let roots = try FirmwareGeneration.originalURLs(in: transaction.vmDirectory, id: id)
            let restores = roots.filter { $0.lastPathComponent.contains("Restore") }
            guard restores.count == 1 else { throw FirmwareGeneration.fail("Ambiguous pristine restore input") }
            let pipeline = FirmwarePipeline(vmDirectory: transaction.vmDirectory, variant: variant, verbose: false,
                forceExcGuard: plan.gates.forceExcGuard, enableFrida: plan.gates.enableFrida,
                experimentalV2RootRemount: plan.gates.experimentalV2RootRemount == true,
                generationID: id, guestEnvironmentV2: plan.gates.guestEnvironmentV2)
            guard let descriptor = pipeline.buildComponentList().first(where: { $0.name.lowercased() == component.lowercased() }) else {
                throw FirmwareGeneration.fail("Unknown installed component")
            }
            let input = try pipeline.findFile(in: restores[0], patterns: descriptor.searchPatterns, label: component)
            _ = try FirmwareComponentReceipt.relative(input, in: restores[0])
            var raw = Data()
            try FirmwareGeneration.readFile(input) { raw.append($0) }
            let sourceSHA = VPhoneCreateDigest.sha256(raw)
            let bytes = try (try? IM4P(raw)).map { try $0.payload() } ?? raw
            let (payload, records) = try producer(pipeline, bytes, plan)
            guard !records.isEmpty, try FirmwareGeneration.fileSHA256(input) == sourceSHA else {
                throw FirmwareGeneration.fail("Installed producer has no records or changed source")
            }
            // A complete result must retain every emitted effect and be explained
            // by the producer's exact ordered byte changes from the pristine input.
            var reconstructed = Data(bytes)
            for record in records {
                guard record.component.lowercased() == component.lowercased(), record.fileOffset >= 0,
                      record.fileOffset <= reconstructed.count,
                      record.originalBytes.count <= reconstructed.count - record.fileOffset,
                      reconstructed.subdata(in: record.fileOffset ..< record.fileOffset + record.originalBytes.count) == record.originalBytes else {
                    throw FirmwareGeneration.fail("Installed producer input/effect relationship differs")
                }
                reconstructed.replaceSubrange(record.fileOffset ..< record.fileOffset + record.originalBytes.count, with: record.patchedBytes)
                try FirmwareComponentReceipt.verifyEffect(record, payload: payload)
            }
            guard reconstructed == payload else { throw FirmwareGeneration.fail("Installed producer has unexplained output changes") }
            try recheck()
            return ProducedBinary(session: self, transactionID: journal.id, component: component,
                input: input, inputSHA256: sourceSHA, payload: payload, records: records)
        }

        func commitBinary(_ produced: ProducedBinary, transaction: FirmwareTransaction,
                          expected: VPhoneMachineBinding.Snapshot,
                          readback: FirmwareInstalledReadback.Operations? = nil) throws -> URL {
            try recheck()
            guard produced.session === self, produced.transactionID == transaction.journalSnapshot.id else {
                throw FirmwareGeneration.fail("Installed producer scope or transaction expired")
            }
            guard produced.component.lowercased() == "kernelcache" else {
                throw FirmwareGeneration.fail("Boot-chain origin requires the complete installed component set")
            }
            let layer: VPhoneMachineBinding.Layer = .kernel
            let reader = try FirmwareInstalledReadback(transaction: transaction)
            let journal = transaction.journalSnapshot
            guard let plan = journal.plan, let generation = journal.options["generationID"],
                  let planSHA = journal.planBinding?.planSHA256, let desiredSHA = journal.options["desiredSHA256"] else {
                throw FirmwareGeneration.fail("Installed origin has no current transaction")
            }
            let effects = try produced.records.map { record -> FirmwareComponentReceipt.Effect in
                let owners = plan.selected.filter { ($0.recordRules ?? []).contains { $0.matches(record) } }
                guard owners.count == 1, let owner = owners.first,
                      owner.swiftSteps.contains(where: { $0.hasPrefix(produced.component.lowercased() + ".") }) else {
                    throw FirmwareGeneration.fail("Installed effect has no unique selected declaration")
                }
                return .init(declarationID: owner.id, outputPath: "Disk.img", record: record)
            }
            for entry in plan.selected where entry.required && entry.swiftSteps.contains(where: { $0.hasPrefix(produced.component.lowercased() + ".") }) {
                guard effects.contains(where: { $0.declarationID == entry.id }) else { throw FirmwareGeneration.fail("Installed producer misses required declaration") }
            }
            let verify: () throws -> Void = {
                try self.recheck()
                guard try FirmwareGeneration.fileSHA256(produced.input) == produced.inputSHA256 else {
                    throw FirmwareGeneration.fail("Pristine installed component source changed")
                }
                let body: (FirmwareInstalledReadback.Volumes) throws -> Void = { volumes in
                    let data = try volumes.readUniqueComponent(produced.component)
                    let payload: Data
                    if let img4 = try? IMG4(data) { payload = try img4.im4p().payload() }
                    else if let im4p = try? IM4P(data) { payload = try im4p.payload() }
                    else { payload = data }
                    guard payload == produced.payload else { throw FirmwareGeneration.fail("Installed payload differs from the verified Bundle producer") }
                    for effect in effects { try FirmwareComponentReceipt.verifyEffect(effect.record, payload: payload) }
                }
                if let readback { try reader.withReadOnlyVolumes(operations: readback, body: body) }
                else { try reader.withReadOnlyVolumes(body: body) }
                try self.recheck()
            }
            try verify()
            let receipt = FirmwareComponentReceipt.Record(schemaVersion: 1, component: produced.component,
                scope: .installedComponent, state: .committed, generationID: generation,
                planSHA256: planSHA, desiredSHA256: desiredSHA,
                outputs: [.init(path: "Disk.img", sha256: reader.imageSHA256)], effects: effects)
            let proof = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
                "producer": "current-bundle-recompute", "version": version, "executableSHA256": executableSHA256,
                "input": produced.input.path, "inputSHA256": produced.inputSHA256,
                "payloadSHA256": VPhoneCreateDigest.sha256(produced.payload), "imageSHA256": reader.imageSHA256,
                "transactionID": journal.id], options: [.sortedKeys])
            return try transaction.commit(origin: .init(transactionID: journal.id, layer: layer, expected: expected,
                binding: expected.binding.replacingOrigin(layer, with: version), receipt: receipt, proof: proof,
                recheck: { _ in try verify() }))
        }

        /// This returns inspection data only. It cannot construct ProducedBinary
        /// or InstalledOrigin. C2 must capture the real guest producer and bridge
        /// the CFW journal's disk lifecycle before guest origins can advance.
        func inspectGuestEffects(transaction: FirmwareTransaction, frozenContext: Data,
                                 readback: FirmwareInstalledReadback.Operations? = nil) throws -> Data {
            try recheck()
            guard let context = try JSONSerialization.jsonObject(with: frozenContext) as? [String: Any],
                  context["verifierPath"] as? String == executable.path,
                  context["verifierSHA256"] as? String == executableSHA256,
                  context["vmDirectory"] as? String == transaction.vmDirectory.path,
                  case .ready(let desired) = try FirmwareDesiredPlanStore.read(in: transaction.vmDirectory),
                  desired.generationID == transaction.journalSnapshot.options["generationID"] else {
                throw FirmwareGeneration.fail("Guest inspection context differs from the live source")
            }
            let resources = VPhoneResources.resolve(executablePath: executable.path)
            let python = try resources.pythonExecutable()
            let script = resources.scriptsDir.appendingPathComponent("verify_installed_guest_effects.py")
            let evidence = transaction.root.appendingPathComponent("guest-changes.jsonl")
            let blobs = transaction.root.appendingPathComponent("effect-blobs")
            _ = try FirmwareGeneration.fileSHA256(evidence)
            try FirmwareGeneration.ensureDirectory(blobs, create: false)
            let reader = try FirmwareInstalledReadback(transaction: transaction)
            let body: (FirmwareInstalledReadback.Volumes) throws -> Data = { volumes in
                try self.recheck()
                let result = try volumes.withPaths { paths in
                    var roots = paths.mapValues(\.path)
                    if let system = paths["system"] { roots["dsc"] = system.appendingPathComponent("System/Cryptexes/OS/System/Library/Caches/com.apple.dyld").path }
                    let rootsJSON = try JSONSerialization.data(withJSONObject: roots, options: [.sortedKeys])
                    return try transaction.runTool("/usr/bin/env", ["-i", "PATH=/usr/bin:/bin:/usr/sbin:/sbin",
                        "PYTHONDONTWRITEBYTECODE=1", "VPHONE_FROZEN_PLAN=" + transaction.vmDirectory.appendingPathComponent(FirmwareDesiredPlanStore.filename).path,
                        "VPHONE_FROZEN_PLAN_SHA256=" + (try desired.sha256), "VPHONE_FROZEN_CONTEXT=" + String(decoding: frozenContext, as: UTF8.self),
                        python.path, script.path, evidence.path, blobs.path, String(decoding: rootsJSON, as: UTF8.self), resources.base.path])
                }
                try self.recheck()
                return result
            }
            if let readback { return try reader.withReadOnlyVolumes(operations: readback, body: body) }
            return try reader.withReadOnlyVolumes(body: body)
        }

        func recheck(file: String = #fileID, line: Int = #line, function: String = #function) throws {
            try KernelIOTrace.measure("installedOrigin.recheck", file: file, line: line, function: function) { _ in
                guard active else { throw FirmwareGeneration.fail("Installed origin source callback expired") }
                try verify()
                guard try FirmwareGeneration.fileSHA256(executable) == executableSHA256 else {
                    throw FirmwareGeneration.fail("Effective executable changed during installed origin qualification")
                }
            }
        }
    }
}
