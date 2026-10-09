// DeclarationGateTests.swift — T11: strict resolver rejections and the write-side gate.
//
// Each resolver rejection class has one example (unknown / duplicate / missing dependency /
// conflict / cyclic order / version indeterminate / required missing / not-implemented
// selected). The write gate rejects an undeclared record and a not-enabled record and passes
// a clean report. The byte-invariance test drives a real FirmwareTransaction and shows a
// pre-commit gate rejection leaves the original bytes unchanged.

import Foundation
import Testing
@testable import FirmwarePatcher

@Suite struct DeclarationGateTests {
    // MARK: - Helpers

    static func decl(
        _ id: String, coverage: PatchDeclaration.Coverage = .swift, steps: [String] = [],
        variants: Set<String> = ["regular"], optIn: PatchDeclaration.OptIn = .none,
        required: Bool = false, rule: PatchRule? = .always,
        requires: [String] = [], conflicts: [String] = [], after: [String] = []
    ) -> PatchDeclaration {
        PatchDeclaration(
            id: id, title: id, coverage: coverage, swiftSteps: steps, variants: variants,
            optIn: optIn, required: required, versionRule: rule, upstreamIDs: [id],
            upstreamApplicability: "test", requires: requires, conflicts: conflicts, after: after)
    }

    static func gates(_ variant: String = "regular", base27: Bool = false) -> PatchGateSnapshot {
        PatchGateSnapshot(
            variant: variant, iosBaseIs18: false, iosBaseIs27: base27, cloudOSIsFridaCapable: true,
            forceExcGuard: false, enableFrida: false, excGuardActive: false,
            applyIOS27: base27, applyFrida: false)
    }

    static func record(component: String = "avpbooter") -> PatchRecord {
        PatchRecord(patchID: "fixture", component: component, fileOffset: 0,
            originalBytes: Data([0]), patchedBytes: Data([1]), description: "gate fixture")
    }

    static func report(
        step: String, outcome: OutcomeKind, variant: String,
        indices: [Int]? = nil, records: [PatchRecord]? = nil
    ) -> PatchRunReport {
        let g = gates(variant)
        let id = try! JSONDecoder().decode(PatchID.self, from: Data("\"\(step)\"".utf8))
        let writes = outcome == .applied
        let result = PatchResult(id: id, requirement: .required, rule: nil, outcome: outcome,
            reason: nil, recordIndices: indices ?? (writes ? [0] : []), gates: g)
        let component = ComponentReport(component: id.component, coverage: .structured,
            results: [result], records: records ?? (writes ? [record(component: id.component)] : []))
        return PatchRunReport(variant: variant, gates: g, components: [component], ablation: [])
    }

    // MARK: - Resolver rejections (each class once)

    @Test func unknownDeclarationSelected() {
        #expect(throws: PatchDeclarationCatalog.CatalogError.unknownDeclaration(id: "no-such-id")) {
            _ = try VariantPlanResolver.resolve(variant: .regular, gates: Self.gates(), select: ["no-such-id"])
        }
    }

    @Test func notImplementedSelected() {
        #expect(throws: PatchDeclarationCatalog.CatalogError.notImplementedSelected(id: "dyld-exp-mis_trust_auth")) {
            _ = try VariantPlanResolver.resolve(variant: .exp, gates: Self.gates("exp"),
                select: ["dyld-exp-mis_trust_auth"])
        }
    }

    @Test func duplicateDeclaration() {
        let catalog = [Self.decl("dup"), Self.decl("dup")]
        #expect(throws: PatchDeclarationCatalog.CatalogError.duplicateDeclaration(id: "dup")) {
            try PatchDeclarationCatalog.validateStructure(catalog)
        }
    }

    @Test func missingDependencyStructural() {
        let catalog = [Self.decl("a", requires: ["absent"])]
        #expect(throws: PatchDeclarationCatalog.CatalogError.missingDependency(id: "a", requires: "absent")) {
            try PatchDeclarationCatalog.validateStructure(catalog)
        }
    }

    @Test func missingDependencyWhenTargetNotEnabled() {
        // a is enabled (always) and requires b, but b is version-gated off (27-only on a 26 base).
        // Built on the real catalog so the live pipeline steps stay declared.
        let catalog = PatchDeclarationCatalog.all + [
            Self.decl("test-a", steps: [], variants: ["regular"], required: false, rule: .always, requires: ["test-b"]),
            Self.decl("test-b", steps: [], variants: ["regular"], required: false, rule: .iosBaseIs27),
        ]
        #expect(throws: PatchDeclarationCatalog.CatalogError.missingDependency(id: "test-a", requires: "test-b")) {
            _ = try VariantPlanResolver.resolve(variant: .regular, gates: Self.gates(), catalog: catalog)
        }
    }

    @Test func conflictBetweenEnabled() {
        let catalog = PatchDeclarationCatalog.all + [
            Self.decl("test-a", variants: ["regular"], conflicts: ["test-b"]),
            Self.decl("test-b", variants: ["regular"]),
        ]
        #expect(throws: PatchDeclarationCatalog.CatalogError.conflict(id: "test-a", with: "test-b")) {
            _ = try VariantPlanResolver.resolve(variant: .regular, gates: Self.gates(), catalog: catalog)
        }
    }

    @Test func cyclicOrder() {
        let catalog = [Self.decl("a", after: ["b"]), Self.decl("b", after: ["a"])]
        #expect(throws: (any Error).self) {
            try PatchDeclarationCatalog.validateStructure(catalog)
        }
    }

    @Test func versionIndeterminateWhenBaseUnknown() {
        // jb carries required iOS-27-gated declarations; an unreadable base is indeterminate.
        #expect(throws: (any Error).self) {
            _ = try VariantPlanResolver.resolve(
                variant: .jb, gates: Self.gates("jb"), baseVersionKnown: false)
        }
    }

    @Test func requiredMissingWhenPipelineLacksStep() {
        var catalog = PatchDeclarationCatalog.all
        catalog.append(Self.decl("test-required-missing",
            steps: ["kernelcache.KernelPatcher.notARealStep"],
            variants: ["regular"], required: true, rule: .always))
        #expect(throws: PatchDeclarationCatalog.CatalogError.requiredMissing(
            variant: "regular", id: "test-required-missing")) {
            _ = try VariantPlanResolver.resolve(variant: .regular, gates: Self.gates(), catalog: catalog)
        }
    }

    @Test func liveStepUndeclaredWhenCatalogIncomplete() {
        // A catalog missing the real avpbooter step: the live pipeline step is undeclared.
        let catalog = PatchDeclarationCatalog.all.filter {
            !$0.swiftSteps.contains("avpbooter.AVPBooterPatcher.patchDGSTBypass")
        }
        #expect(throws: (any Error).self) {
            _ = try VariantPlanResolver.resolve(variant: .regular, gates: Self.gates(), catalog: catalog)
        }
    }

    // MARK: - Write gate

    @Test func gatePassesForACleanReport() throws {
        let report = Self.report(step: "avpbooter.AVPBooterPatcher.patchDGSTBypass",
            outcome: .applied, variant: "regular")
        try PatchDeclarationGate.enforce(report: report, variant: "regular", gates: report.gates)
        #expect(PatchDeclarationGate.violations(in: report, variant: "regular", gates: report.gates).isEmpty)
    }

    @Test func gateRejectsAnUndeclaredRecord() {
        let report = Self.report(step: "made.UpPatcher.doesNotExist", outcome: .applied, variant: "regular")
        let violations = PatchDeclarationGate.violations(in: report, variant: "regular", gates: report.gates)
        #expect(violations.map(\.kind) == [.undeclared])
        #expect(throws: (any Error).self) {
            try PatchDeclarationGate.enforce(report: report, variant: "regular", gates: report.gates)
        }
    }

    @Test func gateRejectsANotEnabledRecord() {
        // An exp-only DeviceTree identity step, emitted under the regular variant.
        let report = Self.report(step: "devicetree.DeviceTreePatcher.target_sub_type",
            outcome: .applied, variant: "regular")
        let violations = PatchDeclarationGate.violations(in: report, variant: "regular", gates: report.gates)
        #expect(violations.map(\.kind) == [.notEnabled])
        #expect(throws: (any Error).self) {
            try PatchDeclarationGate.enforce(report: report, variant: "regular", gates: report.gates)
        }
    }

    @Test func gateIgnoresNotApplicableAndAblatedResults() {
        // A not-enabled step that did not apply (notApplicable) is not a violation.
        let report = Self.report(step: "devicetree.DeviceTreePatcher.target_sub_type",
            outcome: .notApplicable, variant: "regular")
        #expect(PatchDeclarationGate.violations(in: report, variant: "regular", gates: report.gates).isEmpty)
    }

    @Test func gateRejectsRecordsWithoutAnOwningResult() {
        let report = Self.report(step: "avpbooter.AVPBooterPatcher.patchDGSTBypass",
            outcome: .applied, variant: "regular", indices: [])
        #expect(throws: (any Error).self) {
            try PatchDeclarationGate.enforce(report: report, variant: "regular", gates: report.gates)
        }
    }

    @Test(arguments: [-1, 1]) func gateRejectsInvalidRecordIndices(index: Int) {
        let report = Self.report(step: "avpbooter.AVPBooterPatcher.patchDGSTBypass",
            outcome: .applied, variant: "regular", indices: [index])
        #expect(throws: (any Error).self) {
            try PatchDeclarationGate.enforce(report: report, variant: "regular", gates: report.gates)
        }
    }

    @Test func gateRejectsDuplicateRecordIndicesWithinAResult() {
        let report = Self.report(step: "avpbooter.AVPBooterPatcher.patchDGSTBypass",
            outcome: .applied, variant: "regular", indices: [0, 0])
        #expect(throws: (any Error).self) {
            try PatchDeclarationGate.enforce(report: report, variant: "regular", gates: report.gates)
        }
    }

    @Test func gateRejectsMultipleOwnersForARecord() {
        let clean = Self.report(step: "avpbooter.AVPBooterPatcher.patchDGSTBypass",
            outcome: .applied, variant: "regular")
        let component = ComponentReport(component: "avpbooter", coverage: .structured,
            results: clean.components[0].results + clean.components[0].results,
            records: clean.components[0].records)
        let report = PatchRunReport(variant: "regular", gates: clean.gates,
            components: [component], ablation: [])
        #expect(throws: (any Error).self) {
            try PatchDeclarationGate.enforce(report: report, variant: "regular", gates: report.gates)
        }
    }

    @Test func gateRejectsAnUndeclaredFailedStepThatEmittedRecords() {
        let report = Self.report(step: "made.UpPatcher.doesNotExist", outcome: .failed,
            variant: "regular", indices: [0], records: [Self.record(component: "made")])
        #expect(throws: (any Error).self) {
            try PatchDeclarationGate.enforce(report: report, variant: "regular", gates: report.gates)
        }
    }

    @Test(arguments: [OutcomeKind.ablated, .notApplicable])
    func gateRejectsRecordsFromAnOutcomeThatCannotWrite(outcome: OutcomeKind) {
        let report = Self.report(step: "avpbooter.AVPBooterPatcher.patchDGSTBypass",
            outcome: outcome, variant: "regular", indices: [0], records: [Self.record()])
        #expect(throws: (any Error).self) {
            try PatchDeclarationGate.enforce(report: report, variant: "regular", gates: report.gates)
        }
    }

    @Test func gateAllowsAnAlreadyAppliedStepWithoutRecords() throws {
        let report = Self.report(step: "avpbooter.AVPBooterPatcher.patchDGSTBypass",
            outcome: .alreadyApplied, variant: "regular")
        try PatchDeclarationGate.enforce(report: report, variant: "regular", gates: report.gates)
    }

    @Test func gateAllowsMultipleRecordsOwnedByOneDeclaredStep() throws {
        let report = Self.report(step: "avpbooter.AVPBooterPatcher.patchDGSTBypass",
            outcome: .applied, variant: "regular", indices: [0, 1],
            records: [Self.record(), Self.record()])
        try PatchDeclarationGate.enforce(report: report, variant: "regular", gates: report.gates)
    }

    @Test func gateChecksOwnershipForDeclaredFailedSteps() throws {
        // Discovery can emit records before failing; ownership remains valid. Required
        // failure rejection is the pipeline's separate check, before this gate.
        let report = Self.report(step: "avpbooter.AVPBooterPatcher.patchDGSTBypass",
            outcome: .failed, variant: "regular", indices: [0], records: [Self.record()])
        try PatchDeclarationGate.enforce(report: report, variant: "regular", gates: report.gates)
        #expect(report.failedRequired.count == 1)
    }

    // MARK: - Byte invariance (reject before commit)

    @Test(arguments: [false, true])
    func rejectionBeforeCommitLeavesOriginalBytesUnchanged(unattributed: Bool) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let restore = root.appendingPathComponent("FixtureRestore")
        let boot = root.appendingPathComponent("AVPBooter.fixture.bin")
        try fm.createDirectory(at: restore, withIntermediateDirectories: true)
        try Data("original boot".utf8).write(to: boot)
        try Data("original manifest".utf8).write(to: restore.appendingPathComponent("BuildManifest.plist"))
        defer { try? fm.removeItem(at: root) }

        let transaction = try FirmwareTransaction(
            vmDirectory: root, inputs: [boot, restore], options: ["variant": "regular"])
        // Stage a patched copy (as the pipeline would before the gate runs).
        try Data("patched boot".utf8).write(to: transaction.stage.appendingPathComponent(boot.lastPathComponent))

        // Mirror patchAllStructured's do/catch for both an undeclared step and an
        // unattributed record: the gate throws before the staged bytes are published.
        let report = unattributed
            ? Self.report(step: "avpbooter.AVPBooterPatcher.patchDGSTBypass",
                outcome: .applied, variant: "regular", indices: [])
            : Self.report(step: "made.UpPatcher.doesNotExist", outcome: .applied, variant: "regular")
        do {
            try PatchDeclarationGate.enforce(report: report, variant: "regular", gates: report.gates)
            Issue.record("gate should have rejected the report")
        } catch {
            transaction.recordFailure(error)
        }

        // The original firmware was never replaced.
        #expect(try Data(contentsOf: boot) == Data("original boot".utf8))
        // A pending failed transaction is recoverable and leaves the original in place.
        #expect(try FirmwareTransaction.recover(vmDirectory: root) != nil)
        #expect(try Data(contentsOf: boot) == Data("original boot".utf8))
    }
}
