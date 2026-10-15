import Foundation
import Testing
@testable import FirmwarePatcher

@Suite struct RequiredDeclarationEvidenceTests {
    static func complete(_ plan: VariantPlanResolver.VariantPlan, omitting: String? = nil) -> PatchRunReport {
        let components = plan.selected.filter { $0.required && $0.id != omitting }.map { entry in
            let step = entry.swiftSteps.first { plan.enabledSteps.contains($0) }!
            let rule = entry.recordRules!.first!
            let record = PatchRecord(patchID: rule.literal + (rule.hexadecimalOffsetSuffix ? "0" : ""),
                component: String(step.split(separator: ".")[0]), fileOffset: 0,
                originalBytes: Data([0]), patchedBytes: Data([1]), description: "required fixture")
            let parts = step.split(separator: ".", maxSplits: 2).map(String.init)
            let result = PatchResult(id: PatchID(component: parts[0], patcher: parts[1], method: parts[2]), requirement: .required, rule: nil,
                outcome: .applied, reason: nil, recordIndices: [0], gates: plan.gates)
            return ComponentReport(component: record.component, coverage: .structured, results: [result], records: [record])
        }
        return PatchRunReport(variant: plan.variant, gates: plan.gates, components: components, ablation: [])
    }
    @Test(arguments: ["regular", "dev", "jb", "exp", "less"])
    func completeRequiredEvidencePasses(_ variant: String) throws {
        let plan = try VariantPlanResolver.resolve(variant: FirmwarePipeline.Variant(rawValue: variant)!,
            gates: DeclarationGateTests.gates(variant))
        try PatchDeclarationGate.enforce(report: Self.complete(plan), plan: plan)
    }
    @Test func combinedStepCannotHideMissingRequiredDeclaration() throws {
        let plan = try VariantPlanResolver.resolve(variant: .regular, gates: DeclarationGateTests.gates())
        let report = Self.complete(plan, omitting: "kernel-boot-apfs_vfsop_mount")
        #expect(report.components.flatMap(\.results).contains { $0.id.method == "patchApfsMount" })
        let violations = PatchDeclarationGate.violations(in: report, plan: plan)
        #expect(violations.count == 1)
        #expect(violations.first?.step == "kernel-boot-apfs_vfsop_mount")
        #expect(throws: (any Error).self) { try PatchDeclarationGate.enforce(report: report, plan: plan) }
    }
    @Test func unknownRecordInEnabledStepIsRefused() throws {
        let plan = try VariantPlanResolver.resolve(variant: .regular, gates: DeclarationGateTests.gates())
        let unknown = DeclarationGateTests.report(step: "avpbooter.AVPBooterPatcher.patchDGSTBypass", outcome: .applied, variant: "regular")
        let report = PatchRunReport(variant: plan.variant, gates: plan.gates,
            components: Self.complete(plan).components + unknown.components, ablation: [])
        #expect(throws: (any Error).self) { try PatchDeclarationGate.enforce(report: report, plan: plan) }
    }
    @Test func alreadyAppliedNeedsVerifiedOutput() throws {
        let plan = try VariantPlanResolver.resolve(variant: .regular, gates: DeclarationGateTests.gates())
        let unknown = DeclarationGateTests.report(step: "avpbooter.AVPBooterPatcher.patchDGSTBypass", outcome: .alreadyApplied, variant: "regular")
        let report = PatchRunReport(variant: plan.variant, gates: plan.gates,
            components: Self.complete(plan).components + unknown.components, ablation: [])
        #expect(throws: (any Error).self) { try PatchDeclarationGate.enforce(report: report, plan: plan) }
    }
    @Test func missingEntireComponentIsRefused() throws {
        let plan = try VariantPlanResolver.resolve(variant: .regular, gates: DeclarationGateTests.gates())
        let report = Self.complete(plan, omitting: "avpbooter-boot-dgst_bypass")
        #expect(throws: (any Error).self) { try PatchDeclarationGate.enforce(report: report, plan: plan) }
    }
}

extension RequiredDeclarationEvidenceTests {
    private final class AlreadyAppliedPatcher: StructuredPatcher {
        let component = "avpbooter"
        let verbose = false
        var emittedRecords: [PatchRecord] = []
        var patchedData = Data([1])
        func buildSteps() -> [PatchStep] {
            [PatchStep(id: PatchID(component: component, patcher: "AVPBooterPatcher", method: "patchDGSTBypass"), requirement: .required) {
                self.emittedRecords.append(PatchRecord(patchID: "avpbooter.dgst_bypass", component: self.component,
                    fileOffset: 0, originalBytes: Data([1]), patchedBytes: Data([1]), description: "already present"))
                return .idempotent
            }]
        }
        func commit(_ records: [PatchRecord]) {}
        func findAll() throws -> [PatchRecord] { emittedRecords }
        func apply() throws -> Int { 0 }
    }
    @Test(arguments: [true, false])
    func alreadyAppliedReadsCurrentPayload(_ containsOutput: Bool) throws {
        let plan = try VariantPlanResolver.resolve(variant: .regular, gates: DeclarationGateTests.gates())
        let execution = StructuredExecution.run(patcher: AlreadyAppliedPatcher(), componentName: "avpbooter",
            gates: plan.gates, ablate: [], fallback: Data([containsOutput ? 1 : 0]), enabledSteps: plan.enabledSteps)
        let report = PatchRunReport(variant: plan.variant, gates: plan.gates,
            components: Self.complete(plan, omitting: "avpbooter-boot-dgst_bypass").components + [execution.report], ablation: [])
        if containsOutput {
            try PatchDeclarationGate.enforce(report: report, plan: plan)
            #expect(execution.report.results[0].declarationEvidence?[0].verifiedPayloadSHA256 != nil)
        } else {
            #expect(throws: (any Error).self) { try PatchDeclarationGate.enforce(report: report, plan: plan) }
        }
    }
    @Test func missingOneRequiredRecordLeavesOriginalFirmwareUnchanged() throws {
        let fixture = try FirmwareTransactionTests.Fixture()
        let transaction = try fixture.begin()
        try fixture.patch(transaction)
        let plan = try VariantPlanResolver.resolve(variant: .regular, gates: DeclarationGateTests.gates())
        let report = Self.complete(plan, omitting: "kernel-boot-apfs_vfsop_mount")
        #expect(throws: (any Error).self) {
            try PatchDeclarationGate.enforce(report: report, plan: plan)
            _ = try transaction.commit()
        }
        try fixture.original()
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".firmware-history").path))
    }
    @Test func offsetSuffixMustEqualRecordOffset() {
        let rule = PatchDeclarationCatalog.byID["kernel-boot-handle_get_dev_by_role"]!.recordRules![0]
        for id in ["kernel.handle_get_dev_by_role.gate_fake", "kernel.handle_get_dev_by_role.gate_20"] {
            let record = PatchRecord(patchID: id, component: "kernelcache", fileOffset: 16,
                originalBytes: Data([0]), patchedBytes: Data([1]), description: "invalid suffix")
            #expect(!rule.matches(record))
        }
    }
}

extension RequiredDeclarationEvidenceTests {
    @Test func recordRulesAreEncodedInCatalogAndFrozenPlan() throws {
        let declaration = try #require(PatchDeclarationCatalog.byID["avpbooter-boot-dgst_bypass"])
        let catalogJSON = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(declaration)) as? [String: Any])
        #expect(catalogJSON["recordRules"] != nil)
        let plan = try VariantPlanResolver.resolve(variant: .regular, gates: DeclarationGateTests.gates())
        #expect(plan.selected.first { $0.id == declaration.id }?.recordRules == declaration.recordRules)
        var oldPlan = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        var selected = try #require(oldPlan["selected"] as? [[String: Any]])
        selected[0].removeValue(forKey: "recordRules")
        oldPlan["selected"] = selected
        let oldBytes = try JSONSerialization.data(withJSONObject: oldPlan)
        let legacy = try JSONDecoder().decode(VariantPlanResolver.VariantPlan.self, from: oldBytes)
        #expect(legacy.selected[0].recordRules == nil)
        #expect(throws: (any Error).self) { try PatchDeclarationGate.enforce(report: Self.complete(plan), plan: legacy) }
        let roundTrip = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        #expect((roundTrip["selected"] as? [[String: Any]])?[0]["recordRules"] == nil)
    }
}

extension RequiredDeclarationEvidenceTests {
    @Test func legacyJournalWithoutRulesRemainsRecoverable() throws {
        let fixture = try FirmwareTransactionTests.Fixture()
        let transaction = try fixture.begin()
        try fixture.patch(transaction)
        let plan = try VariantPlanResolver.resolve(variant: .regular, gates: DeclarationGateTests.gates())
        var oldPlan = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        for key in ["selected", "excludedByVersion", "excludedByOptIn", "excludedByVariant", "guestUncovered", "notImplemented"] {
            var entries = try #require(oldPlan[key] as? [[String: Any]])
            for index in entries.indices { entries[index].removeValue(forKey: "recordRules") }
            oldPlan[key] = entries
        }
        let journalURL = fixture.root.appendingPathComponent(".firmware-transaction/journal.json")
        var journal = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
        journal["plan"] = oldPlan
        try JSONSerialization.data(withJSONObject: journal).write(to: journalURL)
        let read = try FirmwareTransaction.readJournal(at: journalURL)
        #expect(read.plan?.selected.allSatisfy { $0.recordRules == nil } == true)
        #expect(try fixture.recover() != nil)
        try fixture.original()
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(".firmware-transaction").path))
    }
}

extension RequiredDeclarationEvidenceTests {
    @Test func legacyBoundJournalPreservesDigestAndRecovery() throws {
        let fixture = try PatchExperimentRecordTests.Fixture()
        let original = try Data(contentsOf: fixture.kernel)
        #expect(throws: (any Error).self) { try fixture.run(allowOutput: true) }
        let url = fixture.vm.appendingPathComponent(".firmware-transaction/journal.json")
        func withoutRules(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                return dictionary.filter { $0.key != "recordRules" }.mapValues(withoutRules)
            }
            if let array = value as? [Any] { return array.map(withoutRules) }
            return value
        }
        var object = try #require(withoutRules(JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any])
        var binding = try #require(object["planBinding"] as? [String: Any])
        let payloadObject = try #require(binding["payload"] as? [String: Any])
        let payload = try JSONDecoder().decode(FirmwarePlanBinding.Payload.self,
            from: JSONSerialization.data(withJSONObject: payloadObject))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        binding["planSHA256"] = DeclarationExecutionEvidence.digest(try encoder.encode(payload.plan))
        binding["contextSHA256"] = DeclarationExecutionEvidence.digest(try encoder.encode(payload))
        object["planBinding"] = binding
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        let journal = try FirmwareTransaction.readJournal(at: url)
        try journal.planBinding?.validate(journal: journal, directory: fixture.vm, currentCatalog: false)
        #expect(journal.plan?.selected.allSatisfy { $0.recordRules == nil } == true)
        #expect(try FirmwareTransaction.recover(vmDirectory: fixture.vm, mounts: { _, _ in }) != nil)
        #expect(try Data(contentsOf: fixture.kernel) == original)
    }
}
