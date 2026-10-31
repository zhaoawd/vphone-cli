// VariantPlanTests.swift — T10: the resolved plan matches the pipeline's live steps.
//
// The expected enabled-step set is derived from the pipeline's own
// `buildComponentList()` / `buildSteps()` (not a hand-kept list), then compared with the
// resolver's plan. This keeps the plan honest against the code paths that actually run.

import Foundation
import Testing
@testable import FirmwarePatcher

@Suite struct VariantPlanTests {
    static let allVariants: [FirmwarePipeline.Variant] = [.regular, .dev, .jb, .exp, .less]

    /// Gate snapshots to exercise conditional classification (version + opt-in + exc-guard).
    static func snapshots(_ variant: FirmwarePipeline.Variant) -> [PatchGateSnapshot] {
        func gate(base18: Bool = false, base27: Bool = false, frida: Bool = false,
                  cloudCapable: Bool = true, forceExc: Bool = false) -> PatchGateSnapshot {
            PatchGateSnapshot(
                variant: variant.rawValue, iosBaseIs18: base18, iosBaseIs27: base27,
                cloudOSIsFridaCapable: cloudCapable, forceExcGuard: forceExc, enableFrida: frida,
                excGuardActive: variant == .dev || base18 || forceExc,
                applyIOS27: base27, applyFrida: frida && cloudCapable)
        }
        return [
            gate(),                                  // 26 base, no opt-in
            gate(base18: true),                      // iOS 18 base (exc-guard on)
            gate(base27: true),                      // iOS 27 base
            gate(frida: true),                       // frida opt-in, cloud capable
            gate(base27: true, frida: true, forceExc: true),
        ]
    }

    /// The steps the pipeline would run for a variant + gates: every buildSteps step whose
    /// requirement is required/optional, or a conditional whose rule holds. Mirrors
    /// `StructuredExecution`'s own run predicate.
    static func executedSteps(_ variant: FirmwarePipeline.Variant, _ gates: PatchGateSnapshot) -> Set<String> {
        let pipeline = FirmwarePipeline(
            vmDirectory: URL(fileURLWithPath: "/nonexistent/plan-test"), variant: variant, verbose: false)
        var out = Set<String>()
        for component in pipeline.buildComponentList() {
            if component.name == "Filesystem" {
                if !component.patcherFactories.isEmpty { out.insert(CryptexFilesystemPatcher.stepID.description) }
                continue
            }
            if component.name == "Manifest" {
                if !component.patcherFactories.isEmpty { out.insert(ManifestHashPatcher.stepID.description) }
                continue
            }
            for makePatcher in component.patcherFactories {
                let patcher = makePatcher(Data(), false)
                guard let structured = patcher as? any StructuredPatcher else { continue }
                for step in structured.buildSteps() {
                    switch step.requirement {
                    case .required, .optional:
                        out.insert(step.id.description)
                    case let .conditional(rule):
                        if rule.evaluate(gates) { out.insert(step.id.description) }
                    }
                }
            }
        }
        return out
    }

    @Test func catalogStructureValidates() throws {
        try PatchDeclarationCatalog.validateStructure()
    }

    @Test func everySwiftStepIsBoundExactlyOnceOrByAlternatives() {
        // Only patchApfsMount (4) and patchSandbox (5) are bound by more than one declaration.
        var count: [String: Int] = [:]
        for (step, declarations) in PatchDeclarationCatalog.declarationsByStep {
            count[step] = declarations.count
        }
        let multi = count.filter { $0.value > 1 }.keys.sorted()
        #expect(multi == [
            "kernelcache.KernelPatcher.patchApfsMount",
            "kernelcache.KernelPatcher.patchSandbox",
        ])
    }

    @Test func resolvedPlanMatchesLiveStepsForEveryVariantAndGate() throws {
        for variant in Self.allVariants {
            for gates in Self.snapshots(variant) {
                let plan = try VariantPlanResolver.resolve(variant: variant, gates: gates)
                let expected = Self.executedSteps(variant, gates)
                #expect(plan.enabledStepIDs == expected,
                        "variant \(variant.rawValue) gates \(gates.summary)")
            }
        }
    }

    @Test func defaultVariantIsRegular() {
        let pipeline = FirmwarePipeline(vmDirectory: URL(fileURLWithPath: "/nonexistent/default"))
        #expect(pipeline.variant == .regular)
    }

    @Test func expOnlyStepsAreAbsentFromOtherVariants() throws {
        let gates = Self.snapshots(.exp)[0]
        let exp = try VariantPlanResolver.resolve(variant: .exp, gates: gates)
        let jb = try VariantPlanResolver.resolve(
            variant: .jb, gates: Self.snapshots(.jb)[0])
        // hv_vmm kernel rename and the DeviceTree identity rewrites are exp-only.
        let hvVmm = "kernelcache.KernelEXPPatcher.patchHvVmmRename"
        let identity = "devicetree.DeviceTreePatcher.target_sub_type"
        #expect(exp.enabledStepIDs.contains(hvVmm))
        #expect(exp.enabledStepIDs.contains(identity))
        #expect(!jb.enabledStepIDs.contains(hvVmm))
        #expect(!jb.enabledStepIDs.contains(identity))
    }

    @Test func notImplementedIsAlwaysListedAndNeverSelectable() throws {
        let plan = try VariantPlanResolver.resolve(variant: .exp, gates: Self.snapshots(.exp)[0])
        #expect(plan.notImplemented.contains { $0.id == "dyld-exp-mis_trust_auth" })
        #expect(!plan.enabledStepIDs.contains("dyld-exp-mis_trust_auth"))
    }

    @Test func fridaStepsNeedOptInOnJBAndExp() throws {
        let fridaStep = "kernelcache.KernelJBPatcher.patchThreadSetStateEntitlementFlag"
        // Without --frida: excluded by opt-in.
        let off = try VariantPlanResolver.resolve(
            variant: .jb,
            gates: PatchGateSnapshot(variant: "jb", iosBaseIs18: false, iosBaseIs27: false,
                cloudOSIsFridaCapable: true, forceExcGuard: false, enableFrida: false,
                excGuardActive: false, applyIOS27: false, applyFrida: false))
        #expect(!off.enabledStepIDs.contains(fridaStep))
        #expect(off.excludedByOptIn.contains { $0.swiftSteps.contains(fridaStep) })
        // With --frida on a capable cloudOS: enabled.
        let on = try VariantPlanResolver.resolve(
            variant: .jb,
            gates: PatchGateSnapshot(variant: "jb", iosBaseIs18: false, iosBaseIs27: false,
                cloudOSIsFridaCapable: true, forceExcGuard: false, enableFrida: true,
                excGuardActive: false, applyIOS27: false, applyFrida: true))
        #expect(on.enabledStepIDs.contains(fridaStep))
    }

    @Test func lessIsResolvedIndependently() throws {
        let plan = try VariantPlanResolver.resolve(variant: .less, gates: Self.snapshots(.less)[0])
        // less runs only iBEC/LLB/DeviceTree-base + filesystem + manifest, no kernel/AVPBooter.
        #expect(plan.enabledStepIDs.contains("filesystem.CryptexFilesystemPatcher.patchCryptexFilesystem"))
        #expect(plan.enabledStepIDs.contains("manifest.ManifestHashPatcher.patchManifestHash"))
        #expect(!plan.enabledStepIDs.contains("avpbooter.AVPBooterPatcher.patchDGSTBypass"))
        #expect(!plan.enabledStepIDs.contains(where: { $0.hasPrefix("kernelcache.") }))
    }
}
