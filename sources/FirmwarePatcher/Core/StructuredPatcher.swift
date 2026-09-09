// StructuredPatcher.swift — Structured execution protocol, step runner, and legacy
// adapter for the C2 patch-result model.
//
// Execution rules (see research/patch_results_ablation_2026-09-09.md):
//   1. Ablation is intercepted BEFORE a step's `run` closure — no bytes are written
//      for an ablated step (important for kernel patchers that emit-on-find).
//   2. Each step runs exactly once; the record-count delta gives its recordIndices.
//   3. The raw result is mapped to a PatchOutcome via requirement × gate snapshot.

import Foundation

/// A single patch method, declared as an executable step.
public struct PatchStep {
    public let id: PatchID
    public let requirement: PatchRequirement
    /// Runs the method (which appends to the patcher's record list) and reports its
    /// raw result. Never called for an ablated step.
    public let run: () -> RawStepResult

    public init(id: PatchID, requirement: PatchRequirement, run: @escaping () -> RawStepResult) {
        self.id = id
        self.requirement = requirement
        self.run = run
    }
}

/// A patcher that declares method-level steps and can commit collected records.
///
/// Migrated patchers adopt this alongside `Patcher`; un-migrated patchers keep only
/// `Patcher` and are wrapped by `LegacyPatcherAdapter`.
public protocol StructuredPatcher: Patcher {
    /// The method steps, in execution order.
    func buildSteps() -> [PatchStep]

    /// Records emitted so far by executed steps (the patcher's internal patch list).
    var emittedRecords: [PatchRecord] { get }

    /// Write the given records' bytes into the patcher's buffer, without re-running
    /// discovery. Used instead of `apply()` so that ablated steps (whose records were
    /// never collected) leave no bytes, and so discovery runs exactly once.
    func commit(_ records: [PatchRecord])

    /// The patched payload after `commit`.
    var patchedData: Data { get }
}

/// Runs a structured patcher's steps and produces a `ComponentReport`.
public enum StructuredExecution {
    /// Execute `patcher`'s steps against `gates`, honoring the `ablate` set. Records
    /// from non-ablated steps are collected; `commit` writes them to the buffer.
    /// Returns the component report and the patched payload.
    public static func run(
        patcher: any StructuredPatcher,
        componentName: String,
        gates: PatchGateSnapshot,
        ablate: Set<String>,
        fallback: Data
    ) -> (report: ComponentReport, data: Data) {
        var results: [PatchResult] = []

        for step in patcher.buildSteps() {
            if isAblated(step.id, ablate) {
                results.append(PatchResult(
                    id: step.id,
                    requirement: step.requirement.kind,
                    rule: step.requirement.rule,
                    outcome: .ablated,
                    reason: "--ablate",
                    recordIndices: [],
                    gates: gates
                ))
                continue
            }

            let before = patcher.emittedRecords.count
            let raw = step.run()
            let after = patcher.emittedRecords.count
            let outcome = PatchOutcomeMapping.outcome(for: raw, requirement: step.requirement, gates: gates)

            results.append(PatchResult(
                id: step.id,
                requirement: step.requirement.kind,
                rule: step.requirement.rule,
                outcome: outcome.kind,
                reason: outcome.reason,
                recordIndices: Array(before ..< after),
                gates: gates
            ))
        }

        let records = patcher.emittedRecords
        patcher.commit(records)
        let data = records.isEmpty ? fallback : patcher.patchedData
        let report = ComponentReport(
            component: componentName,
            coverage: .structured,
            results: results,
            records: records
        )
        return (report, data)
    }

    /// Whether a step id is hit by any ablation value (component / patcher / full id).
    public static func isAblated(_ id: PatchID, _ ablate: Set<String>) -> Bool {
        ablate.contains { id.matchesAblation($0) }
    }
}

/// Wraps an un-migrated `Patcher` so it appears in the structured report with
/// `coverage: .legacy`. Preserves the legacy "empty records ⇒ failed" semantics.
public enum LegacyPatcherAdapter {
    /// Run a legacy patcher exactly like the old `patchData` path (findAll + apply +
    /// extract), and produce a single aggregated `ComponentReport`.
    ///
    /// - Empty records → one `failed`/`required` result (old "no patches found" fails
    ///   the pipeline).
    /// - Non-empty records → one `applied`/`required` result.
    /// - Component/patcher-level ablation → one `ablated` result; the patcher is not run.
    ///
    /// `extract` mirrors `FirmwarePipeline.extractPatchedData` for this patcher type.
    public static func run(
        patcher: any Patcher,
        componentName: String,
        gates: PatchGateSnapshot,
        ablate: Set<String>,
        fallback: Data,
        extract: (any Patcher, [PatchRecord]) -> Data
    ) throws -> (report: ComponentReport, data: Data) {
        let patcherName = String(describing: type(of: patcher))
        let componentTarget = componentName.lowercased()
        let patcherTarget = "\(componentTarget).\(patcherName)"
        // Legacy patchers declare no method id, so only component/patcher granularity applies.
        let id = PatchID(component: componentTarget, patcher: patcherName, method: "*")

        if ablate.contains(componentTarget) || ablate.contains(patcherTarget) {
            let result = PatchResult(
                id: id, requirement: .required, rule: nil,
                outcome: .ablated, reason: "--ablate (legacy)", recordIndices: [], gates: gates
            )
            return (ComponentReport(component: componentName, coverage: .legacy, results: [result], records: []), fallback)
        }

        let records = try patcher.findAll()
        if records.isEmpty {
            let result = PatchResult(
                id: id, requirement: .required, rule: nil,
                outcome: .failed, reason: "legacy: no patches found", recordIndices: [], gates: gates
            )
            return (ComponentReport(component: componentName, coverage: .legacy, results: [result], records: []), fallback)
        }

        _ = try patcher.apply()
        let data = extract(patcher, records)
        let result = PatchResult(
            id: id, requirement: .required, rule: nil,
            outcome: .applied, reason: nil,
            recordIndices: Array(records.indices), gates: gates
        )
        return (ComponentReport(component: componentName, coverage: .legacy, results: [result], records: records), data)
    }
}
