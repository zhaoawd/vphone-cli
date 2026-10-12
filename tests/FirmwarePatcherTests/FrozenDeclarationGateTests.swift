import Foundation
import Testing
@testable import FirmwarePatcher

@Suite struct FrozenDeclarationGateTests {
    @Test func rejectsAWritingStepBlockedInTheFrozenPlan() throws {
        let report = DeclarationGateTests.report(step: "ibss.IBootPatcher.patchSerialLabels",
            outcome: .applied, variant: "regular")
        let plan = try VariantPlanResolver.resolve(variant: .regular, gates: report.gates,
            block: ["ibss-cfw-serial_label"])
        #expect(!PatchDeclarationGate.violations(in: report, plan: plan).isEmpty)
        #expect(throws: (any Error).self) { try PatchDeclarationGate.enforce(report: report, plan: plan) }
    }

    enum Mismatch: CaseIterable { case variant, reportGates, resultGates }

    @Test(arguments: Mismatch.allCases)
    func rejectsReportIdentityChanges(_ mismatch: Mismatch) throws {
        let original = DeclarationGateTests.report(step: "avpbooter.AVPBooterPatcher.patchDGSTBypass",
            outcome: .applied, variant: "regular")
        let plan = try VariantPlanResolver.resolve(variant: .regular, gates: original.gates)
        let otherGates = DeclarationGateTests.gates("regular", base27: true)
        let oldResult = original.components[0].results[0]
        let result = PatchResult(id: oldResult.id, requirement: oldResult.requirement, rule: oldResult.rule,
            outcome: oldResult.outcome, reason: oldResult.reason, recordIndices: oldResult.recordIndices,
            gates: mismatch == .resultGates ? otherGates : oldResult.gates)
        let component = ComponentReport(component: original.components[0].component, coverage: .structured,
            results: [result], records: original.components[0].records)
        let report = PatchRunReport(variant: mismatch == .variant ? "dev" : original.variant,
            gates: mismatch == .reportGates ? otherGates : original.gates,
            components: [component], ablation: [])
        #expect(!PatchDeclarationGate.violations(in: report, plan: plan).isEmpty)
        #expect(throws: (any Error).self) { try PatchDeclarationGate.enforce(report: report, plan: plan) }
    }

    @Test func acceptsMatchingResolvedPlan() throws {
        let plan = try VariantPlanResolver.resolve(variant: .regular, gates: DeclarationGateTests.gates())
        let report = RequiredDeclarationEvidenceTests.complete(plan)
        try PatchDeclarationGate.enforce(report: report, plan: plan)
        #expect(PatchDeclarationGate.violations(in: report, plan: plan).isEmpty)
    }
}
