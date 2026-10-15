import Foundation
import Testing
@testable import FirmwarePatcher

@Suite struct FrozenPipelinePlanTests {
    @Test func transactionJournalContainsTheResolvedPlan() throws {
        let fixture = try PatchExperimentRecordTests.Fixture()
        #expect(throws: (any Error).self) { try fixture.run(allowOutput: true) }
        let report = try #require(fixture.record().patch.report)
        let archived = fixture.vm.appendingPathComponent(".firmware-transaction")
        let bytes = try Data(contentsOf: archived.appendingPathComponent("journal.json"))
        let journal = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let plan = try #require(journal["plan"] as? [String: Any])
        #expect(plan["variant"] as? String == report.variant)
        let gates = try #require(plan["gates"] as? [String: Any])
        #expect(gates["variant"] as? String == report.gates.variant)
        #expect(plan["upstreamTag"] as? String == PatchDeclarationCatalog.upstreamTag)
        #expect(Set(plan["enabledSteps"] as? [String] ?? []) ==
            (try VariantPlanResolver.resolve(variant: .regular, gates: report.gates)).enabledSteps)
        #expect(journal["entries"] != nil)
        let inputs = try #require(journal["versionInputs"] as? [String: Any])
        #expect((inputs["manifests"] as? [[String: Any]])?.count == 2)
    }

    @Test func unknownRequiredVersionIsRejectedBeforeCreatingATransaction() throws {
        let fixture = try PatchExperimentRecordTests.Fixture()
        try FileManager.default.removeItem(at: fixture.restore.appendingPathComponent("iPhone-BuildManifest.plist"))
        do {
            _ = try fixture.run(variant: .jb, allowOutput: true)
            Issue.record("Unknown required version was allowed to create and commit firmware")
        } catch {
            #expect(String(describing: error).contains("base version is unknown"))
        }
        #expect(!FirmwareTransaction.exists(fixture.vm.appendingPathComponent(".firmware-transaction")))
        #expect(!FirmwareTransaction.exists(fixture.vm.appendingPathComponent(".firmware-history")))
    }
    @Test func unknownCloudOSWithFridaIsRejectedBeforeCreatingATransaction() throws {
        let fixture = try PatchExperimentRecordTests.Fixture()
        try FileManager.default.removeItem(at: fixture.restore.appendingPathComponent("BuildManifest.plist"))
        let pipeline = FirmwarePipeline(vmDirectory: fixture.vm, variant: .jb, verbose: false,
            enableFrida: true, loader: PatchExperimentRecordTests.PassThroughLoader())
        do {
            _ = try pipeline.patchAllStructured(ablate: PatchExperimentRecordTests.allComponents)
            Issue.record("Unknown cloudOS was allowed to create and commit an opted-in Frida plan")
        } catch {
            #expect(String(describing: error).contains("cloudOS version is unknown"))
        }
        #expect(!FirmwareTransaction.exists(fixture.vm.appendingPathComponent(".firmware-transaction")))
        #expect(!FirmwareTransaction.exists(fixture.vm.appendingPathComponent(".firmware-history")))
    }

    @Test(arguments: [FirmwarePipeline.Variant.dev, .regular])
    func knownExcGuardActivationDoesNotResolveUnknownBootArgumentParameters(_ variant: FirmwarePipeline.Variant) throws {
        let fixture = try PatchExperimentRecordTests.Fixture()
        try FileManager.default.removeItem(at: fixture.restore.appendingPathComponent("iPhone-BuildManifest.plist"))
        do {
            _ = try fixture.run(variant: variant, forceExcGuard: variant == .regular, allowOutput: true)
            Issue.record("Unknown base was allowed to commit unresolved boot argument parameters")
        } catch {
            #expect(String(describing: error).contains("base version is unknown"))
        }
        #expect(!FirmwareTransaction.exists(fixture.vm.appendingPathComponent(".firmware-transaction")))
        #expect(!FirmwareTransaction.exists(fixture.vm.appendingPathComponent(".firmware-history")))
    }

}
