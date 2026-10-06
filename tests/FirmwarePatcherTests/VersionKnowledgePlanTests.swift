import Testing
@testable import FirmwarePatcher

@Suite struct VersionKnowledgePlanTests {
    @Test(arguments: [false, true])
    func unknownBaseCannotDisableAnIndeterminateRequiredGuard(_ block: Bool) {
        #expect(throws: PatchDeclarationCatalog.CatalogError.versionIndeterminate(
            id: "kernel-boot-thread_guard_violation", rule: .excGuardActive)) {
            _ = try VariantPlanResolver.resolve(variant: .regular,
                gates: VariantPlanTests.snapshots(.regular)[0], baseVersionKnown: false,
                block: block ? ["kernel-boot-thread_guard_violation"] : [])
        }
    }

    @Test func devGuardDoesNotNeedTheBaseToDecideItsActivation() throws {
        let plan = try VariantPlanResolver.resolve(variant: .dev,
            gates: VariantPlanTests.snapshots(.dev)[0], baseVersionKnown: false)
        #expect(plan.selected.contains { $0.id == "kernel-boot-thread_guard_violation" })
    }
    @Test func optedInFridaCannotTreatUnknownCloudOSAsBelowTheFloor() {
        #expect(throws: PatchDeclarationCatalog.CatalogError.versionIndeterminate(
            id: "kernel-exp-frida_thread_set_state_entitlement_flag", rule: .cloudOSFridaCapable)) {
            _ = try VariantPlanResolver.resolve(variant: .jb,
                gates: VariantPlanTests.snapshots(.jb)[3], cloudOSVersionKnown: false)
        }
    }

    @Test func unknownCloudOSDoesNotBlockAPlanWithoutFrida() throws {
        let plan = try VariantPlanResolver.resolve(variant: .jb,
            gates: VariantPlanTests.snapshots(.jb)[0], cloudOSVersionKnown: false)
        #expect(plan.excludedByOptIn.contains { $0.id == "kernel-exp-frida_thread_set_state_entitlement_flag" })
    }

}
