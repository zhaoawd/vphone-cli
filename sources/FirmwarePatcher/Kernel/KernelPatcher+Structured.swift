// KernelPatcher+Structured.swift — Structured execution (C3, group 2) for the regular
// base kernel patcher.
//
// This is a pure-additive, byte-equivalent migration: it adds the `StructuredPatcher`
// conformance and per-method `PatchStep` factories without changing any emit/write-byte
// logic. `buildSteps()` declares the same 12 methods in the same order as `findAll()`,
// and the records emitted along the success path are byte-identical to `findAll()`.
//
// `KernelPatcher` is `final` with no subclasses, so — unlike `IBootPatcher`, whose
// witnesses live in the class body to allow `IBootJBPatcher` to override `buildSteps()`
// via dynamic dispatch — the conformance can live entirely in this extension.

import Foundation

/// Raw signal returned by a kernel patch method so its structured step can report the
/// exact outcome without inspecting the record list. Byte output is unchanged; only a
/// return value is added (or reinterpreted). Translated to `RawStepResult` in `rawResult`.
///
/// Mirrors `IBootStepSignal` case-for-case.
enum KernelStepSignal: Equatable {
    /// Anchor found and all expected records emitted.
    case matched
    /// No anchor found (or a gated method whose gate is false).
    case noAnchor
    /// Some but not all records of a multi-record group were emitted. Maps to
    /// `.encodeFail` → failed. Byte-wise this reproduces the legacy aggregate returning
    /// `false` while the sub-patches that did match have already written their bytes.
    case partial(String)
    /// More than one candidate where exactly one was expected.
    case ambiguous(Int)
}

extension KernelPatcher: StructuredPatcher {
    // MARK: - StructuredPatcher requirements

    /// Declares the 12 base-kernel methods in the exact order of `findAll()`.
    ///
    /// Requirements (see research/patch_results_c3_kernel_base_2026-09-10.md):
    ///   - methods 1–11 are `.required` (each is a core boot-blocking bypass; the C1
    ///     manifest lists them required=true).
    ///   - method 12 `patchExcGuardBehavior` is declared unconditionally (so it is a valid
    ///     ablation target) with `.conditional(.excGuardActive)`. Its `run` closure applies
    ///     the patch only when `isDev || applyExcGuard`, exactly reproducing
    ///     `findAll()`'s `if isDev || applyExcGuard` gate; otherwise it returns `.noMatch`,
    ///     which — paired with the conditional rule being false — maps to `notApplicable`.
    ///
    /// Cheap and safe on an empty payload: it only constructs `PatchStep`s and never parses.
    public func buildSteps() -> [PatchStep] {
        [
            apfsRootSnapshotStep(),      // 1
            apfsSealBrokenStep(),        // 2
            bsdInitRootvpStep(),         // 3
            launchConstraintsStep(),     // 4-5
            debuggerStep(),              // 6-7
            postValidationNOPStep(),     // 8
            postValidationCMPStep(),     // 9
            dyldPolicyStep(),            // 10-11
            apfsGraftStep(),             // 12
            apfsMountStep(),             // 13-16
            sandboxStep(),               // 17-26
            excGuardBehaviorStep(),      // 26
        ]
    }

    public var emittedRecords: [PatchRecord] { patches }

    /// Write the given records' bytes into the buffer (idempotent; mirrors
    /// `KernelPatcherBase.applyPatches()`). `KernelPatcherBase.emit` already writes each
    /// patch through to `buffer.data` as it is recorded, so this re-write is a no-op for a
    /// normally-run patcher and only matters for the structured contract.
    public func commit(_ records: [PatchRecord]) {
        for record in records {
            buffer.writeBytes(at: record.fileOffset, bytes: record.patchedBytes)
        }
    }

    public var patchedData: Data { buffer.data }

    // MARK: - Signal → RawStepResult

    /// Translate a `KernelStepSignal` into the structured `RawStepResult`
    /// (identical mapping to `IBootPatcher.rawResult`).
    private func rawResult(_ signal: KernelStepSignal) -> RawStepResult {
        switch signal {
        case .matched: .matched
        case .noAnchor: .noMatch
        case let .partial(reason): .encodeFail(reason: reason)
        case let .ambiguous(count): .ambiguous(count: count)
        }
    }

    private func step(_ method: String, _ requirement: PatchRequirement, run: @escaping () -> RawStepResult) -> PatchStep {
        PatchStep(
            id: PatchID(component: component, patcher: "KernelPatcher", method: method),
            requirement: requirement,
            run: run
        )
    }

    // MARK: - Step factories

    /// Count-delta step for a single-anchor method that keeps its `Bool` return: run it and
    /// report `.matched` when it emitted at least one record, else `.noMatch`. Always calls
    /// `ensurePrepared()` first so heavyweight setup runs even if earlier steps were ablated.
    private func countDeltaStep(_ method: String, _ requirement: PatchRequirement, _ body: @escaping () -> Void) -> PatchStep {
        step(method, requirement) { [self] in
            ensurePrepared()
            let before = patches.count
            body()
            return patches.count > before ? .matched : .noMatch
        }
    }

    private func apfsRootSnapshotStep() -> PatchStep {
        countDeltaStep("patchApfsRootSnapshot", .required) { [self] in patchApfsRootSnapshot() }
    }

    private func apfsSealBrokenStep() -> PatchStep {
        countDeltaStep("patchApfsSealBroken", .required) { [self] in patchApfsSealBroken() }
    }

    private func bsdInitRootvpStep() -> PatchStep {
        countDeltaStep("patchBsdInitRootvp", .required) { [self] in patchBsdInitRootvp() }
    }

    private func launchConstraintsStep() -> PatchStep {
        countDeltaStep("patchLaunchConstraints", .required) { [self] in patchLaunchConstraints() }
    }

    private func debuggerStep() -> PatchStep {
        countDeltaStep("patchDebugger", .required) { [self] in patchDebugger() }
    }

    private func postValidationNOPStep() -> PatchStep {
        countDeltaStep("patchPostValidationNOP", .required) { [self] in patchPostValidationNOP() }
    }

    /// Method returns `KernelStepSignal` directly (unique/ambiguous/no-anchor distinction).
    private func postValidationCMPStep() -> PatchStep {
        step("patchPostValidationCMP", .required) { [self] in
            ensurePrepared()
            return rawResult(patchPostValidationCMP())
        }
    }

    private func dyldPolicyStep() -> PatchStep {
        countDeltaStep("patchDyldPolicy", .required) { [self] in patchDyldPolicy() }
    }

    private func apfsGraftStep() -> PatchStep {
        countDeltaStep("patchApfsGraft", .required) { [self] in patchApfsGraft() }
    }

    /// Aggregate of the 4 apfs-mount sub-patches; returns `KernelStepSignal`.
    private func apfsMountStep() -> PatchStep {
        step("patchApfsMount", .required) { [self] in
            ensurePrepared()
            return rawResult(patchApfsMount())
        }
    }

    /// Sandbox MACF hooks (5 hook pairs); returns `KernelStepSignal`.
    private func sandboxStep() -> PatchStep {
        step("patchSandbox", .required) { [self] in
            ensurePrepared()
            return rawResult(patchSandbox())
        }
    }

    /// EXC_GUARD disable — unconditionally declared (valid ablation target) but only run
    /// when `isDev || applyExcGuard`, matching `findAll()`'s gate. When the gate is false,
    /// returns `.noMatch`; with `.conditional(.excGuardActive)` this maps to `notApplicable`.
    private func excGuardBehaviorStep() -> PatchStep {
        step("patchExcGuardBehavior", .conditional(.excGuardActive)) { [self] in
            ensurePrepared()
            guard isDev || applyExcGuard else { return .noMatch }
            let before = patches.count
            patchExcGuardBehavior()
            return patches.count > before ? .matched : .noMatch
        }
    }
}
