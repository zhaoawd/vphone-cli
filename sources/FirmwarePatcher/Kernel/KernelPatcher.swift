// KernelPatcher.swift — Regular kernel patcher orchestrator.
//
// Historical note: this file replaces the old Python firmware patcher implementation.
// Each patch method is defined as an extension in its own file under Patches/.

import Foundation

/// Regular kernel patcher for iOS prelinked kernelcaches.
///
/// Patches are applied in the same order as the Python reference implementation.
/// Each patch method is an extension in a separate file under `Kernel/Patches/`.
public final class KernelPatcher: KernelPatcherBase, StructuredPatcher {
    public let component = "kernelcache"

    /// When true, includes dev-only kernel patches (e.g. EXC_GUARD disable).
    public var isDev: Bool = false

    /// When true, apply the EXC_GUARD (Mach port guard) disable even on
    /// non-dev variants. Always required on iOS 18 bases: their older
    /// userland (runningboardd/SpringBoard) trips a Mach port guard
    /// "flavor 10" that crash-loops the UI. On other bases this is opt-in
    /// (see `FirmwarePipeline`'s `forceExcGuard`/`--force-exc-guard`): some
    /// third-party apps calling task_swap_exception_ports() (crash-reporting/
    /// RASP SDKs) can trip a GUARD_TYPE_MACH_PORT/KOBJECT_REPLY_PORT_SEMANTICS
    /// violation that the research kernel enforces fatally (upstream issue
    /// #291 / PR #297), but it's not required for the VM itself to boot.
    public var applyExcGuard: Bool = false

    public convenience init(data: Data, verbose: Bool = true, isDev: Bool, applyExcGuard: Bool = false) {
        self.init(data: data, verbose: verbose)
        self.isDev = isDev
        self.applyExcGuard = applyExcGuard
    }

    // MARK: - Setup (idempotent)

    /// Set once the heavyweight Mach-O parse + index build has run for this instance.
    private var didPrepare = false

    /// Idempotent heavyweight setup: parse the Mach-O, build the ADRP/BL indices, and
    /// locate `_panic`. Runs exactly once per instance (guarded by `didPrepare`), whether
    /// triggered by `findAll()` or by the first executed structured step.
    ///
    /// Kept out of `buildSteps()` so the ablation dry-run (`makePatcher(Data(), false)` →
    /// `buildSteps()` in `FirmwarePipeline.knownAblationTargets`) stays cheap and safe on
    /// an empty payload: `buildSteps()` only constructs `PatchStep`s and never parses. Each
    /// step's `run` closure calls this before running its patch body, so setup happens even
    /// if the first declared step is ablated. Order matches the former inline setup exactly.
    func ensurePrepared() {
        guard !didPrepare else { return }
        parseMachO()
        buildADRPIndex()
        buildBLIndex()
        findPanic()
        didPrepare = true
    }

    // MARK: - Find All

    public func findAll() throws -> [PatchRecord] {
        patches = []

        ensurePrepared()

        // Apply patches in order (matching Python find_all)
        patchApfsRootSnapshot() // 1
        patchApfsSealBroken() // 2
        patchBsdInitRootvp() // 3
        patchLaunchConstraints() // 4-5
        patchDebugger() // 6-7
        patchPostValidationNOP() // 8
        patchPostValidationCMP() // 9
        patchDyldPolicy() // 10-11
        patchApfsGraft() // 12
        patchApfsMount() // 13-15
        patchSandbox() // 16-25

        // EXC_GUARD (Mach port guard) disable — applied on the dev variant
        // always, and on regular/jb/exp via applyExcGuard (see its doc comment).
        if isDev || applyExcGuard {
            patchExcGuardBehavior() // 26
        }

        return patches
    }

    // MARK: - StructuredPatcher

    public func buildSteps() -> [PatchStep] {
        [
            step("patchApfsRootSnapshot", run: patchApfsRootSnapshot),
            step("patchApfsSealBroken", run: patchApfsSealBroken),
            step("patchBsdInitRootvp", run: patchBsdInitRootvp),
            step("patchLaunchConstraints", run: patchLaunchConstraints),
            step("patchDebugger", run: patchDebugger),
            step("patchPostValidationNOP", run: patchPostValidationNOP),
            rawStep("patchPostValidationCMP", run: patchPostValidationCMP),
            step("patchDyldPolicy", run: patchDyldPolicy),
            step("patchApfsGraft", run: patchApfsGraft),
            step("patchApfsMount", run: patchApfsMount),
            step("patchSandbox", run: patchSandbox),
            step("patchExcGuardBehavior", requirement: .conditional(.excGuardActive)) { [self] in
                guard isDev || applyExcGuard else { return false }
                return patchExcGuardBehavior()
            },
        ]
    }

    private func step(
        _ method: String, requirement: PatchRequirement = .required,
        run: @escaping () -> Bool
    ) -> PatchStep {
        PatchStep(id: PatchID(component: component, patcher: "KernelPatcher", method: method),
                  requirement: requirement) { [self] in
            ensurePrepared()
            let before = patches.count
            return structuredMethodResult(completed: run(), since: before)
        }
    }

    private func rawStep(
        _ method: String, run: @escaping () -> RawStepResult
    ) -> PatchStep {
        PatchStep(id: PatchID(component: component, patcher: "KernelPatcher", method: method),
                  requirement: .required) { [self] in
            ensurePrepared()
            let before = patches.count
            let result = run()
            let records = patches.dropFirst(before)
            if result == .matched, !records.isEmpty,
               records.allSatisfy({ $0.originalBytes == $0.patchedBytes }) {
                return .idempotent
            }
            return result
        }
    }

    @discardableResult
    public func apply() throws -> Int {
        let records = try (patches.isEmpty ? findAll() : patches)
        guard !records.isEmpty else {
            log("  [!] No kernel patches found")
            return 0
        }
        let count = applyPatches()
        log("\n  [\(count) kernel patches applied]")
        return count
    }
}
