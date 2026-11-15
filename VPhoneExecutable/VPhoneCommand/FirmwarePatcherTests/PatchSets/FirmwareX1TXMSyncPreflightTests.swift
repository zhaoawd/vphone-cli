import CryptoKit
@testable import FirmwarePatcher
import Foundation
import Testing
import VPhonePatchKit

// Explicit preflight against the fixed upstream inventory, not a migration or
// a guest acceptance test. Enable with the saved runner in Research/Integration.
@Suite("Duo X1 and TXM synchronization preflight", .enabled(if: ProcessInfo.processInfo.environment["VPHONE_X1_TXM_PREFLIGHT_DIR"] != nil, "requires the scoped preflight runner"))
struct FirmwareX1TXMSyncPreflightTests {
    static var outputPath: String? { ProcessInfo.processInfo.environment["VPHONE_X1_TXM_PREFLIGHT_DIR"] }
    static var txmPath: String? { ProcessInfo.processInfo.environment["VPHONE_X1_TXM_PREFLIGHT_TXM"] }

    struct Inventory: Decodable {
        struct Image: Decodable { let identifier: String; let path: String }
        let revision: String
        let images: [Image]
    }

    static func save(_ name: String, _ value: Any) throws {
        let root = try #require(outputPath)
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted])
        try (bytes + Data("\n".utf8)).write(to: URL(fileURLWithPath: root).appendingPathComponent(name))
    }

    static func plan(version: String?, blocked: Set<String> = []) throws -> VPhonePatchPlan {
        var preset = FirmwarePatchSetCatalog.standardPreset
        preset.selection = preset.selection.blocking(blocked)
        return try VPhonePatchPlan.resolve(
            preset: preset, patchSets: FirmwarePatchSetCatalog.bundled,
            iOSBase: version.flatMap(VPhoneVersion.init), cloudOS: VPhoneVersion("26.4"),
        )
    }

    @Test func `record the upstream inventory overlap and current version selections`() throws {
        let root = try #require(Self.outputPath)
        let inventory = try JSONDecoder().decode(Inventory.self, from: Data(contentsOf:
            URL(fileURLWithPath: root).appendingPathComponent("upstream-accessibility.json")))
        #expect(inventory.revision == "1316940501398ea279f960ee7d838f93885730d4")
        #expect(inventory.images.count == 35)
        #expect(Set(inventory.images.map(\.identifier)).count == 35)
        #expect(Set(inventory.images.map(\.path)).count == 35)
        let declarations = FirmwarePatchSetCatalog.allDeclarations
        let aggregateID = FirmwareGuestSystemPatchSet.arm64eX1AccessibilityBundles
        let aggregate = try #require(declarations.first { $0.identifier == aggregateID })
        #expect(aggregate.target == .guestExecutable(path: "/" + FirmwareGuestSystemPatchSet.accessibilityBundlesPath))
        let overlap = inventory.images.map { image -> [String: Any] in
            let covered = image.path.hasPrefix(FirmwareGuestSystemPatchSet.accessibilityBundlesPath + "/")
            #expect(covered)
            let exact = declarations.compactMap { declaration -> String? in
                switch declaration.target {
                case let .guestExecutable(path), let .guestFile(path):
                    return path == "/" + image.path ? declaration.identifier : nil
                default: return nil
                }
            }
            return ["upstream_identifier": image.identifier, "path": image.path,
                    "inside_current_aggregate_directory": covered, "current_exact_declarations": exact]
        }
        let policies = try ([nil, "18.6.2", "26.4", "27.0.1", "27.1", "27.2", "28.0"] as [String?]).map { version -> [String: Any] in
            let plan = try Self.plan(version: version)
            let ids = [aggregateID, "txm-boot-precheck_admission", "txm-exp-precheck_admission", "txm-cfw-executable_remap", "kernel-boot-amfi_trustcache"]
            return ["iOS_base": version as Any? ?? NSNull(), "policies": ids.map { id in
                ["identifier": id, "declared": declarations.contains { $0.identifier == id }, "enabled": plan.isEnabled(id)] as [String: Any]
            }]
        }
        try Self.save("catalogue-preflight.json", ["upstream_revision": inventory.revision,
            "aggregate_identifier": aggregateID, "inventory": overlap, "standard_selections": policies])
    }

    @Test(.enabled(if: txmPath != nil, "needs an original TXM IM4P"))
    func `real TXM precheck records obey deselection and change only their recorded ranges`() throws {
        let sourceURL = URL(fileURLWithPath: try #require(Self.txmPath))
        let originalFile = try Data(contentsOf: sourceURL)
        let source = try IM4PHandler.load(contentsOf: sourceURL).payload
        try source.write(to: URL(fileURLWithPath: try #require(Self.outputPath)).appendingPathComponent("txm-reference.raw"))
        let enabled = TXMDevPatcher(data: source, verbose: false)
        enabled.gate = VPhonePatchGate(plan: try Self.plan(version: "27.1"))
        let records = try enabled.findAll()
        let precheck = records.filter { $0.patchID.hasPrefix("txm-boot-precheck_admission.") }
        #expect(precheck.count == 4)
        #expect(precheck.allSatisfy { !enabled.gate.isUndeclared(record: $0.patchID) })
        let first = try #require(precheck.first)
        #expect(precheck.map(\.fileOffset).sorted() == (0..<4).map { first.fileOffset + $0 * 4 })
        var expected = source
        for record in records {
            #expect(source.subdata(in: record.fileOffset..<(record.fileOffset + record.originalBytes.count)) == record.originalBytes)
            expected.replaceSubrange(record.fileOffset..<(record.fileOffset + record.patchedBytes.count), with: record.patchedBytes)
        }
        _ = try enabled.apply()
        #expect(enabled.patchedData == expected)
        let disabled = TXMDevPatcher(data: source, verbose: false)
        disabled.gate = VPhonePatchGate(plan: try Self.plan(version: "27.1", blocked: ["txm-boot-precheck_admission"]))
        let without = try disabled.findAll()
        #expect(!without.contains { $0.patchID.hasPrefix("txm-boot-precheck_admission.") })
        #expect(without.map(\.patchID) == records.filter { !$0.patchID.hasPrefix("txm-boot-precheck_admission.") }.map(\.patchID))
        #expect(try Data(contentsOf: sourceURL) == originalFile)
        func rows(_ records: [PatchRecord]) -> [[String: Any]] {
            records.map { ["identifier": $0.patchID, "offset": $0.fileOffset,
                          "before": $0.originalBytes.map { String(format: "%02x", $0) }.joined(),
                          "after": $0.patchedBytes.map { String(format: "%02x", $0) }.joined()] }
        }
        try Self.save("txm-current-records.json", ["source": sourceURL.path,
            "container_sha256": SHA256.hash(data: originalFile).map { String(format: "%02x", $0) }.joined(),
            "payload_sha256": SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined(),
            "standard": rows(records), "precheck_blocked": rows(without), "source_unchanged": true])
    }

    @Test func `a naive declaration replacement cannot preserve legacy selection ownership`() throws {
        let root = try #require(Self.outputPath)
        let inventory = try JSONDecoder().decode(Inventory.self, from: Data(contentsOf:
            URL(fileURLWithPath: root).appendingPathComponent("upstream-accessibility.json")))
        let aggregate = FirmwareGuestSystemPatchSet.arm64eX1AccessibilityBundles
        let additions = inventory.images.map { image in
            VPhonePatchDeclaration(identifier: image.identifier, title: image.identifier, target: .guestFile(path: "/" + image.path))
        }
        var combined = FirmwarePatchSetCatalog.bundled
        let guest = try #require(combined.firstIndex { $0.identifier == FirmwareGuestSystemPatchSet.identifier })
        combined[guest].patches += additions
        var legacy = FirmwarePatchSetCatalog.standardPreset
        legacy.selection = legacy.selection.blocking([aggregate])
        let mixed = try VPhonePatchPlan.resolve(preset: legacy, patchSets: combined,
            iOSBase: VPhoneVersion("27.1"), cloudOS: VPhoneVersion("26.4"))
        #expect(!mixed.isEnabled(aggregate))
        let independentlyEnabled = inventory.images.filter { mixed.isEnabled($0.identifier) }.count
        #expect(independentlyEnabled == 35)
        combined[guest].patches.removeAll { $0.identifier == aggregate }
        var aggregateReplacementRefused = false
        do {
            _ = try VPhonePatchPlan.resolve(preset: legacy, patchSets: combined,
                iOSBase: VPhoneVersion("27.1"), cloudOS: VPhoneVersion("26.4"))
        } catch let error as VPhonePatchPlanError {
            if case let .unknownPatch(_, id) = error, id == aggregate { aggregateReplacementRefused = true }
        }
        #expect(aggregateReplacementRefused)

        var renamed = FirmwarePatchSetCatalog.bundled
        let boot = try #require(renamed.firstIndex { $0.identifier == FirmwareBootChainPatchSet.identifier })
        let oldID = "txm-boot-precheck_admission", newID = "txm-exp-precheck_admission"
        let index = try #require(renamed[boot].patches.firstIndex { $0.identifier == oldID })
        var replacement = renamed[boot].patches[index]
        replacement.identifier = newID
        replacement.bootEssential = false
        renamed[boot].patches[index] = replacement
        var oldTXMSelection = FirmwarePatchSetCatalog.standardPreset
        oldTXMSelection.selection = oldTXMSelection.selection.blocking([oldID])
        var txmRenameRefused = false
        do {
            _ = try VPhonePatchPlan.resolve(preset: oldTXMSelection, patchSets: renamed,
                iOSBase: VPhoneVersion("27.1"), cloudOS: VPhoneVersion("26.4"))
        } catch let error as VPhonePatchPlanError {
            if case let .unknownPatch(_, id) = error, id == oldID { txmRenameRefused = true }
        }
        #expect(txmRenameRefused)
        try Self.save("selection-migration-negative.json", ["legacy_aggregate_disabled": true,
            "independent_images_still_enabled_without_mapping": independentlyEnabled,
            "removed_aggregate_rejects_old_selection": aggregateReplacementRefused,
            "renamed_txm_rejects_old_selection": txmRenameRefused])
    }

    @Test(.enabled(if: txmPath != nil, "needs an original TXM IM4P"))
    func `a missing policy callback anchor emits no precheck records`() throws {
        let url = URL(fileURLWithPath: try #require(Self.txmPath))
        var source = try IM4PHandler.load(contentsOf: url).payload
        let disassembler = ARM64Disassembler()
        var anchors: [Int] = []
        for offset in stride(from: 0, to: source.count - 8, by: 4) {
            guard let instruction = disassembler.disassembleOne(in: source, at: offset),
                  instruction.mnemonic == "mov", let operands = instruction.detail?.operands, operands.count == 2,
                  operands[0].reg == .x(17), operands[1].type == .immediate, operands[1].imm == 0x7e51,
                  disassembler.disassembleOne(in: source, at: offset + 4)?.mnemonic == "blraa" else { continue }
            anchors.append(offset + 4)
        }
        #expect(!anchors.isEmpty)
        for offset in anchors { source.replaceSubrange(offset..<(offset + 4), with: ARM64.nop) }
        let patcher = TXMDevPatcher(data: source, verbose: false)
        patcher.patchPrecheckForcePass()
        #expect(patcher.patches.isEmpty)
        #expect(patcher.patchedData == source)
        try Self.save("txm-anchor-negative.json", ["mutated_callback_count": anchors.count, "records": patcher.patches.count])
    }
}
