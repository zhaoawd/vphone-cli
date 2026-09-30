// VariantPlanResolver.swift — Resolve a variant + gate snapshot into a declared plan (T10/T11).
//
// The resolver decides once, before anything is written, which declarations run for a
// variant, which are excluded and why. It derives the live step set from the pipeline's
// own `buildComponentList()` / `buildSteps()` (design decision: the plan is derived from
// the code paths, never a hand-kept parallel list) and joins it with the declaration
// catalog. Every disagreement is an error with the offending id (T11): an undeclared
// pipeline step, a required declaration the pipeline does not run, an unreadable version a
// required version-gated declaration needs, a duplicate id, a missing dependency, a
// conflict, a cyclic order, an unknown or not-implemented selection.

import Foundation

/// The five firmware variants plus the resolved plan for one of them.
public enum VariantPlanResolver {
    // MARK: - Plan model

    /// Why a declaration is or is not in the plan.
    public enum Disposition: String, Sendable, Codable, Equatable {
        case selected
        case excludedByVersion
        case excludedByOptIn
        case excludedByVariant
        /// Guest-side Python/zsh step: declaration-only this round, execution not gated.
        case guestUncovered
        /// Declared upstream, not implemented locally.
        case notImplemented
    }

    /// One declaration's place in a variant's plan.
    public struct Entry: Sendable, Codable, Equatable {
        public let id: String
        public let title: String
        public let disposition: Disposition
        public let reason: String
        public let required: Bool
        public let optIn: String
        public let swiftSteps: [String]
        public let upstreamIDs: [String]
    }

    /// The resolved plan for a variant + gate snapshot.
    public struct VariantPlan: Sendable, Codable, Equatable {
        public let variant: String
        public let gates: PatchGateSnapshot
        public let upstreamTag: String
        public let selected: [Entry]
        public let excludedByVersion: [Entry]
        public let excludedByOptIn: [Entry]
        public let excludedByVariant: [Entry]
        public let guestUncovered: [Entry]
        public let notImplemented: [Entry]
        /// The Swift step ids the plan actually runs for this variant. A declaration may bind
        /// variant-alternative steps (trustcache binds TXMPatcher and TXMDevPatcher), so this
        /// is the selected declarations' steps intersected with the variant's live steps.
        public let enabledSteps: Set<String>

        /// The Swift step ids the plan enables; the write gate checks emitted steps against this.
        public var enabledStepIDs: Set<String> { enabledSteps }
    }

    // MARK: - Live step enumeration (from the pipeline)

    /// The Swift step ids the pipeline runs for a variant, in component order. Derived from
    /// `buildComponentList()` without touching disk (empty-data patchers, static ids for the
    /// filesystem/manifest factories that need a restore directory), mirroring
    /// `knownAblationTargets`.
    public static func liveStepIDs(variant: FirmwarePipeline.Variant) -> [String] {
        let pipeline = FirmwarePipeline(
            vmDirectory: URL(fileURLWithPath: "/nonexistent/variant-plan"),
            variant: variant, verbose: false)
        var ids: [String] = []
        for component in pipeline.buildComponentList() {
            if component.name == "Filesystem" {
                if !component.patcherFactories.isEmpty { ids.append(CryptexFilesystemPatcher.stepID.description) }
                continue
            }
            if component.name == "Manifest" {
                if !component.patcherFactories.isEmpty { ids.append(ManifestHashPatcher.stepID.description) }
                continue
            }
            for makePatcher in component.patcherFactories {
                let patcher = makePatcher(Data(), false)
                if let structured = patcher as? any StructuredPatcher {
                    ids.append(contentsOf: structured.buildSteps().map(\.id.description))
                }
            }
        }
        return ids
    }

    // MARK: - Resolve

    /// Resolve `variant` under `gates`. `baseVersionKnown` is false when the iPhone base
    /// `ProductVersion` could not be read (the gates then read as not-18/not-27); a required
    /// version-gated declaration then resolves to `versionIndeterminate` instead of silently
    /// dropping. `select` / `block` are explicit per-run overrides (empty on the default
    /// path); an unknown or not-implemented id in `select` is refused.
    public static func resolve(
        variant: FirmwarePipeline.Variant,
        gates: PatchGateSnapshot,
        baseVersionKnown: Bool = true,
        select: Set<String> = [],
        block: Set<String> = [],
        catalog: [PatchDeclaration] = PatchDeclarationCatalog.all
    ) throws -> VariantPlan {
        try PatchDeclarationCatalog.validateStructure(catalog)

        let byID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        // Explicit selection must name real, implemented declarations.
        for id in select.union(block) where byID[id] == nil {
            throw PatchDeclarationCatalog.CatalogError.unknownDeclaration(id: id)
        }
        for id in select where byID[id]?.coverage == .notImplemented {
            throw PatchDeclarationCatalog.CatalogError.notImplementedSelected(id: id)
        }

        let variantName = variant.rawValue
        let live = liveStepIDs(variant: variant)
        let liveSet = Set(live)

        // Every pipeline step must be a declared Swift step.
        let knownSteps = Set(catalog.filter { $0.coverage == .swift }.flatMap(\.swiftSteps))
        for step in live where !knownSteps.contains(step) {
            throw PatchDeclarationCatalog.CatalogError.liveStepUndeclared(step: step, variant: variantName)
        }

        var selected: [Entry] = []
        var excludedByVersion: [Entry] = []
        var excludedByOptIn: [Entry] = []
        var excludedByVariant: [Entry] = []
        var guestUncovered: [Entry] = []
        var notImplemented: [Entry] = []
        var enabledIDs = Set<String>()

        for declaration in catalog {
            let blocked = block.contains(declaration.id)
            switch declaration.coverage {
            case .notImplemented:
                notImplemented.append(entry(declaration, .notImplemented,
                    "not implemented locally (T18 libmisfix scope)"))
                continue
            case .guestStep:
                if declaration.variants.contains(variantName) {
                    guestUncovered.append(entry(declaration, .guestUncovered,
                        "guest Python/zsh step: declaration-only this round, execution not gated"))
                }
                continue
            case .swift:
                break
            }

            guard declaration.variants.contains(variantName) else {
                excludedByVariant.append(entry(declaration, .excludedByVariant,
                    "not in variant \(variantName) (\(declaration.variants.sorted().joined(separator: ",")))"))
                continue
            }
            if blocked {
                excludedByOptIn.append(entry(declaration, .excludedByOptIn, "blocked by request"))
                continue
            }
            if declaration.optIn == .frida, !gates.enableFrida {
                excludedByOptIn.append(entry(declaration, .excludedByOptIn, "needs --frida opt-in"))
                continue
            }
            // Required version-gated declaration with an unreadable base version.
            if declaration.required, !baseVersionKnown,
               let rule = declaration.versionRule, rule == .iosBaseIs18 || rule == .iosBaseIs27 {
                throw PatchDeclarationCatalog.CatalogError.versionIndeterminate(id: declaration.id, rule: rule)
            }
            if PatchDeclarationCatalog.ruleHolds(declaration, gates) {
                selected.append(entry(declaration, .selected, dispositionReason(declaration)))
                enabledIDs.insert(declaration.id)
            } else if let rule = declaration.versionRule, declaration.optIn == .frida {
                // Frida opt-in on but cloudOS below the floor.
                excludedByVersion.append(entry(declaration, .excludedByVersion,
                    "version rule \(rule.rawValue) false for these gates"))
            } else {
                let rule = declaration.versionRule ?? .always
                excludedByVersion.append(entry(declaration, .excludedByVersion,
                    "version rule \(rule.rawValue) false for these gates"))
            }
        }

        // Required declarations the pipeline must actually run. A declaration may bind
        // variant-alternative steps (regular uses TXMPatcher, dev/jb/exp use TXMDevPatcher),
        // so at least one bound step must be live rather than all of them.
        for declaration in catalog
        where declaration.coverage == .swift && declaration.required && !declaration.swiftSteps.isEmpty {
            guard declaration.variants.contains(variantName),
                  PatchDeclarationCatalog.ruleHolds(declaration, gates) else { continue }
            if !declaration.swiftSteps.contains(where: liveSet.contains) {
                throw PatchDeclarationCatalog.CatalogError.requiredMissing(variant: variantName, id: declaration.id)
            }
        }

        // Dependencies and conflicts among the enabled declarations.
        for id in enabledIDs.sorted() {
            guard let declaration = byID[id] else { continue }
            for requirement in declaration.requires where !enabledIDs.contains(requirement) {
                throw PatchDeclarationCatalog.CatalogError.missingDependency(id: id, requires: requirement)
            }
            for other in declaration.conflicts where enabledIDs.contains(other) {
                throw PatchDeclarationCatalog.CatalogError.conflict(id: id, with: other)
            }
        }

        let enabledSteps = Set(selected.flatMap(\.swiftSteps)).intersection(liveSet)
        return VariantPlan(
            variant: variantName, gates: gates, upstreamTag: PatchDeclarationCatalog.upstreamTag,
            selected: selected, excludedByVersion: excludedByVersion, excludedByOptIn: excludedByOptIn,
            excludedByVariant: excludedByVariant, guestUncovered: guestUncovered,
            notImplemented: notImplemented, enabledSteps: enabledSteps)
    }

    private static func dispositionReason(_ declaration: PatchDeclaration) -> String {
        if let rule = declaration.versionRule, rule != .always {
            return "version rule \(rule.rawValue) holds"
        }
        return declaration.required ? "required" : "applies"
    }

    private static func entry(_ declaration: PatchDeclaration, _ disposition: Disposition, _ reason: String) -> Entry {
        Entry(
            id: declaration.id, title: declaration.title, disposition: disposition, reason: reason,
            required: declaration.required, optIn: declaration.optIn.rawValue,
            swiftSteps: declaration.swiftSteps, upstreamIDs: declaration.upstreamIDs)
    }
}
