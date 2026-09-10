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
    let loader: any FirmwareLoader

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
        loader: (any FirmwareLoader)? = nil
    ) {
        self.vmDirectory = vmDirectory
        self.variant = variant
        self.verbose = verbose
        self.noBinpack = noBinpack
        self.noVphoned = noVphoned
        self.forceExcGuard = forceExcGuard
        self.enableFrida = enableFrida
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

    /// Read the manifests, set the gate flags, log the run header, and return the
    /// restore directory plus the gate snapshot used for necessity-rule evaluation.
    private func prepare() throws -> (restoreDir: URL, gates: PatchGateSnapshot) {
        let restoreDir = try findRestoreDirectory()

        log("[*] VM directory:      \(vmDirectory.path)")
        log("[*] Restore directory: \(restoreDir.path)")

        // Detect the iPhone base iOS version (from the pre-hybrid manifest that
        // fw_prepare preserves — the live BuildManifest.plist reads the cloudOS
        // version, not the base). iOS 18 bases need the skywalk-netagent boot-arg.
        let baseVersion = Self.readBaseProductVersion(restoreDir)
        iosBaseIs18 = baseVersion?.hasPrefix("18.") ?? false
        iosBaseIs27 = baseVersion?.hasPrefix("27.") ?? false
        let baseGateNote = iosBaseIs18 ? "  (enabling iOS-18 netagent boot-arg)"
            : iosBaseIs27 ? "  (enabling iOS-27 JB kernel patches)" : ""
        log("[*] iPhone base iOS:   \(baseVersion ?? "unknown")\(baseGateNote)")

        // Frida Stalker kernel patches only apply on cloudOS 26.4+ (where the shapes
        // were validated); older kernels are left untouched. The Frida deb install is
        // separate and version-independent.
        let cloudOSVersion = Self.readCloudOSProductVersion(restoreDir)
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
            applyFrida: enableFrida && cloudOSIsFridaCapable
        )
    }

    /// Run the full pipeline and return a structured ``PatchRunReport``.
    ///
    /// - `ablate`: component / patcher / full-id values to disable (see ``PatchID``).
    ///   Each value is intercepted before its step runs, so no bytes are written for
    ///   an ablated step. Unknown values throw before any component is loaded.
    /// - `allowOutput`: when false (the default for an ablation run), patched firmware
    ///   is NOT written back — the report is still produced. A non-ablation run always
    ///   writes.
    ///
    /// This method does not throw on required failures; callers inspect
    /// ``PatchRunReport/failedRequired``. It throws only on hard I/O / format errors
    /// (missing files, unreadable payloads, unknown ablation ids).
    public func patchAllStructured(ablate ablateValues: [String] = [], allowOutput: Bool = true) throws -> PatchRunReport {
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

        // The less filesystem step writes external artifacts. Until C4 provides
        // staging, a dry run must explicitly ablate this entire operation.
        if variant == .less, !ablate.isEmpty, !allowOutput,
           !StructuredExecution.isAblated(CryptexFilesystemPatcher.stepID, ablate) {
            throw PatcherError.invalidFormat("less dry-run requires --ablate filesystem; filesystem staging is not implemented")
        }

        let (restoreDir, gates) = try prepare()
        let components = buildComponentList()

        let isDry = !ablate.isEmpty && !allowOutput
        log("[*] Patching \(components.count) boot-chain components ..."
            + (isDry ? "  (ABLATION dry-run: firmware NOT written)" : ""))

        var componentReports: [ComponentReport] = []

        for component in components {
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
                ablate: ablate
            )
            componentReports.append(contentsOf: reports)
            logStructuredReports(reports)

            let componentFailed = reports.contains { $0.hasRequiredFailure }
            if componentFailed {
                log("  [x] required failure — not saved; stopping before dependent components")
                break
            } else if isDry {
                log("  [.] ablation dry-run — not saved")
            } else {
                try loader.save(currentData, to: fileURL)
                log("  [+] saved")
            }
        }

        let ablatedIDs = componentReports
            .flatMap { $0.results }
            .filter { $0.outcome == .ablated }
            .map { $0.id }

        let report = PatchRunReport(
            variant: variant.rawValue, gates: gates,
            components: componentReports, ablation: ablatedIDs
        )

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
        ablate: Set<String>
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
                    fallback: input
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
                    [{ data, verbose in
                        KernelPatcher(data: data, verbose: verbose, isDev: false, applyExcGuard: applyExcGuard)
                    }]
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
                        CryptexFilesystemPatcher(buildManiest: data, restoreDir: try! self.findRestoreDirectory(), verbose: verbose, noBinpack: self.noBinpack, noVphoned: self.noVphoned)
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
        let url = restoreDir.appendingPathComponent(manifest)
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any],
              let version = dict["ProductVersion"] as? String
        else { return nil }
        return version
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
        guard let parts = version?.split(separator: ".").compactMap({ Int($0) }),
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
