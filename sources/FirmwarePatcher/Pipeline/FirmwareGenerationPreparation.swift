import Foundation
import VPhoneCore

/// Prepare trusted originals for an existing VM without publishing boot files.
public enum FirmwareGenerationPreparation {
    public static func prepare(in directory: URL, iPhone: URL, cloudOS: URL, bootROMSource: URL,
                               variant: FirmwarePipeline.Variant, enableFrida: Bool = false,
                               forceExcGuard: Bool = false) throws -> FirmwareDesiredPlanStore.Record {
        let directory = directory.standardizedFileURL
        guard directory == directory.resolvingSymlinksInPath(), variant != .less else {
            throw FirmwareGeneration.fail("Generation preparation requires a direct classic VM directory")
        }
        let rom = bootROMSource.standardizedFileURL.resolvingSymlinksInPath()
        guard !rom.path.hasPrefix(directory.path + "/") else {
            throw FirmwareGeneration.fail("VM files cannot serve as the independent boot ROM source")
        }
        return try VPhoneBundleGuard.withBundleLock(directory: directory, operation: VPhoneVMOperation.fwPrepare) { _ in
            guard case .missing = try FirmwareDesiredPlanStore.read(in: directory) else {
                throw FirmwareGeneration.fail("Generation preparation requires a missing desired plan; existing plans are never replaced")
            }
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(".firmware-transaction").path) else {
                throw FirmwareGeneration.fail("Pending firmware transaction; recover before generation preparation")
            }
            try FirmwareKernelUpdate.requireReleasedDisk(in: directory,
                observation: FirmwareTransaction.run("/usr/bin/hdiutil", ["info", "-plist"]))
            let identity = try VPhoneFirmwareIdentity.read(in: directory)
            let scratch = directory.appendingPathComponent(".firmware-generation-prepare-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: scratch) }
            try FirmwareGeneration.copy(rom, to: scratch.appendingPathComponent("AVPBooter.vresearch1.bin"))
            let source = try FirmwarePreparation.prepareWithSource(iPhone: iPhone, cloudOS: cloudOS,
                bundle: scratch, bootROMSource: rom).source
            let plan = try FirmwarePipeline(vmDirectory: scratch, variant: variant, verbose: false,
                forceExcGuard: forceExcGuard, enableFrida: enableFrida).resolvedPlan()
            let prepared = try FirmwareGeneration.prepareFreshSource(in: directory, sourceDirectory: scratch, source: source)
            defer { try? FirmwareGeneration.discard(prepared) }
            guard try VPhoneFirmwareIdentity.read(in: directory) == identity,
                  case .missing = try FirmwareDesiredPlanStore.read(in: directory) else {
                throw FirmwareGeneration.fail("VM identity or desired plan changed during preparation")
            }
            let generation = try FirmwareGeneration.publish(prepared, planSHA256: FirmwareGeneration.planDigest(plan))
            let desired = try FirmwareDesiredPlanStore.prepare(in: directory, plan: plan, generation: generation)
            guard desired.expectedSHA256 == nil, desired.expectedLegacySHA256 == nil else {
                throw FirmwareGeneration.fail("Desired plan appeared during preparation")
            }
            // A failure retains the generation and any publication barrier. The
            // existing desired-plan readback command reconciles uncertain writes.
            return try FirmwareDesiredPlanStore.publish(desired, expectedSHA256: nil)
        }
    }
}
