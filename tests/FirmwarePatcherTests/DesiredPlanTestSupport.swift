import Foundation
@testable import FirmwarePatcher

/// Synthetic firmware tests exercise transactions without real IPSWs. Only test code can
/// construct this module-internal Source; production callers must use FirmwarePreparation.
func saveSyntheticDesiredPlan(_ pipeline: FirmwarePipeline) throws {
    let directory = pipeline.vmDirectory.standardizedFileURL.resolvingSymlinksInPath()
    let plan = try pipeline.resolvedPlan()
    let inputs = try pipeline.transactionRoots()
    let provenance = FirmwareGeneration.Provenance(recognition: "fresh-local-ipsw-prepare-v1",
        inputManifestSHA256: [:], archiveSHA256: [:], builds: [:], device: "synthetic-test",
        gpuInputs: [], bootROMSHA256: String(repeating: "0", count: 64))
    let source = FirmwareGeneration.Source(provenance: provenance, originals: try inputs.map {
        FirmwareGeneration.Original(name: $0.lastPathComponent, sha256: try FirmwareGeneration.treeDigest($0))
    }.sorted { $0.name < $1.name }, directory: directory)
    let generation = try FirmwareGeneration.publish(FirmwareGeneration.prepare(in: directory, inputs: inputs, source: source),
        planSHA256: FirmwareGeneration.planDigest(plan))
    let desired = try FirmwareDesiredPlanStore.prepare(in: directory, plan: plan, generation: generation)
    _ = try FirmwareDesiredPlanStore.publish(desired, expectedSHA256: desired.expectedSHA256)
}
