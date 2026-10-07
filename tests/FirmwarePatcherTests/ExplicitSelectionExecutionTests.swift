import Foundation
import Testing
@testable import FirmwarePatcher

@Suite struct ExplicitSelectionExecutionTests {
    @Test func explicitSelectionCannotCrossVariantBoundary() {
        #expect(throws: (any Error).self) {
            _ = try VariantPlanResolver.resolve(variant: .regular,
                gates: DeclarationGateTests.gates(), select: ["kernel-exp-hv_vmm"])
        }
    }

    @Test func explicitSelectionCannotEnableFridaWithoutOptIn() {
        #expect(throws: (any Error).self) {
            _ = try VariantPlanResolver.resolve(variant: .jb,
                gates: DeclarationGateTests.gates("jb"),
                select: ["kernel-exp-frida_thread_set_state_entitlement_flag"])
        }
    }

    @Test func explicitSelectionCannotOverrideVersionCondition() {
        let catalog = PatchDeclarationCatalog.all + [
            DeclarationGateTests.decl("version-only", steps: ["ibss.IBootPatcher.patchSerialLabels"],
                rule: .iosBaseIs27),
        ]
        #expect(throws: (any Error).self) {
            _ = try VariantPlanResolver.resolve(variant: .regular,
                gates: DeclarationGateTests.gates(), select: ["version-only"], catalog: catalog)
        }
    }

    @Test func explicitSelectionRequiresALiveExecutableStep() {
        let catalog = PatchDeclarationCatalog.all + [
            DeclarationGateTests.decl("unavailable-step", steps: ["absent.Patcher.run"]),
        ]
        #expect(throws: (any Error).self) {
            _ = try VariantPlanResolver.resolve(variant: .regular,
                gates: DeclarationGateTests.gates(), select: ["unavailable-step"], catalog: catalog)
        }
    }

    @Test func guestSelectionIsRefusedUntilGuestExecutionIsGated() {
        #expect(throws: (any Error).self) {
            _ = try VariantPlanResolver.resolve(variant: .regular,
                gates: DeclarationGateTests.gates(), select: ["dyld-boot-iomfb_force_kern"])
        }
    }

    @Test func applicableGuestBlockIsRefusedUntilGuestExecutionIsGated() {
        #expect(throws: (any Error).self) {
            _ = try VariantPlanResolver.resolve(variant: .regular,
                gates: DeclarationGateTests.gates(), block: ["dyld-boot-iomfb_force_kern"])
        }
    }

    @Test func guestBlockOutsideVariantDoesNotChangeSwiftPlan() throws {
        let plan = try VariantPlanResolver.resolve(variant: .dev,
            gates: DeclarationGateTests.gates("dev"), block: ["dyld-boot-iomfb_force_kern"])
        #expect(!plan.guestUncovered.contains { $0.id == "dyld-boot-iomfb_force_kern" })
        #expect(plan.enabledSteps.contains("ibss.IBootPatcher.patchSerialLabels"))
    }

    @Test func supportedExplicitSelectionRetainsExecutableStep() throws {
        let plan = try VariantPlanResolver.resolve(variant: .regular,
            gates: DeclarationGateTests.gates(), select: ["ibss-cfw-serial_label"])
        #expect(plan.selected.contains { $0.id == "ibss-cfw-serial_label" })
        #expect(plan.enabledSteps.contains("ibss.IBootPatcher.patchSerialLabels"))
    }
}
