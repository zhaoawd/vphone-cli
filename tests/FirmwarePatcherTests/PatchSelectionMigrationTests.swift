import Testing
@testable import FirmwarePatcher

@Suite struct PatchSelectionMigrationTests {
    @Test func oldDottedIDsPreserveExplicitEnableAndDisable() throws {
        let result = try PatchSelectionMigration.preview(select: ["ibss.serial_label"], block: ["avpbooter.dgst_bypass"])
        #expect(result.selected == ["ibss-cfw-serial_label"])
        #expect(result.blocked == ["avpbooter-boot-dgst_bypass"])
        #expect(result.renames == [
            .init(from: "avpbooter.dgst_bypass", to: "avpbooter-boot-dgst_bypass", enabled: false),
            .init(from: "ibss.serial_label", to: "ibss-cfw-serial_label", enabled: true),
        ])
    }

    @Test func intermediateParavirtDisableSurvivesDefaultChange() throws {
        let result = try PatchSelectionMigration.preview(select: [], block: ["kernel-exp-paravirt_user_clients"])
        #expect(result.blocked == ["kernel-cfw-paravirt_user_clients"])
        #expect(result.notDeclaredLocally.isEmpty)
        #expect(PatchDeclarationCatalog.byID["kernel-cfw-paravirt_user_clients"]?.coverage == .notImplemented)
        #expect(result.selected.isEmpty)
    }

    @Test func migrationDoesNotEnableNewDefaults() throws {
        let result = try PatchSelectionMigration.preview(select: [], block: [])
        #expect(result.selected.isEmpty)
        #expect(result.blocked.isEmpty)
    }

    @Test func canonicalMigrationIsIdempotent() throws {
        let first = try PatchSelectionMigration.preview(select: ["ibss.serial_label"], block: ["kernel-exp-paravirt_user_clients"])
        let second = try PatchSelectionMigration.preview(select: first.selected, block: first.blocked)
        #expect(second.selected == ["ibss-cfw-serial_label"])
        #expect(second.blocked == ["kernel-cfw-paravirt_user_clients"])
        #expect(second.renames.isEmpty)
    }

    @Test(arguments: ["unknown-patch", "", " ibss.serial_label", "IBSS.serial_label"])
    func unknownIDsAreRejected(id: String) {
        #expect(throws: PatchSelectionMigration.MigrationError.unknownID(id)) {
            try PatchSelectionMigration.preview(select: [id], block: [])
        }
        #expect(throws: PatchSelectionMigration.MigrationError.unknownID(id)) {
            try PatchSelectionMigration.preview(select: [], block: [id])
        }
    }

    @Test(arguments: [true, false])
    func duplicateInputIsRejected(enabled: Bool) {
        let ids = ["ibss.serial_label", "ibss.serial_label"]
        #expect(throws: PatchSelectionMigration.MigrationError.duplicateID("ibss.serial_label")) {
            try PatchSelectionMigration.preview(select: enabled ? ids : [], block: enabled ? [] : ids)
        }
    }

    @Test(arguments: [true, false])
    func oldAndCanonicalAliasesCannotCollapseSilently(enabled: Bool) {
        let ids = ["ibss.serial_label", "ibss-cfw-serial_label"]
        #expect(throws: PatchSelectionMigration.MigrationError.duplicateTarget("ibss-cfw-serial_label")) {
            try PatchSelectionMigration.preview(select: enabled ? ids : [], block: enabled ? [] : ids)
        }
    }

    @Test func conflictingIntentAcrossAliasesIsRejected() {
        #expect(throws: PatchSelectionMigration.MigrationError.contradictoryID("ibss-cfw-serial_label")) {
            try PatchSelectionMigration.preview(select: ["ibss.serial_label"], block: ["ibss-cfw-serial_label"])
        }
    }

    @Test func localLessIDsRemainLocal() throws {
        let result = try PatchSelectionMigration.preview(select: ["filesystem-less-cryptex_merge"], block: ["manifest-less-hash_rewrite"])
        #expect(result.selected == ["filesystem-less-cryptex_merge"])
        #expect(result.blocked == ["manifest-less-hash_rewrite"])
        #expect(result.notDeclaredLocally.isEmpty)
    }

    @Test func newDeclarationDoesNotGainLocalExecutionCoverage() throws {
        let result = try PatchSelectionMigration.preview(select: ["kernel-boot-shared_region_size"], block: [])
        #expect(result.notDeclaredLocally.isEmpty)
        #expect(PatchDeclarationCatalog.byID["kernel-boot-shared_region_size"]?.coverage == .notImplemented)
    }

    @Test func bundledExtendedPresetMigratesWithoutRewritingModes() throws {
        #expect(try PatchSelectionMigration.migrateBundledPreset("extended") == "experimental")
        #expect(try PatchSelectionMigration.migrateBundledPreset("experimental") == "experimental")
        #expect(try PatchSelectionMigration.migrateBundledPreset("standard") == "standard")
    }

    @Test(arguments: ["regular", "exp", "custom", ""])
    func modeAndCustomPresetAreNotBundledPresetAliases(id: String) {
        #expect(throws: PatchSelectionMigration.MigrationError.unknownBundledPreset(id)) {
            try PatchSelectionMigration.migrateBundledPreset(id)
        }
    }
}
