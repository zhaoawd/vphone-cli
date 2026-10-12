import Foundation
import Testing
@testable import FirmwarePatcher

@Suite struct TargetCatalogTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct Decisions: Decodable {
        struct Row: Decodable {
            let id: String
            let declaration: PatchDeclaration
            let applicability: [String: [String: String]]
        }
        let target: String
        let decisions: [Row]
    }

    static func decisions() throws -> Decisions {
        let url = root.appendingPathComponent("research/upstream_integration_2026-10-06/T09_target_applicability.json")
        return try JSONDecoder().decode(Decisions.self, from: Data(contentsOf: url))
    }

    static func sourceIDs() throws -> [String] {
        struct Manifest: Decodable {
            struct Row: Decodable { let id: String }
            let declarations: [Row]
        }
        let url = root.appendingPathComponent("research/upstream_integration_2026-10-06/evidence/2026-10-12-five-task-audit/fixed-target-source-manifest.json")
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url)).declarations.map(\.id)
    }

    // A missing mapping must never acquire execution permission from a preset default.
    @Test func targetIDsHaveExactlyOneDecision() throws {
        let expected = Set(try Self.sourceIDs())
        let actual = PatchDeclarationCatalog.all.flatMap(\.upstreamIDs)
        #expect(expected.count == 141)
        #expect(Set(actual).count == 141)
        #expect(actual.count == 141)
        #expect(expected.subtracting(actual).sorted() == [])
        #expect(Set(actual).subtracting(expected).isEmpty)
        try PatchDeclarationCatalog.validateStructure()
    }

    @Test(arguments: ["regular", "dev", "jb", "exp", "less"], [18, 26, 27, 99])
    func everyVariantAndVersionHasExplicitApplicability(variant: String, base: Int) throws {
        let mode = try #require(FirmwarePipeline.Variant(rawValue: variant))
        let gates = PatchGateSnapshot(
            variant: variant, iosBaseIs18: base == 18, iosBaseIs27: base == 27,
            cloudOSIsFridaCapable: true, forceExcGuard: false, enableFrida: false,
            excGuardActive: base == 18 || variant == "dev", applyIOS27: base == 27, applyFrida: false)
        let plan = try VariantPlanResolver.resolve(variant: mode, gates: gates)
        let decisions = try Self.decisions()
        #expect(decisions.target == "2d21d21fbdd4f51f013616273ceda9b35a3e0789")
        let entries = plan.selected + plan.excludedByVersion + plan.excludedByOptIn
            + plan.excludedByVariant + plan.notImplemented + plan.guestUncovered
        for row in decisions.decisions {
            #expect(Set(row.applicability.keys) == ["regular", "dev", "jb", "exp", "less"])
            let versions = try #require(row.applicability[variant])
            #expect(Set(versions.keys) == ["18", "26", "27", "other"])
            let expected = try #require(versions[base == 99 ? "other" : String(base)])
            let declaration = try #require(PatchDeclarationCatalog.byID[row.id])
            #expect(declaration == row.declaration)
            if declaration.coverage == .guestStep && !declaration.variants.contains(variant) {
                #expect(expected == "excludedByVariant")
                #expect(!entries.contains { $0.id == row.id })
            } else {
                #expect(entries.filter { $0.id == row.id }.map(\.disposition.rawValue) == [expected])
            }
            if declaration.coverage == .notImplemented {
                #expect(!(declaration.implementationNote ?? "").isEmpty)
                #expect(plan.notImplemented.contains { $0.id == row.id && $0.reason == declaration.implementationNote })
                #expect(throws: PatchDeclarationCatalog.CatalogError.notImplementedSelected(id: row.id)) {
                    _ = try VariantPlanResolver.resolve(variant: mode, gates: gates, select: [row.id])
                }
                let blocked = try VariantPlanResolver.resolve(variant: mode, gates: gates, block: [row.id])
                #expect(blocked.enabledSteps == plan.enabledSteps)
            }
        }
    }

    @Test func preservesEveryTargetDisableAndCanonicalMigrationIsStable() throws {
        let ids = try Self.sourceIDs().sorted()
        let first = try PatchSelectionMigration.preview(select: [], block: ids)
        let second = try PatchSelectionMigration.preview(select: first.selected, block: first.blocked)
        #expect(first.blocked == ids)
        #expect(first.selected.isEmpty)
        #expect(first == second)
        #expect(first.notDeclaredLocally.isEmpty)
        #expect(PatchDeclarationCatalog.byID["system-launchdaemons-boot-environment"]?.optIn == .guestEnvironmentV2)
        #expect(PatchDeclarationCatalog.byID["system-launchdaemons-boot-environment"]?.variants == ["regular"])
    }

    @Test func futureTargetIDsCannotDefaultToEnabled() {
        let id = "kernel-cfw-unreviewed_future_patch"
        #expect(throws: PatchSelectionMigration.MigrationError.unknownID(id)) {
            _ = try PatchSelectionMigration.preview(select: [id], block: [])
        }
        #expect(throws: PatchDeclarationCatalog.CatalogError.unknownDeclaration(id: id)) {
            _ = try VariantPlanResolver.resolve(variant: .regular, gates: DeclarationGateTests.gates(), select: [id])
        }
    }

    @Test func refusesDisablingOneTargetOfTheSharedSandboxStep() {
        #expect(throws: PatchDeclarationCatalog.CatalogError.partialStepSelection(
            id: "kernel-cfw-sandbox_file_check_mmap", step: "kernelcache.KernelPatcher.patchSandbox",
            enabled: ["kernel-boot-sandbox_mount_check_mount", "kernel-boot-sandbox_mount_check_remount",
                      "kernel-cfw-sandbox_mount_check_umount", "kernel-cfw-sandbox_vnode_check_rename"])) {
            _ = try VariantPlanResolver.resolve(variant: .regular, gates: DeclarationGateTests.gates(),
                block: ["kernel-cfw-sandbox_file_check_mmap"])
        }
    }

    @Test(arguments: ["regular", "dev", "jb", "exp", "less"], [18, 26, 27])
    func existingDefaultExecutionStepsArePreserved(variant: String, base: Int) throws {
        let url = Self.root.appendingPathComponent("research/t10_patch_declarations_2026-10-01.json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var rows = try #require(object["declarations"] as? [[String: Any]])
        for index in rows.indices where rows[index]["coverage"] as? String != "swift" {
            rows[index]["versionRule"] = NSNull()
        }
        object["declarations"] = rows
        struct Baseline: Decodable { let declarations: [PatchDeclaration] }
        let baseline = try JSONDecoder().decode(Baseline.self, from: JSONSerialization.data(withJSONObject: object))
        let mode = try #require(FirmwarePipeline.Variant(rawValue: variant))
        let gates = PatchGateSnapshot(
            variant: variant, iosBaseIs18: base == 18, iosBaseIs27: base == 27,
            cloudOSIsFridaCapable: true, forceExcGuard: false, enableFrida: false,
            excGuardActive: base == 18 || variant == "dev", applyIOS27: base == 27, applyFrida: false)
        let previous = try VariantPlanResolver.resolve(variant: mode, gates: gates, catalog: baseline.declarations)
        let current = try VariantPlanResolver.resolve(variant: mode, gates: gates)
        #expect(current.enabledSteps == previous.enabledSteps)
    }
}
