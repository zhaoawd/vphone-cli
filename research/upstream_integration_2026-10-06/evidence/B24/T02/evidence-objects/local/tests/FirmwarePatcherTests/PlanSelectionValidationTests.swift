import Foundation
import Testing
@testable import FirmwarePatcher

@Suite struct PlanSelectionValidationTests {
    static let boot = "avpbooter-boot-dgst_bypass"
    static let optional = "ibss-cfw-serial_label"
    static let sharedStep = "avpbooter.AVPBooterPatcher.patchDGSTBypass"

    @Test func refusesContradictoryExplicitChoices() {
        #expect(throws: PatchDeclarationCatalog.CatalogError.contradictorySelection(id: Self.optional)) {
            _ = try VariantPlanResolver.resolve(variant: .regular, gates: DeclarationGateTests.gates(),
                select: [Self.optional], block: [Self.optional])
        }
    }

    @Test func refusesBlockingAnApplicableRequiredDeclaration() {
        #expect(throws: PatchDeclarationCatalog.CatalogError.requiredMissing(variant: "regular", id: Self.boot)) {
            _ = try VariantPlanResolver.resolve(variant: .regular, gates: DeclarationGateTests.gates(),
                block: [Self.boot])
        }
    }

    @Test func refusesVariantAndGateMismatch() {
        #expect(throws: PatchDeclarationCatalog.CatalogError.variantMismatch(variant: "regular", gates: "exp")) {
            _ = try VariantPlanResolver.resolve(variant: .regular, gates: DeclarationGateTests.gates("exp"))
        }
    }

    @Test func refusesBlockingOnlyPartOfAnIndivisibleStep() {
        let catalog = PatchDeclarationCatalog.all + [
            DeclarationGateTests.decl("shared-optional", steps: [Self.sharedStep]),
        ]
        #expect(throws: PatchDeclarationCatalog.CatalogError.partialStepSelection(id: "shared-optional", step: Self.sharedStep, enabled: [Self.boot])) {
            _ = try VariantPlanResolver.resolve(variant: .regular, gates: DeclarationGateTests.gates(),
                block: ["shared-optional"], catalog: catalog)
        }
    }

    @Test func canBlockAnIndependentOptionalStep() throws {
        let plan = try VariantPlanResolver.resolve(variant: .regular, gates: DeclarationGateTests.gates(),
            block: [Self.optional])
        #expect(!plan.selected.contains { $0.id == Self.optional })
        #expect(!plan.enabledSteps.contains("ibss.IBootPatcher.patchSerialLabels"))
        #expect(plan.excludedByOptIn.contains { $0.id == Self.optional && $0.reason == "blocked by request" })
        #expect(plan.selected.contains { $0.id == Self.boot })
    }

    @Test func canBlockARequiredDeclarationOutsideTheVariant() throws {
        // AVPBooter is absent from less. Blocking it cannot suppress a less boot step.
        let plan = try VariantPlanResolver.resolve(variant: .less, gates: DeclarationGateTests.gates("less"),
            block: [Self.boot])
        #expect(plan.excludedByVariant.contains { $0.id == Self.boot })
    }

    @Test func canBlockAllOptionalDeclarationsSharingOneStep() throws {
        let originals = PatchDeclarationCatalog.all.filter { $0.id != Self.optional }
        let serial = "ibss.IBootPatcher.patchSerialLabels"
        let catalog = originals + [
            DeclarationGateTests.decl("serial-a", steps: [serial]),
            DeclarationGateTests.decl("serial-b", steps: [serial]),
        ]
        let plan = try VariantPlanResolver.resolve(variant: .regular, gates: DeclarationGateTests.gates(),
            block: ["serial-a", "serial-b"], catalog: catalog)
        #expect(!plan.enabledSteps.contains(serial))
        #expect(plan.excludedByOptIn.filter { $0.id.hasPrefix("serial-") }.count == 2)
    }
    @Test func canBlockARequiredDeclarationWhoseVersionRuleIsFalse() throws {
        let catalog = PatchDeclarationCatalog.all + [
            DeclarationGateTests.decl("conditional-required", steps: [Self.sharedStep],
                required: true, rule: .iosBaseIs27),
        ]
        let plan = try VariantPlanResolver.resolve(variant: .regular, gates: DeclarationGateTests.gates(),
            block: ["conditional-required"], catalog: catalog)
        #expect(!plan.selected.contains { $0.id == "conditional-required" })
        #expect(plan.enabledSteps.contains(Self.sharedStep))
    }

}
