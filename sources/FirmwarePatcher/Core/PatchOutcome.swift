// PatchOutcome.swift — Result kind of a single structured patch step (C2).

import Foundation

/// The result of running one patch method (step).
public enum PatchOutcome: Sendable, Equatable {
    /// Anchor found and bytes written.
    case applied
    /// Anchor already in patched form (idempotent no-op); an idempotent record is emitted.
    case alreadyApplied
    /// A conditional rule evaluated false for this input, so the patch does not apply.
    /// This is the ONLY path that produces `notApplicable`.
    case notApplicable(reason: String)
    /// No anchor, ambiguous match, or encoding failure. The default for a missing anchor.
    case failed(reason: String)
    /// Explicitly disabled via `--ablate`; the method did not run and wrote no bytes.
    case ablated(reason: String)

    /// The flat kind used for JSON encoding.
    public var kind: OutcomeKind {
        switch self {
        case .applied: .applied
        case .alreadyApplied: .alreadyApplied
        case .notApplicable: .notApplicable
        case .failed: .failed
        case .ablated: .ablated
        }
    }

    /// The human-readable reason, if any.
    public var reason: String? {
        switch self {
        case .applied, .alreadyApplied: nil
        case let .notApplicable(reason): reason
        case let .failed(reason): reason
        case let .ablated(reason): reason
        }
    }
}

/// Flat, JSON-stable representation of `PatchOutcome`.
public enum OutcomeKind: String, Codable, Sendable, Equatable {
    case applied
    case alreadyApplied
    case notApplicable
    case failed
    case ablated
}

/// Raw result of a step's `run` closure, before requirement/gate interpretation.
public enum RawStepResult: Sendable, Equatable {
    /// Anchor found and record(s) written.
    case matched
    /// Anchor explicitly recognized as already patched. The method may emit an
    /// idempotent record or preserve its legacy no-write behavior with no record.
    case idempotent
    /// No anchor found.
    case noMatch
    /// More than one match where exactly one was expected.
    case ambiguous(count: Int)
    /// Instruction encoding or serialization failed.
    case encodeFail(reason: String)
}

public enum PatchOutcomeMapping {
    /// Map a raw step result to a `PatchOutcome` using the step's requirement and the
    /// run's gate snapshot. See `research/patch_results_ablation_2026-09-09.md`.
    ///
    /// - `matched` → applied; `idempotent` → alreadyApplied.
    /// - `ambiguous`/`encodeFail` → failed even when the requirement is optional.
    /// - `noMatch` → `notApplicable` when the requirement is `.optional` (a missing
    ///   optional anchor never fails the component), or when it is `.conditional` and
    ///   its rule is false for `gates`; otherwise `failed` (required and rule-true
    ///   conditionals fail on a missing anchor).
    ///
    /// C3 mapping refinement: previously `.optional` + `noMatch` mapped to `failed`
    /// (harmless only because optional failures do not set `hasRequiredFailure`). That
    /// mislabels a legitimately-absent optional anchor (e.g. iBoot serial labels or a
    /// pre-26.4 bootx precondition construct) as a failure in the report. It now maps
    /// to `notApplicable`, so only `.required` (and rule-true `.conditional`) treat a
    /// missing anchor as a failure. See research/patch_results_c3_bootchain_2026-09-09.md.
    public static func outcome(
        for raw: RawStepResult,
        requirement: PatchRequirement,
        gates: PatchGateSnapshot
    ) -> PatchOutcome {
        switch raw {
        case .matched:
            if case let .conditional(rule) = requirement, !rule.evaluate(gates) {
                // Should not happen: the rule said this input does not need the patch,
                // yet an anchor matched. Record it as applied with a warning for review.
                return .applied
            }
            return .applied
        case .idempotent:
            return .alreadyApplied
        case let .ambiguous(count):
            return .failed(reason: "expected 1 match, found \(count)")
        case let .encodeFail(reason):
            return .failed(reason: "encode failed: \(reason)")
        case .noMatch:
            switch requirement {
            case .optional:
                return .notApplicable(reason: "optional, no anchor")
            case let .conditional(rule) where !rule.evaluate(gates):
                return .notApplicable(reason: "rule \(rule.rawValue) false for this input: \(gates.summary)")
            case .required, .conditional:
                return .failed(reason: "anchor not found")
            }
        }
    }
}
