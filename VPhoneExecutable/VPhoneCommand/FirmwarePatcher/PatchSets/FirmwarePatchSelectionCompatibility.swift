import Foundation
import VPhonePatchKit

extension FirmwarePatchSetCatalog {
    /// Selection migration only. Receipts keep the retired directory identifier
    /// until installation has checked and transferred each file's backup.
    public static func currentSelection(
        _ selection: VPhonePatchSelection,
        blocked: Set<String> = [], allowed: Set<String> = [],
    ) -> VPhonePatchSelection {
        let legacy = FirmwareGuestSystemPatchSet.arm64eX1AccessibilityBundles
        let replacements = Set(FirmwareGuestSystemPatchSet.arm64eX1AccessibilityImages.map(\.identifier))
            .union([FirmwareGuestSystemPatchSet.arm64eX1HomePopAccessibility,
                    FirmwareGuestSystemPatchSet.arm64eX1AccessibilityRemaining])
        func expand(_ ids: Set<String>) -> Set<String> {
            let current = Set(currentIdentifiers(Array(ids)))
            return current.contains(legacy) ? current.subtracting([legacy]).union(replacements) : current
        }
        let migrated: VPhonePatchSelection
        switch selection {
        case .all: migrated = .all
        case let .allow(ids): migrated = .allow(expand(ids))
        case let .block(ids): migrated = .block(expand(ids))
        @unknown default: return selection
        }
        let blocked = Set(currentIdentifiers(Array(blocked)))
        let allowed = Set(currentIdentifiers(Array(allowed)))
        // Explicit individual choices override a legacy group. An explicit
        // block still wins when both lists name the same current identifier.
        let explicitAllowed = allowed.intersection(replacements).subtracting(blocked)
        return migrated.allowing(expand(allowed).subtracting(blocked.intersection(replacements)))
            .blocking(expand(blocked).subtracting(explicitAllowed))
    }

    public static func resolve(
        preset: VPhonePatchPreset, patchSets: [VPhonePatchSetManifest],
        iOSBase: VPhoneVersion?, cloudOS: VPhoneVersion?,
        blocked: Set<String> = [], allowed: Set<String> = [],
    ) throws -> VPhonePatchPlan {
        var current = preset
        current.selection = currentSelection(preset.selection, blocked: blocked, allowed: allowed)
        return try VPhonePatchPlan.resolve(
            preset: current, patchSets: patchSets, iOSBase: iOSBase, cloudOS: cloudOS,
        )
    }
}
