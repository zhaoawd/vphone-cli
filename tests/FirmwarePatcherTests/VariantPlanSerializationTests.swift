import Foundation
import Testing
@testable import FirmwarePatcher

@Suite struct VariantPlanSerializationTests {
    private func plan(_ variant: FirmwarePipeline.Variant = .regular) throws -> VariantPlanResolver.VariantPlan {
        try VariantPlanResolver.resolve(variant: variant, gates: VariantPlanTests.snapshots(variant)[0])
    }

    @Test func historicalNilProfilePreservesCanonicalEncodingAndDoesNotPromote() throws {
        let legacy = try plan()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(legacy)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let gates = try #require(object["gates"] as? [String: Any])
        #expect(gates["guestEnvironmentV2"] == nil)
        let restored = try JSONDecoder().decode(VariantPlanResolver.VariantPlan.self, from: bytes)
        #expect(restored.gates.guestEnvironmentV2 == nil)
        #expect(try encoder.encode(restored) == bytes)
        #expect(try FirmwareGeneration.planDigest(restored) == FirmwareGeneration.planDigest(legacy))
        #expect(throws: (any Error).self) { try VariantPlanResolver.resolve(variant: .regular, gates: restored.gates, guestEnvironmentV2: true) }
        let journal = FirmwareTransaction.Journal(id: "historical", vmPath: "/historical", options: [:],
            plan: legacy, versionInputs: nil, planBinding: nil, entries: [])
        let journalBytes = try encoder.encode(journal)
        let readback = try JSONDecoder().decode(FirmwareTransaction.Journal.self, from: journalBytes)
        #expect(readback.plan?.gates.guestEnvironmentV2 == nil)
        #expect(try encoder.encode(readback) == journalBytes)
    }

    @Test func encodedStepsHaveStableOrderForEveryVariant() throws {
        for variant in VariantPlanTests.allVariants {
            let plan = try plan(variant)
            let data = try JSONEncoder().encode(plan)
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(object["enabledSteps"] as? [String] == plan.enabledStepIDs.sorted())
            #expect(try JSONDecoder().decode(VariantPlanResolver.VariantPlan.self, from: data) == plan)
        }
    }

    @Test func duplicateStepsCannotBeCollapsedDuringDecode() throws {
        let plan = try plan()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        let step = try #require(plan.enabledStepIDs.sorted().first)
        object["enabledSteps"] = [step, step]
        let data = try JSONSerialization.data(withJSONObject: object)
        do {
            _ = try JSONDecoder().decode(VariantPlanResolver.VariantPlan.self, from: data)
            Issue.record("Repeated plan steps must be rejected before conversion to Set")
        } catch DecodingError.dataCorrupted(let context) {
            #expect(context.codingPath.last?.stringValue == "enabledSteps")
        }
    }

    @Test func legacyUnsortedUniqueStepsRetainTheSamePlan() throws {
        let plan = try plan()
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        object["enabledSteps"] = Array(plan.enabledStepIDs.sorted().reversed())
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(VariantPlanResolver.VariantPlan.self, from: data)
        #expect(decoded == plan)
        let canonical = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(canonical["enabledSteps"] as? [String] == plan.enabledStepIDs.sorted())
    }

    @Test func missingStepFieldDoesNotCreateDefaults() throws {
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan())) as? [String: Any])
        object.removeValue(forKey: "enabledSteps")
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(VariantPlanResolver.VariantPlan.self, from: data)
        }
    }
}
