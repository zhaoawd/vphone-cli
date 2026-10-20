import Foundation
import Testing
@testable import FirmwarePatcher

@Suite struct BootxVersionGateTests {
    static let declarationID = "ibec-boot-bootx_precondition"

    static func gates(modernCloudOS: Bool, frida: Bool = false, variant: String = "regular") -> PatchGateSnapshot {
        PatchGateSnapshot(variant: variant, iosBaseIs18: false, iosBaseIs27: false,
            cloudOSIsFridaCapable: modernCloudOS, forceExcGuard: false, enableFrida: frida,
            excGuardActive: false, applyIOS27: false, applyFrida: frida && modernCloudOS)
    }

    @Test(arguments: [false, true])
    func pre26_4CloudOSExcludesBootxRegardlessOfFrida(_ frida: Bool) throws {
        let plan = try VariantPlanResolver.resolve(variant: .regular,
            gates: Self.gates(modernCloudOS: false, frida: frida))
        #expect(plan.excludedByVersion.contains { $0.id == Self.declarationID })
        #expect(!plan.selected.contains { $0.id == Self.declarationID })
        #expect(!plan.enabledSteps.contains("ibec.IBootPatcher.patchBootxPrecondition"))
    }

    @Test(arguments: [false, true])
    func modernCloudOSRequiresBootxRegardlessOfFrida(_ frida: Bool) throws {
        let gates = Self.gates(modernCloudOS: true, frida: frida)
        let plan = try VariantPlanResolver.resolve(variant: .regular, gates: gates)
        let declaration = try #require(plan.selected.first { $0.id == Self.declarationID })
        #expect(declaration.required)
        let step = try #require(IBootPatcher(data: Data(), mode: .ibec).buildSteps()
            .first { $0.id.method == "patchBootxPrecondition" })
        #expect(step.requirement.isEffectivelyRequired(for: gates))
        #expect(PatchOutcomeMapping.outcome(for: .noMatch, requirement: step.requirement,
            gates: gates).kind == .failed)
        #expect(PatchOutcomeMapping.outcome(for: .ambiguous(count: 2), requirement: step.requirement,
            gates: gates).kind == .failed)
        #expect(throws: (any Error).self) {
            try VariantPlanResolver.resolve(variant: .regular, gates: gates, block: [Self.declarationID])
        }
    }

    @Test(arguments: [false, true])
    func actualStructuredExecutionSkipsOldInputsAndFailsMissingModernAnchors(_ modern: Bool) throws {
        let patcher = IBootPatcher(data: Data(), mode: .ibec, verbose: false)
        let result = StructuredExecution.run(patcher: patcher, componentName: "ibec",
            gates: Self.gates(modernCloudOS: modern), ablate: [], fallback: Data())
        let bootx = try #require(result.report.results.first { $0.id.method == "patchBootxPrecondition" })
        #expect(bootx.outcome == (modern ? .failed : .notApplicable))
        #expect(bootx.isRequiredFailure == modern)
        #expect(bootx.recordIndices.isEmpty)
        #expect(result.data.isEmpty)
    }

    @Test(arguments: ["26.1", "26.3", "26.4", "26.4.1", "26.10", "27.0"])
    func sourceVersionBoundary(_ version: String) throws {
        let modern = FirmwarePipeline.productVersionAtLeast(version, 26, 4)
        let plan = try VariantPlanResolver.resolve(variant: .regular,
            gates: Self.gates(modernCloudOS: modern))
        #expect(plan.selected.contains { $0.id == Self.declarationID }
            == !["26.1", "26.3"].contains(version))
    }
}
