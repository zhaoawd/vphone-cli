// PatchResult.swift — Structured, method-level patch results and run report (C2).
//
// `PatchRecord` (Core/PatchRecord.swift) is unchanged and remains the byte-level
// record. `PatchResult` associates a method (`PatchID`), its necessity rule, the
// evaluated outcome, and the indices of the byte records it emitted.

import Foundation

/// The gate values captured at the moment necessity rules were evaluated.
public struct PatchGateSnapshot: Codable, Sendable, Equatable {
    public let variant: String
    public let iosBaseIs18: Bool
    public let iosBaseIs27: Bool
    public let cloudOSIsFridaCapable: Bool
    public let forceExcGuard: Bool
    public let enableFrida: Bool
    // Derived gates, also snapshotted for offline review.
    public let excGuardActive: Bool
    public let applyIOS27: Bool
    public let applyFrida: Bool

    public init(
        variant: String,
        iosBaseIs18: Bool,
        iosBaseIs27: Bool,
        cloudOSIsFridaCapable: Bool,
        forceExcGuard: Bool,
        enableFrida: Bool,
        excGuardActive: Bool,
        applyIOS27: Bool,
        applyFrida: Bool
    ) {
        self.variant = variant
        self.iosBaseIs18 = iosBaseIs18
        self.iosBaseIs27 = iosBaseIs27
        self.cloudOSIsFridaCapable = cloudOSIsFridaCapable
        self.forceExcGuard = forceExcGuard
        self.enableFrida = enableFrida
        self.excGuardActive = excGuardActive
        self.applyIOS27 = applyIOS27
        self.applyFrida = applyFrida
    }

    /// Compact one-line description used in `notApplicable` reasons.
    public var summary: String {
        "variant=\(variant) iosBaseIs18=\(iosBaseIs18) iosBaseIs27=\(iosBaseIs27) "
            + "excGuardActive=\(excGuardActive) applyIOS27=\(applyIOS27) applyFrida=\(applyFrida)"
    }
}

/// The structured result of running one patch method.
public struct PatchResult: Codable, Sendable, Equatable {
    public let id: PatchID
    public let requirement: RequirementKind
    public let rule: PatchRule?
    public let outcome: OutcomeKind
    public let reason: String?
    /// Indices into the owning `ComponentReport.records` array.
    public let recordIndices: [Int]
    public let gates: PatchGateSnapshot

    public init(
        id: PatchID,
        requirement: RequirementKind,
        rule: PatchRule?,
        outcome: OutcomeKind,
        reason: String?,
        recordIndices: [Int],
        gates: PatchGateSnapshot
    ) {
        self.id = id
        self.requirement = requirement
        self.rule = rule
        self.outcome = outcome
        self.reason = reason
        self.recordIndices = recordIndices
        self.gates = gates
    }

    /// Whether this result is a failure that must fail its component: outcome is
    /// `failed` and the requirement is effectively required (required, or a
    /// conditional whose rule is true for this result's gates).
    public var isRequiredFailure: Bool {
        guard outcome == .failed else { return false }
        switch requirement {
        case .required: return true
        case .optional: return false
        case .conditional: return rule?.evaluate(gates) ?? false
        }
    }
}

/// How thoroughly a component was modeled: `structured` (per-method results) or
/// `legacy` (a single aggregated result for an un-migrated patcher).
public enum Coverage: String, Codable, Sendable, Equatable {
    case structured
    case legacy
}

/// One patcher's contribution to a component: its coverage, per-method results, and
/// the byte records it emitted (indexed by `PatchResult.recordIndices`).
public struct ComponentReport: Codable, Sendable, Equatable {
    public let component: String
    public let coverage: Coverage
    public let results: [PatchResult]
    public let records: [PatchRecord]

    public init(component: String, coverage: Coverage, results: [PatchResult], records: [PatchRecord]) {
        self.component = component
        self.coverage = coverage
        self.results = results
        self.records = records
    }

    /// Whether any required result failed in this component.
    public var hasRequiredFailure: Bool {
        results.contains { $0.isRequiredFailure }
    }
}

/// The full patching run: gate snapshot, per-patcher reports, and any ablated ids.
public struct PatchRunReport: Codable, Sendable, Equatable {
    public let variant: String
    public let gates: PatchGateSnapshot
    public let components: [ComponentReport]
    /// Ids ablated on this run (empty means a normal run).
    public let ablation: [PatchID]

    public init(variant: String, gates: PatchGateSnapshot, components: [ComponentReport], ablation: [PatchID]) {
        self.variant = variant
        self.gates = gates
        self.components = components
        self.ablation = ablation
    }

    public var isAblationRun: Bool { !ablation.isEmpty }

    /// Ids of every required failure across all components.
    public var failedRequired: [PatchID] {
        components.flatMap { $0.results }.filter { $0.isRequiredFailure }.map { $0.id }
    }

    /// All byte records across all components, in pipeline order (parity with `patchAll`).
    public var allRecords: [PatchRecord] {
        components.flatMap { $0.records }
    }
}
