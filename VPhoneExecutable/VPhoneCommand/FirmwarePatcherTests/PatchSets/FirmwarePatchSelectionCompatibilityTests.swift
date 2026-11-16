import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

@Suite("Duo patch selection compatibility")
struct FirmwarePatchSelectionCompatibilityTests {
    let aggregate = FirmwareGuestSystemPatchSet.arm64eX1AccessibilityBundles
    var children: Set<String> {
        Set(FirmwareGuestSystemPatchSet.arm64eX1AccessibilityImages.map(\.identifier))
            .union([FirmwareGuestSystemPatchSet.arm64eX1HomePopAccessibility])
    }

    func resolve(_ preset: VPhonePatchPreset = FirmwarePatchSetCatalog.standardPreset,
                 blocked: Set<String> = [], allowed: Set<String> = []) throws -> VPhonePatchPlan {
        try FirmwarePatchSetCatalog.resolve(
            preset: preset, patchSets: FirmwarePatchSetCatalog.bundled,
            iOSBase: VPhoneVersion("27.1"), cloudOS: VPhoneVersion("26.4"),
            blocked: blocked, allowed: allowed,
        )
    }

    @Test func `legacy aggregate block covers every replacement but not debug libraries`() throws {
        var preset = FirmwarePatchSetCatalog.standardPreset
        for override in [false, true] {
            if !override { preset.selection = preset.selection.blocking([aggregate]) }
            let plan = try resolve(preset, blocked: override ? [aggregate] : [])
            #expect(plan.enabled.isDisjoint(with: children))
            #expect(!plan.isEnabled(aggregate))
            #expect(FirmwareGuestSystemPatchSet.arm64eX1DebugImages.allSatisfy { plan.isEnabled($0.identifier) })
            preset = FirmwarePatchSetCatalog.standardPreset
        }
    }

    @Test func `explicit individual choices take precedence over a legacy group`() throws {
        let child = try #require(children.sorted().first)
        let allowed = try resolve(blocked: [aggregate], allowed: [child])
        #expect(allowed.enabled.intersection(children) == [child])
        #expect(!allowed.isEnabled(aggregate))
        var preset = FirmwarePatchSetCatalog.standardPreset
        preset.selection = .allow([aggregate])
        let blocked = try resolve(preset, blocked: [child])
        #expect(blocked.enabled.intersection(children) == children.subtracting([child]))
        let both = try resolve(blocked: [aggregate, child], allowed: [child])
        #expect(!both.isEnabled(child))
    }

    @Test func `exported selections remain stable and the residual target is independent`() throws {
        let child = try #require(children.sorted().first)
        let exported = FirmwarePatchSetCatalog.currentSelection(.all, blocked: [aggregate], allowed: [child])
        #expect(FirmwarePatchSetCatalog.currentSelection(exported) == exported)
        #expect(exported.includes(child))
        #expect(!exported.includes(FirmwareGuestSystemPatchSet.arm64eX1AccessibilityRemaining))
        let residualOff = try resolve(blocked: [FirmwareGuestSystemPatchSet.arm64eX1AccessibilityRemaining])
        #expect(residualOff.enabled.intersection(children) == children)
        var preset = FirmwarePatchSetCatalog.standardPreset
        preset.selection = exported
        let plan = try resolve(preset)
        #expect(plan.enabled.intersection(children) == [child])
    }

    @Test func `legacy aggregate receipt is not expanded before file migration`() {
        #expect(FirmwarePatchSetCatalog.currentIdentifiers([aggregate]) == [aggregate])
        #expect(FirmwarePatchSetCatalog.currentIdentifiers(["txm-boot-precheck_admission"]) == ["txm-exp-precheck_admission"])
    }

    @Test func `legacy TXM selections resolve and precheck remains explicit`() throws {
        let standard = try resolve()
        #expect(standard.isEnabled("txm-cfw-executable_remap"))
        #expect(!standard.isEnabled("txm-exp-precheck_admission"))
        let legacy = try resolve(allowed: ["txm-boot-precheck_admission"])
        #expect(legacy.isEnabled("txm-exp-precheck_admission"))
        var preset = FirmwarePatchSetCatalog.standardPreset
        preset.selection = .allow(["txm-boot-precheck_admission"])
        let oldPreset = try resolve(preset)
        #expect(oldPreset.enabled == ["txm-exp-precheck_admission"])
        #expect(!(try resolve(blocked: ["txm-boot-precheck_admission"])).isEnabled("txm-exp-precheck_admission"))
    }
}
