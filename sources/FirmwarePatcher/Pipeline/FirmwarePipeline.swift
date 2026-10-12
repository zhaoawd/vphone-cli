// FirmwarePipeline.swift — Orchestrates full boot-chain firmware patching.
//
// Historical note: this file replaces the old Python firmware patcher implementation.
//
// Pipeline order: AVPBooter → iBSS → iBEC → LLB → TXM → Kernel → DeviceTree
//
// Variant selection (mirrors Makefile targets):
//   .regular — base patchers only
//   .dev     — TXMDevPatcher instead of TXMPatcher
//   .jb      — TXMDevPatcher + IBootJBPatcher (iBSS) + KernelJBPatcher
//   .exp     — JB + experimental: KernelEXPPatcher (hv_vmm rename) +
//              DeviceTreePatcher identity properties (D47AP/iPhone17,3).
//              Other variants are NOT affected by experimental patches.

import Darwin
import Foundation
import CryptoKit
import VPhoneCore

/// Orchestrates firmware patching for all boot-chain components.
///
/// The pipeline discovers firmware files inside the VM directory (mirroring
/// `find_restore_dir` + `find_file` in the Python source), loads each file,
/// delegates to the appropriate ``Patcher``, and writes the patched data back.
///
/// The default loader mirrors the Python flow: it loads IM4P containers when
/// present, patches the extracted payload, and re-packages them on save.
public final class FirmwarePipeline {
    // MARK: - Variant

    public enum Variant: String, Sendable {
        case less
        case regular
        case dev
        case jb
        case exp
    }

    // MARK: - Firmware Loader (pluggable IM4P support)

    /// Abstraction over IM4P vs raw firmware loading.
    ///
    /// Provide a conforming type to override the default IM4P/raw handling.
    public protocol FirmwareLoader {
        /// Load firmware from `url`, returning the mutable payload data.
        func load(from url: URL) throws -> Data
        /// Save patched `data` back to `url`, repackaging as needed.
        func save(_ data: Data, to url: URL) throws
    }

    /// Default loader: transparently handles IM4P containers and raw payloads.
    public struct ContainerFirmwareLoader: FirmwareLoader {
        public init() {}
        public func load(from url: URL) throws -> Data {
            try IM4PHandler.load(contentsOf: url).payload
        }

        public func save(_ data: Data, to url: URL) throws {
            let original = try IM4PHandler.load(contentsOf: url).im4p
            try IM4PHandler.save(patchedData: data, originalIM4P: original, to: url)
        }
    }

    // MARK: - Component Descriptor

    /// Describes a single firmware component in the pipeline.
    struct ComponentDescriptor {
        let name: String
        /// If true, search paths are relative to the Restore directory.
        /// If false, relative to the VM directory root.
        let inRestoreDir: Bool
        /// Glob patterns used to locate the file (tried in order).
        let searchPatterns: [String]
        /// Factories that create patchers to run in sequence for the loaded data.
        let patcherFactories: [(Data, Bool) -> any Patcher]
    }

    // MARK: - Properties

    let vmDirectory: URL
    let variant: Variant
    let verbose: Bool
    let noBinpack: Bool
    let noVphoned: Bool
    let forceExcGuard: Bool
    let enableFrida: Bool
    let experimentalV2RootRemount: Bool
    let generationID: String?
    let loader: any FirmwareLoader
    private var transaction: FirmwareTransaction?
    private var executionPlan: VariantPlanResolver.VariantPlan?
    private var versionInputs: FirmwareVersionInputs?
    private var baseVersionKnown = false

    /// Progress of the most recent run (C5). Shared with the staged pipeline so a
    /// failure keeps the stage, completed component reports and transaction.
    public internal(set) var trace = FirmwareRunTrace()

    /// Set when the iPhone base is iOS 18.x (read from iPhone-BuildManifest.plist).
    /// Gates the skywalk-netagent boot-arg workaround (18.x-specific mDNSResponder
    /// crash-loop). Computed in `patchAll()` before `buildComponentList()` runs.
    private var iosBaseIs18 = false

    /// Set when the iPhone base is iOS 27.x. Gates the iOS-27-only JB kernel patches
    /// (KernelJBPatcher.applyIOS27); false for 18.x/26.x so those bases are
    /// byte-identical to pre-branch. Computed in `patchAll()` alongside iosBaseIs18.
    private var iosBaseIs27 = false

    /// Set when the cloudOS kernel is 26.4+; gates the opt-in Frida kernel patches.
    private var cloudOSIsFridaCapable = false

    // MARK: - Init

    public init(
        vmDirectory: URL,
        variant: Variant = .regular,
        verbose: Bool = true,
        noBinpack: Bool = false,
        noVphoned: Bool = false,
        forceExcGuard: Bool = false,
        enableFrida: Bool = false,
        experimentalV2RootRemount: Bool = false,
        generationID: String? = nil,
        loader: (any FirmwareLoader)? = nil
    ) {
        self.vmDirectory = vmDirectory
        self.variant = variant
        self.verbose = verbose
        self.noBinpack = noBinpack
        self.noVphoned = noVphoned
        self.forceExcGuard = forceExcGuard
        self.enableFrida = enableFrida
        self.experimentalV2RootRemount = experimentalV2RootRemount
        self.generationID = generationID
        self.loader = loader ?? ContainerFirmwareLoader()
    }

    // MARK: - Pipeline Execution

    /// Run the full patching pipeline.
    ///
    /// Returns combined ``PatchRecord`` arrays from every component, in order.
    /// Throws on any required patch failure.
    ///
    /// Thin wrapper over ``patchAllStructured(ablate:allowOutput:)`` with no ablation
    /// so byte behavior is identical to the pre-C2 path; the structured report is
    /// discarded and only the flat records are returned.
    public func patchAll() throws -> [PatchRecord] {
        let report = try patchAllStructured(ablate: [], allowOutput: true)
        if !report.failedRequired.isEmpty {
            throw PatcherError.patchSiteNotFound(
                "required patches failed: "
                    + report.failedRequired.map(\.description).joined(separator: ", "))
        }
        return report.allRecords
    }

    /// Resolve the same gates and declarations used by the transaction preflight.
    public func resolvedPlan(select: Set<String> = [], block: Set<String> = []) throws -> VariantPlanResolver.VariantPlan {
        let (_, gates) = try prepare()
        return try VariantPlanResolver.resolve(variant: variant, gates: gates,
            baseVersionKnown: baseVersionKnown, cloudOSVersionKnown: versionInputs?.cloudOSVersion != nil, select: select, block: block)
    }

    /// The CLI adapter owns the bundle lock across observation, validation and publication.
    public func saveDesiredPlan(generationID: String, apply: Bool, expectedSHA256: String?,
                                importLegacy: Bool = false, expectedLegacySHA256: String? = nil,
                                select: [String] = [], block: [String] = []) throws -> FirmwareDesiredPlanStore.Prepared {
        try VPhoneBundleGuard.withBundleLock(directory: vmDirectory, operation: VPhoneVMOperation.fwPatch) { _ in
            guard !FirmwareTransaction.exists(vmDirectory.appendingPathComponent(".firmware-transaction")) else {
                throw PatcherError.invalidFormat("Pending firmware transaction; recover first")
            }
            try PatchSelectionMigration.validateExplicitInputs(select: select, block: block)
            if importLegacy, !select.isEmpty || !block.isEmpty {
                throw PatcherError.invalidFormat("Import legacy selection separately from explicit overrides")
            }
            var selected = Set(select), blocked = Set(block)
            if case .legacy(let legacy) = try FirmwareDesiredPlanStore.read(in: vmDirectory) {
                guard importLegacy else { throw PatcherError.invalidFormat("Legacy selection requires explicit --import-legacy") }
                if apply, legacy.sourceSHA256 != expectedLegacySHA256 { throw FirmwareDesiredPlanStore.Failure.changedSincePreview }
                selected = Set(legacy.selection.selected); blocked = Set(legacy.selection.blocked)
            } else if importLegacy { throw PatcherError.invalidFormat("No legacy selection to import") }
            let generation = try FirmwareGeneration.loadVerified(in: vmDirectory, id: generationID)
            let prepared = try FirmwareDesiredPlanStore.prepare(in: vmDirectory,
                plan: resolvedPlan(select: selected, block: blocked), generation: generation)
            if apply { _ = try FirmwareDesiredPlanStore.publish(prepared, expectedSHA256: expectedSHA256) }
            return prepared
        }
    }

    public static func readDesiredPlan(in directory: URL) throws -> FirmwareDesiredPlanStore.Read {
        try VPhoneBundleGuard.withBundleLock(directory: directory, operation: VPhoneVMOperation.fwPatch) { _ in
            try FirmwareDesiredPlanStore.read(in: directory)
        }
    }

    public static func readbackDesiredPlan(in directory: URL) throws -> FirmwareDesiredPlanStore.Read {
        try VPhoneBundleGuard.withBundleLock(directory: directory, operation: VPhoneVMOperation.fwPatch) { _ in
            try FirmwareDesiredPlanStore.readback(in: directory)
        }
    }

    /// Read manifests and compute the gate snapshot used for necessity rules.
    private func prepare() throws -> (restoreDir: URL, gates: PatchGateSnapshot) {
        if experimentalV2RootRemount, variant != .regular {
            throw PatcherError.invalidFormat("experimental v2 root remount requires variant regular")
        }
        let restoreDir = try findRestoreDirectory()
        if let plan = executionPlan {
            guard let versionInputs else {
                throw PatcherError.invalidFormat("Frozen plan has no version input snapshot")
            }
            try versionInputs.validate(in: restoreDir)
            // Staged execution consumes the preflight snapshot. Do not resolve again
            // from a manifest a filesystem/manifest patcher may subsequently rewrite.
            iosBaseIs18 = plan.gates.iosBaseIs18
            iosBaseIs27 = plan.gates.iosBaseIs27
            cloudOSIsFridaCapable = plan.gates.cloudOSIsFridaCapable
            log("[*] Frozen gates: \(plan.gates.summary)")
            return (restoreDir, plan.gates)
        }

        log("[*] VM directory:      \(vmDirectory.path)")
        log("[*] Restore directory: \(restoreDir.path)")

        // Detect the iPhone base iOS version (from the pre-hybrid manifest that
        // fw_prepare preserves — the live BuildManifest.plist reads the cloudOS
        // version, not the base). iOS 18 bases need the skywalk-netagent boot-arg.
        let inputs = try FirmwareVersionInputs.read(in: restoreDir)
        versionInputs = inputs
        let baseVersion = inputs.baseVersion
        baseVersionKnown = baseVersion != nil
        iosBaseIs18 = FirmwareVersionInputs.components(baseVersion)?.first == 18
        iosBaseIs27 = FirmwareVersionInputs.components(baseVersion)?.first == 27
        let baseGateNote = iosBaseIs18 ? "  (enabling iOS-18 netagent boot-arg)"
            : iosBaseIs27 ? "  (enabling iOS-27 JB kernel patches)" : ""
        log("[*] iPhone base iOS:   \(baseVersion ?? "unknown")\(baseGateNote)")

        // Frida Stalker kernel patches only apply on cloudOS 26.4+ (where the shapes
        // were validated); older kernels are left untouched. The Frida deb install is
        // separate and version-independent.
        let cloudOSVersion = inputs.cloudOSVersion
        cloudOSIsFridaCapable = Self.productVersionAtLeast(cloudOSVersion, 26, 4)
        if enableFrida {
            log("[*] cloudOS kernel:    \(cloudOSVersion ?? "unknown")"
                + (cloudOSIsFridaCapable ? "  (Frida kernel patches enabled)"
                    : "  (< 26.4 — Frida kernel patches skipped)"))
        }

        return (restoreDir, gateSnapshot)
    }

    /// Uses the same activation conditions as the component factories.
    var gateSnapshot: PatchGateSnapshot {
        PatchGateSnapshot(
            variant: variant.rawValue,
            iosBaseIs18: iosBaseIs18,
            iosBaseIs27: iosBaseIs27,
            cloudOSIsFridaCapable: cloudOSIsFridaCapable,
            forceExcGuard: forceExcGuard,
            enableFrida: enableFrida,
            excGuardActive: variant == .dev || iosBaseIs18 || forceExcGuard,
            applyIOS27: iosBaseIs27,
            applyFrida: enableFrida && cloudOSIsFridaCapable,
            experimentalV2RootRemount: experimentalV2RootRemount
        )
    }

    /// Run the full pipeline and return a structured ``PatchRunReport``.
    ///
    /// - `ablate`: component / patcher / full-id values to disable (see ``PatchID``).
    ///   Each value is intercepted before its step runs, so no bytes are written for
    ///   an ablated step. Unknown values throw before any component is loaded.
    /// - `allowOutput`: when false (the default for an ablation run), patched firmware
    ///   is NOT written back — the report is still produced. A non-ablation run always
    ///   requests publication. Publication still requires every selected required declaration
    ///   to have verified execution evidence; ablation does not waive this gate.
    ///
    /// This method does not throw on required failures; callers inspect
    /// ``PatchRunReport/failedRequired``. It throws only on hard I/O / format errors
    /// (missing files, unreadable payloads, unknown ablation ids) and declaration-gate violations.
    public func patchAllStructured(ablate ablateValues: [String] = [], allowOutput: Bool = true) throws -> PatchRunReport {
        trace = FirmwareRunTrace()
        executionPlan = nil
        versionInputs = nil
        trace.stage = .preflight
        guard !FirmwareTransaction.exists(vmDirectory.appendingPathComponent(".firmware-transaction")) else {
            throw PatcherError.invalidFormat("Pending firmware transaction; run patch-firmware --recover first")
        }
        // Neither a journal nor its archived plan grants a fresh execution.
        let desired = try FirmwareDesiredPlanStore.read(in: vmDirectory)
        let bound: FirmwareDesiredPlanStore.Record?
        if case .ready(let record) = desired { bound = record } else { bound = nil }
        let ablate = Set(ablateValues)
        let unknown = ablate.subtracting(knownAblationTargets(buildComponentList()))
        guard unknown.isEmpty else {
            throw PatcherError.invalidFormat("unknown ablation id(s): \(unknown.sorted().joined(separator: ", "))")
        }
        if !ablate.isEmpty && !allowOutput {
            let report = try executeStructured(ablate: ablateValues, allowOutput: false)
            trace.stage = .finished
            return report
        }
        guard let bound else { throw FirmwareDesiredPlanStore.Failure.missing }
        if let generationID, generationID != bound.generationID { throw FirmwareDesiredPlanStore.Failure.identityMismatch }
        trace.stage = .prepare
        let (_, gates) = try prepare()
        let plan = try VariantPlanResolver.resolve(
            variant: variant, gates: gates, baseVersionKnown: baseVersionKnown,
            cloudOSVersionKnown: versionInputs?.cloudOSVersion != nil,
            block: Set(bound.plan.excludedByOptIn.filter { $0.reason == "blocked by request" }.map(\.id)))
        // Every variant's iBEC/LLB boot arguments depend on the iPhone base,
        // even when EXC_GUARD activation is independently known (dev/forced).
        guard baseVersionKnown else {
            throw PatcherError.invalidFormat("iPhone base version is unknown; boot argument parameters cannot be resolved")
        }
        guard plan == bound.plan else { throw FirmwareDesiredPlanStore.Failure.invalidPlan }
        executionPlan = plan
        let roots = try transactionRoots()
        trace.stage = .stageInputs
        var transactionOptions = [
            "variant": variant.rawValue, "noBinpack": String(noBinpack), "noVphoned": String(noVphoned),
            "forceExcGuard": String(forceExcGuard), "frida": String(enableFrida),
            "ablate": ablateValues.joined(separator: ","),
        ]
        if experimentalV2RootRemount { transactionOptions["experimentalV2RootRemount"] = "true" }
        transactionOptions["generationID"] = bound.generationID
        transactionOptions["desiredSHA256"] = try bound.sha256
        let transaction = try FirmwareTransaction(vmDirectory: vmDirectory, inputs: roots,
            options: transactionOptions, plan: plan, versionInputs: versionInputs)
        trace.transaction = transaction
        do {
            let staged = FirmwarePipeline(vmDirectory: transaction.stage, variant: variant, verbose: verbose,
                noBinpack: noBinpack, noVphoned: noVphoned, forceExcGuard: forceExcGuard,
                enableFrida: enableFrida, experimentalV2RootRemount: experimentalV2RootRemount, loader: loader)
            staged.transaction = transaction
            staged.executionPlan = plan
            staged.versionInputs = versionInputs
            staged.trace = trace
            if variant == .less {
                let restore = try staged.findRestoreDirectory()
                try Self.validateManifestPaths(in: restore, name: "BuildManifest.plist")
                try Self.validateManifestPaths(in: restore, name: "iPhone-BuildManifest.plist")
            }
            let report = try staged.executeStructured(ablate: ablateValues, allowOutput: allowOutput)
            try transaction.saveReport(report)
            guard report.failedRequired.isEmpty else {
                transaction.recordFailure(PatcherError.patchSiteNotFound("Required patch failed; original firmware was not changed"))
                return report
            }
            trace.stage = .validateOutput
            trace.component = nil
            // Strict declaration gate (T11): every committed record must belong to a
            // declaration this variant enables. Runs on the staged output before commit,
            // so a violation leaves the original firmware untouched (the transaction
            // records the failure like any other pre-commit error).
            try PatchDeclarationGate.enforce(report: report, plan: plan)
            if variant == .less { try Self.validateManifest(in: staged.findRestoreDirectory()) }
            trace.stage = .commit
            let archive = try transaction.commit()
            log("[+] Firmware transaction committed; receipt and backups: \(archive.path)")
            trace.stage = .finished
            return report
        } catch {
            transaction.recordFailure(error)
            throw error
        }
    }

    /// The transaction roots: VM-root component files plus the Restore directory.
    func transactionRoots() throws -> [URL] {
        let restore = try findRestoreDirectory()
        let rootInputs = try buildComponentList().filter { !$0.inRestoreDir }.map {
            try findFile(in: vmDirectory, patterns: $0.searchPatterns, label: $0.name)
        }
        return rootInputs + [restore]
    }

    /// Call while holding the VM bundle lock. Recovery does not run patchers.
    public static func recoverFirmware(in vmDirectory: URL) throws -> URL? {
        try FirmwareTransaction.recover(vmDirectory: vmDirectory)
    }

    static func validateManifest(in restore: URL) throws {
        let bytes = try Data(contentsOf: restore.appendingPathComponent("BuildManifest.plist"))
        guard let root = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              let identities = root["BuildIdentities"] as? [[String: Any]], identities.count == 1,
              let manifest = identities[0]["Manifest"] as? [String: [String: Any]] else {
            throw PatcherError.invalidFormat("Invalid staged Manifest")
        }
        for (name, component) in manifest {
            guard let info = component["Info"] as? [String: Any], let path = info["Path"] as? String,
                  !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                  let expected = component["Digest"] as? Data else {
                throw PatcherError.invalidFormat("Invalid staged Manifest component: \(name)")
            }
            let file = restore.appendingPathComponent(path)
            guard file.resolvingSymlinksInPath().path.hasPrefix(restore.resolvingSymlinksInPath().path + "/") else {
                throw PatcherError.invalidFormat("Manifest path escapes staged restore: \(name)")
            }
            let actual: Data
            if manifestRetypedIM4PComponents.contains(name) {
                let bytes = try Data(contentsOf: file)
                let retyped = try patchIm4pTypeTag(name, info["Img4PayloadType"] as? String, bytes)
                actual = Data(SHA384.hash(data: retyped))
            } else {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                var hash = SHA384()
                while try autoreleasepool(invoking: {
                    guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
                    hash.update(data: data)
                    return true
                }) {}
                actual = Data(hash.finalize())
            }
            guard actual == expected else {
                throw PatcherError.patchVerificationFailed("Staged Manifest digest mismatch: \(name)")
            }
        }
    }

    private static func validateManifestPaths(in restore: URL, name: String) throws {
        let bytes = try Data(contentsOf: restore.appendingPathComponent(name))
        guard let root = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              let identities = root["BuildIdentities"] as? [[String: Any]], !identities.isEmpty else {
            throw PatcherError.invalidFormat("Invalid staged input Manifest: \(name)")
        }
        for identity in identities {
            guard let manifest = identity["Manifest"] as? [String: [String: Any]] else {
                throw PatcherError.invalidFormat("Missing input Manifest components: \(name)")
            }
            for component in manifest.values {
                // Some original identities contain non-file entries (rfta/rfts).
                // Only file references can escape the staged input tree.
                guard let info = component["Info"] as? [String: Any], info["Path"] != nil else { continue }
                guard let path = info["Path"] as? String,
                      !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                    throw PatcherError.invalidFormat("Input Manifest contains a path outside staged restore: \(name)")
                }
            }
        }
    }

    private func executeStructured(ablate ablateValues: [String], allowOutput: Bool) throws -> PatchRunReport {
        // Validate ablation ids up front — before any component is loaded — so a
        // mistyped id fails fast instead of silently running as an unablated success.
        // The declared step-id set is gate-independent, so it is computed here without
        // reading the manifests.
        let ablate = Set(ablateValues)
        if !ablate.isEmpty {
            let known = knownAblationTargets(buildComponentList())
            let unknown = ablate.filter { !known.contains($0) }.sorted()
            if !unknown.isEmpty {
                throw PatcherError.invalidFormat(
                    "unknown ablation id(s): \(unknown.joined(separator: ", ")); "
                        + "known: \(known.sorted().joined(separator: ", "))")
            }
        }

        // Dry runs do not create a transaction. Filesystem operations require a
        // staged output run, so a dry run must ablate this entire operation.
        if variant == .less, !ablate.isEmpty, !allowOutput,
           !StructuredExecution.isAblated(CryptexFilesystemPatcher.stepID, ablate) {
            throw PatcherError.invalidFormat("less dry-run requires --ablate filesystem; filesystem operations require a staged output run")
        }

        trace.stage = .prepare
        let (restoreDir, gates) = try prepare()
        trace.gates = gates
        let components = buildComponentList()
        trace.plannedComponents = components.map(\.name)

        let isDry = !ablate.isEmpty && !allowOutput
        log("[*] Patching \(components.count) boot-chain components ..."
            + (isDry ? "  (ABLATION dry-run: firmware NOT written)" : ""))

        var componentReports: [ComponentReport] = []

        for component in components {
            trace.stage = .patch
            trace.component = component.name
            let baseDir = component.inRestoreDir ? restoreDir : vmDirectory
            let fileURL = try findFile(in: baseDir, patterns: component.searchPatterns, label: component.name)

            log("\n\(String(repeating: "=", count: 60))")
            log("  \(component.name): \(fileURL.path)")
            log(String(repeating: "=", count: 60))

            let rawData = try loader.load(from: fileURL)
            log("  format: \(rawData.count) bytes")

            let (currentData, reports) = try patchDataStructured(
                rawData,
                componentName: component.name,
                patcherFactories: component.patcherFactories,
                gates: gates,
                ablate: ablate,
                enabledSteps: executionPlan?.enabledStepIDs
            )
            componentReports.append(contentsOf: reports)
            logStructuredReports(reports)

            let componentFailed = reports.contains { $0.hasRequiredFailure }
            if componentFailed {
                trace.record(component.name, reports)
                log("  [x] required failure — not saved; stopping before dependent components")
                break
            } else if isDry {
                log("  [.] ablation dry-run — not saved")
            } else {
                try loader.save(currentData, to: fileURL)
                log("  [+] saved")
            }
            trace.record(component.name, reports)
        }

        let report = Self.makeReport(variant: variant.rawValue, gates: gates, components: componentReports)
        let ablatedIDs = report.ablation

        log("\n\(String(repeating: "=", count: 60))")
        if report.failedRequired.isEmpty {
            log("  \(components.count) components processed"
                + (report.isAblationRun ? " (ablation run: \(ablatedIDs.count) step(s) ablated)" : "")
                + " (\(report.allRecords.count) total patches)")
        } else {
            log("  REQUIRED FAILURES: \(report.failedRequired.map(\.description).joined(separator: ", "))")
        }
        log(String(repeating: "=", count: 60))

        return report
    }

    /// Builds the run report; the ablation list is every ablated result in order.
    static func makeReport(variant: String, gates: PatchGateSnapshot, components: [ComponentReport]) -> PatchRunReport {
        let ablatedIDs = components.flatMap { $0.results }.filter { $0.outcome == .ablated }.map { $0.id }
        return PatchRunReport(variant: variant, gates: gates, components: components, ablation: ablatedIDs)
    }

    /// Emit the stable structured log lines for one component's reports.
    private func logStructuredReports(_ reports: [ComponentReport]) {
        guard verbose else { return }
        for report in reports where report.coverage == .legacy {
            let result = report.results.first
            let mark = switch result?.outcome {
            case .ablated: "[A]"
            case .failed: "[x]"
            default: "[L]"
            }
            print("  \(mark) \(report.component) (legacy)  \(result?.outcome.rawValue ?? "n/a")  (\(report.records.count) records)")
        }
        for report in reports where report.coverage == .structured {
            for result in report.results {
                let mark = switch result.outcome {
                case .applied, .alreadyApplied: "[=]"
                case .notApplicable: "[~]"
                case .failed: "[x]"
                case .ablated: "[A]"
                }
                let detail = result.reason.map { "  \($0)" } ?? "  (\(result.recordIndices.count) records)"
                print("  \(mark) \(result.id)  \(result.outcome.rawValue)\(detail)")
            }
        }
    }

    /// Build the set of valid ablation targets (component / patcher / full-id) for the
    /// current variant + gates, so unknown `--ablate` values can be rejected up front.
    func knownAblationTargets(_ components: [ComponentDescriptor]) -> Set<String> {
        var targets = Set<String>()
        for component in components {
            let canonical = component.name.lowercased()
            targets.insert(canonical)
            // These factories need a real restore directory; enumerate their static
            // operation IDs without instantiating a patcher or touching the disk.
            if component.name == "Filesystem" || component.name == "Manifest" {
                if !component.patcherFactories.isEmpty {
                    let id = component.name == "Filesystem" ? CryptexFilesystemPatcher.stepID : ManifestHashPatcher.stepID
                    targets.insert(id.patcherTarget)
                    targets.insert(id.description)
                }
                continue
            }
            for makePatcher in component.patcherFactories {
                let patcher = makePatcher(Data(), false)
                targets.insert("\(canonical).\(String(describing: type(of: patcher)))")
                if let structured = patcher as? any StructuredPatcher {
                    for step in structured.buildSteps() {
                        targets.insert(step.id.componentTarget)
                        targets.insert(step.id.patcherTarget)
                        targets.insert(step.id.description)
                    }
                }
            }
        }
        return targets
    }

    func patchData(
        _ rawData: Data,
        componentName: String,
        patcherFactories: [(Data, Bool) -> any Patcher]
    ) throws -> (Data, [PatchRecord]) {
        var currentData = rawData
        var componentRecords: [PatchRecord] = []

        for makePatcher in patcherFactories {
            let patcher = makePatcher(currentData, verbose)
            let records = try patcher.findAll()

            guard !records.isEmpty else {
                throw PatcherError.patchSiteNotFound("\(componentName): no patches found")
            }

            let count = try patcher.apply()
            log("  [+] \(count) \(componentName) patches applied")

            componentRecords.append(contentsOf: records)
            currentData = extractPatchedData(from: patcher, fallback: currentData, records: records)
        }

        return (currentData, componentRecords)
    }

    /// Structured counterpart of ``patchData(_:componentName:patcherFactories:)``.
    ///
    /// Runs each patcher factory against the chained data. A ``StructuredPatcher`` runs
    /// its declared steps (honoring `ablate`); any other patcher is wrapped by
    /// ``LegacyPatcherAdapter`` (preserving the "no patches found ⇒ failed" semantics).
    /// Produces one ``ComponentReport`` per patcher factory.
    func patchDataStructured(
        _ rawData: Data,
        componentName: String,
        patcherFactories: [(Data, Bool) -> any Patcher],
        gates: PatchGateSnapshot,
        ablate: Set<String>,
        enabledSteps: Set<String>? = nil
    ) throws -> (Data, [ComponentReport]) {
        var currentData = rawData
        var reports: [ComponentReport] = []

        for makePatcher in patcherFactories {
            let patcher = makePatcher(currentData, verbose)
            let input = currentData
            if let structured = patcher as? any StructuredPatcher {
                let (report, data) = StructuredExecution.run(
                    patcher: structured,
                    componentName: componentName,
                    gates: gates,
                    ablate: ablate,
                    fallback: input,
                    enabledSteps: enabledSteps
                )
                reports.append(report)
                currentData = data
            } else {
                let (report, data) = try LegacyPatcherAdapter.run(
                    patcher: patcher,
                    componentName: componentName,
                    gates: gates,
                    ablate: ablate,
                    fallback: input,
                    extract: { p, recs in self.extractPatchedData(from: p, fallback: input, records: recs) }
                )
                reports.append(report)
                currentData = data
            }
        }

        return (currentData, reports)
    }

    // MARK: - Component List Builder

    /// Build the ordered component list based on the variant.
    func buildComponentList() -> [ComponentDescriptor] {
        var components: [ComponentDescriptor] = []

        // Captured by value into the patcher factory closures below (avoids
        // capturing self). Always on for iOS 18 bases: 18.6.2's runningboardd/
        // SpringBoard trips GUARD_TYPE_MACH_PORT flavor 10, crash-looping the
        // UI, and the VM won't boot without this patch there. Otherwise off by
        // default and opt-in via `forceExcGuard` (--force-exc-guard):
        // some third-party apps shipping crash-reporting/RASP SDKs call
        // task_swap_exception_ports(), which the research kernel can enforce
        // as a fatal EXC_GUARD/GUARD_TYPE_MACH_PORT/KOBJECT_REPLY_PORT_SEMANTICS
        // violation (see upstream issue #291 / PR #297) — but this isn't
        // required for the VM itself to boot on 26.x, so it stays opt-in
        // rather than always-on for regular/jb/exp.
        let applyExcGuard = iosBaseIs18 || forceExcGuard

        // Same capture-by-value; true only for iOS 27 bases. Gates the iOS-27-only
        // JB kernel patches so 18.x/26.x bases apply none of them.
        let applyIOS27 = iosBaseIs27

        // Opt-in Frida Stalker kernel relaxations (--frida), gated to cloudOS 26.4+.
        let applyFrida = enableFrida && cloudOSIsFridaCapable
        let experimentalV2RootRemount = experimentalV2RootRemount

        // iOS 18 bases: disable the skywalk flowswitch netagents via boot-arg so
        // Network.framework uses the BSD path (the 26.1-kernel skywalk
        // channel-create traps in the 18.x Network.framework and crash-loops
        // mDNSResponder → no DNS). Empty on 26.x bases (stock boot-args).
        let extraBootArgs = iosBaseIs18 ? "if_attach_nx=0x3" : ""

        // 1. AVPBooter — always present, lives in VM root.
        //    Patched for every non-less variant (regular/dev/jb/exp).
        components.append(ComponentDescriptor(
            name: "AVPBooter",
            inRestoreDir: false,
            searchPatterns: ["AVPBooter*.bin"],
            patcherFactories: {
                if variant != .less {
                    return [
                        { data, verbose in
                            AVPBooterPatcher(data: data, verbose: verbose)
                        },
                    ]
                }
                return []
            }()
        ))

        // 2. iBSS — JB and EXP variants run the base iBSS patcher, then the nonce-skip extension.
        components.append(ComponentDescriptor(
            name: "iBSS",
            inRestoreDir: true,
            searchPatterns: ["Firmware/dfu/iBSS.vresearch101.RELEASE.im4p"],
            patcherFactories: {
                return switch variant {
                case .less:
                    []
                case .regular, .dev:
                    [{ data, verbose in
                        IBootPatcher(data: data, mode: .ibss, verbose: verbose)
                    }]
                case .jb, .exp:
                    [
                        { data, verbose in
                            IBootPatcher(data: data, mode: .ibss, verbose: verbose)
                        },
                        { data, verbose in
                            IBootJBPatcher(data: data, mode: .ibss, verbose: verbose)
                        },
                    ]
                }
            }()
        ))

        // 3. iBEC - Not required by the less variant, still added for the serial logs.
        components.append(ComponentDescriptor(
            name: "iBEC",
            inRestoreDir: true,
            searchPatterns: ["Firmware/dfu/iBEC.vresearch101.RELEASE.im4p"],
            patcherFactories: [{ data, verbose in
                let p = IBootPatcher(data: data, mode: .ibec, verbose: verbose)
                p.extraBootArgs = extraBootArgs
                return p
            }]
        ))

        // 4. LLB - Not required by the less variant, still added for the serial logs.
        components.append(ComponentDescriptor(
            name: "LLB",
            inRestoreDir: true,
            searchPatterns: ["Firmware/all_flash/LLB.vresearch101.RELEASE.im4p"],
            patcherFactories: [{ data, verbose in
                let p = IBootPatcher(data: data, mode: .llb, verbose: verbose)
                p.extraBootArgs = extraBootArgs
                return p
            }]
        ))

        // 5. TXM — dev/jb/exp variants use TXMDevPatcher (adds entitlements, debugger, dev-mode)
        components.append(ComponentDescriptor(
            name: "TXM",
            inRestoreDir: true,
            searchPatterns: ["Firmware/txm.iphoneos.research.im4p"],
            patcherFactories: {
                return switch variant {
                case .less:
                    []
                case .regular:
                    [{ data, verbose in
                        TXMPatcher(data: data, verbose: verbose)
                    }]
                case .dev, .jb, .exp:
                    [{ data, verbose in
                        TXMDevPatcher(data: data, verbose: verbose)
                    }]
                }
            }()
        ))

        // 6. Kernel — JB variant runs base kernel patches first, then JB extensions.
        //    EXP variant runs base + JB + experimental extensions (hv_vmm rename).
        components.append(ComponentDescriptor(
            name: "kernelcache",
            inRestoreDir: true,
            searchPatterns: ["kernelcache.research.vphone600"],
            patcherFactories: {
                return switch variant {
                case .less:
                    []
                case .regular:
                    { () -> [(Data, Bool) -> any Patcher] in
                        var factories: [(Data, Bool) -> any Patcher] = [{ data, verbose in
                            KernelPatcher(data: data, verbose: verbose, isDev: false, applyExcGuard: applyExcGuard)
                        }]
                        if experimentalV2RootRemount {
                            factories.append { data, verbose in
                                let patcher = KernelJBPatcher(data: data, verbose: verbose)
                                patcher.mountOnly = true
                                return patcher
                            }
                        }
                        return factories
                    }()
                case .dev:
                    [{ data, verbose in
                        KernelPatcher(data: data, verbose: verbose, isDev: true)
                    }]
                case .jb:
                    [
                        { data, verbose in
                            KernelPatcher(data: data, verbose: verbose, isDev: false, applyExcGuard: applyExcGuard)
                        },
                        { data, verbose in
                            let p = KernelJBPatcher(data: data, verbose: verbose)
                            p.applyIOS27 = applyIOS27
                            p.applyFrida = applyFrida
                            return p
                        },
                    ]
                case .exp:
                    [
                        { data, verbose in
                            KernelPatcher(data: data, verbose: verbose, isDev: false, applyExcGuard: applyExcGuard)
                        },
                        { data, verbose in
                            let p = KernelJBPatcher(data: data, verbose: verbose)
                            p.applyIOS27 = applyIOS27
                            p.applyFrida = applyFrida
                            return p
                        },
                        { data, verbose in
                            KernelEXPPatcher(data: data, verbose: verbose)
                        },
                    ]
                }
            }()
        ))

        // 7. DeviceTree — base property patches for every variant. EXP additionally
        //    applies the 8 identity-rewrite properties (Tier 1b + 1c) that flip the
        //    device's userland-visible identity toward D47AP / iPhone17,3.
        let dtIncludeIdentity = variant == .exp
        components.append(ComponentDescriptor(
            name: "DeviceTree",
            inRestoreDir: true,
            searchPatterns: ["Firmware/all_flash/DeviceTree.vphone600ap.im4p"],
            patcherFactories: [{ data, verbose in
                DeviceTreePatcher(
                    data: data,
                    verbose: verbose,
                    includeIdentityPatches: dtIncludeIdentity
                )
            }]
        ))
        
        // 8. Filesystem
        components.append(ComponentDescriptor(
            name: "Filesystem",
            inRestoreDir: true,
            searchPatterns: ["BuildManifest.plist"],
            patcherFactories: {
                return switch variant {
                case .less:
                    [{ data, verbose in
                        let patcher = CryptexFilesystemPatcher(buildManiest: data, restoreDir: try! self.findRestoreDirectory(), verbose: verbose, noBinpack: self.noBinpack, noVphoned: self.noVphoned)
                        patcher.transaction = self.transaction
                        return patcher
                    }]
                case .regular, .dev, .jb, .exp:
                    []
                }
            }()
        ))

        // 9. Firmware Manifest - Only required when excluding the img4 signature patches.
        components.append(ComponentDescriptor(
            name: "Manifest",
            inRestoreDir: true,
            searchPatterns: ["BuildManifest.plist"],
            patcherFactories: {
                return switch variant {
                case .less:
                    [{ data, verbose in
                        ManifestHashPatcher(data: data, restoreDir: try? self.findRestoreDirectory(), verbose: verbose)
                    }]
                case .regular, .dev, .jb, .exp:
                    []
                }
            }()
        ))

        return components
    }

    // MARK: - File Discovery

    /// Find the `*Restore*` subdirectory inside the VM directory.
    /// Mirrors Python `find_restore_dir`.
    func findRestoreDirectory() throws -> URL {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(
            at: vmDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
        )
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        .filter { $0.lastPathComponent.contains("Restore") }
        .sorted(by: compareRestoreDirectories)

        guard let restoreDir = contents.first else {
            throw PatcherError.fileNotFound("No *Restore* directory found in \(vmDirectory.path). Run prepare_firmware first.")
        }
        return restoreDir
    }

    /// `ProductVersion` from a manifest in `restoreDir`, or nil if absent/unreadable.
    static func readProductVersion(_ restoreDir: URL, manifest: String) -> String? {
        readManifestString(restoreDir, manifest: manifest, key: "ProductVersion")
    }

    /// A top-level string from a manifest in `restoreDir`, or nil if absent/unreadable.
    static func readManifestString(_ restoreDir: URL, manifest: String, key: String) -> String? {
        let url = restoreDir.appendingPathComponent(manifest)
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let value = dict[key] as? String
        else { return nil }
        return value
    }

    /// iPhone base version (`iPhone-BuildManifest.plist`, preserved by fw_prepare).
    static func readBaseProductVersion(_ restoreDir: URL) -> String? {
        readProductVersion(restoreDir, manifest: "iPhone-BuildManifest.plist")
    }

    /// cloudOS/kernel version (the live `BuildManifest.plist`).
    static func readCloudOSProductVersion(_ restoreDir: URL) -> String? {
        readProductVersion(restoreDir, manifest: "BuildManifest.plist")
    }

    /// Dotted `ProductVersion` >= major.minor, compared numerically. nil is false.
    static func productVersionAtLeast(_ version: String?, _ major: Int, _ minor: Int) -> Bool {
        guard let parts = FirmwareVersionInputs.components(version),
              let vMajor = parts.first else { return false }
        return vMajor != major ? vMajor > major : (parts.count > 1 ? parts[1] : 0) >= minor
    }

    private func compareRestoreDirectories(_ lhs: URL, _ rhs: URL) -> Bool {
        let leftName = lhs.lastPathComponent
        let rightName = rhs.lastPathComponent

        if let left = parseRestoreDirectoryName(leftName),
           let right = parseRestoreDirectoryName(rightName)
        {
            if left.version != right.version {
                return left.version.lexicographicallyPrecedes(right.version, by: >)
            }
            if left.build != right.build {
                return left.build.compare(right.build, options: .numeric) == .orderedDescending
            }
        }

        let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if leftDate != rightDate {
            return leftDate > rightDate
        }
        return leftName > rightName
    }

    private func parseRestoreDirectoryName(_ name: String) -> (version: [Int], build: String)? {
        let pattern = #"_([0-9]+(?:\.[0-9]+)*)_([0-9A-Za-z]+)_Restore$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(name.startIndex..., in: name)
        guard let match = regex.firstMatch(in: name, range: range),
              match.numberOfRanges == 3,
              let versionRange = Range(match.range(at: 1), in: name),
              let buildRange = Range(match.range(at: 2), in: name)
        else { return nil }

        let version = name[versionRange]
            .split(separator: ".")
            .compactMap { Int($0) }
        let build = String(name[buildRange])
        guard !version.isEmpty else { return nil }
        return (version, build)
    }

    /// Find a firmware file by trying glob-style patterns under `baseDir`.
    /// Mirrors Python `find_file`.
    func findFile(in baseDir: URL, patterns: [String], label: String) throws -> URL {
        let fm = FileManager.default
        for pattern in patterns {
            if pattern.contains("*") || pattern.contains("?") || pattern.contains("[") {
                var matches: [URL] = []
                if !pattern.contains("/") {
                    let urls = try fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: [.isRegularFileKey])
                    for url in urls where fnmatch(pattern, url.lastPathComponent, 0) == 0 {
                        matches.append(url)
                    }
                } else {
                    let enumerator = fm.enumerator(at: baseDir, includingPropertiesForKeys: [.isRegularFileKey])
                    while let url = enumerator?.nextObject() as? URL {
                        guard url.path.hasPrefix(baseDir.path + "/") else { continue }
                        let rel = String(url.path.dropFirst(baseDir.path.count + 1))
                        if fnmatch(pattern, rel, 0) == 0 {
                            matches.append(url)
                        }
                    }
                }
                if let first = matches.sorted(by: { $0.path < $1.path }).first {
                    return first
                }
            } else {
                let candidate = baseDir.appendingPathComponent(pattern)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        let searched = patterns.map { baseDir.appendingPathComponent($0).path }.joined(separator: "\n    ")
        throw PatcherError.fileNotFound("\(label) not found. Searched:\n    \(searched)")
    }

    // MARK: - Data Extraction

    /// Extract the patched data from a patcher's internal buffer.
    ///
    /// All current patchers own a ``BinaryBuffer`` whose `.data` property
    /// holds the mutated bytes after `apply()`. We use protocol-based
    /// access where possible and fall back to manual patch application.
    func extractPatchedData(from patcher: any Patcher, fallback: Data, records: [PatchRecord]) -> Data {
        // Try known patcher types that expose their buffer.
        if let avp = patcher as? AVPBooterPatcher { return avp.buffer.data }
        if let iboot = patcher as? IBootPatcher { return iboot.buffer.data }
        if let txm = patcher as? TXMPatcher { return txm.buffer.data }
        if let kp = patcher as? KernelPatcher { return kp.buffer.data }
        if let kjb = patcher as? KernelJBPatcher { return kjb.buffer.data }
        if let kexp = patcher as? KernelEXPPatcher { return kexp.buffer.data }
        if let dt = patcher as? DeviceTreePatcher { return dt.patchedData }
        if let filesystem = patcher as? CryptexFilesystemPatcher { return filesystem.patchedData }
        if let manifest = patcher as? ManifestHashPatcher { return manifest.patchedData }

        // Fallback: apply records manually to a copy of the original data.
        var data = fallback
        for record in records {
            let range = record.fileOffset ..< record.fileOffset + record.patchedBytes.count
            data.replaceSubrange(range, with: record.patchedBytes)
        }
        return data
    }

    // MARK: - Logging

    func log(_ message: String) {
        if verbose {
            print(message)
        }
    }
}
