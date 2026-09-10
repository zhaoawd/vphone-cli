// PatchRequirement.swift — Necessity model for structured patch steps (C2).
//
// A patch method's necessity is decided by an explicit rule, never by whether an
// anchor happened to match. Missing required anchors fail; disabled conditional
// rules and absent optional anchors produce `notApplicable` (see `PatchOutcome`).

import Foundation

/// Whether a patch step must apply, may be skipped, or is decided by a rule.
public enum PatchRequirement: Sendable, Equatable {
    /// Must end as applied/alreadyApplied; a `failed` outcome fails the component.
    case required
    /// A missing anchor does not fail the pipeline (e.g. iBoot serial labels).
    case optional
    /// An explicit predicate decides whether this input requires the patch. When the
    /// rule is false, execution is skipped as `notApplicable`; when the
    /// rule is true it behaves like `.required`.
    case conditional(PatchRule)

    /// The flat kind used for JSON encoding.
    public var kind: RequirementKind {
        switch self {
        case .required: .required
        case .optional: .optional
        case .conditional: .conditional
        }
    }

    /// The rule for a conditional requirement (nil otherwise).
    public var rule: PatchRule? {
        if case let .conditional(rule) = self { return rule }
        return nil
    }

    /// Whether this requirement is effectively required for the given gate snapshot:
    /// `.required` always, `.conditional` when its rule is true, `.optional` never.
    public func isEffectivelyRequired(for gates: PatchGateSnapshot) -> Bool {
        switch self {
        case .required: true
        case .optional: false
        case let .conditional(rule): rule.evaluate(gates)
        }
    }
}

/// Flat, JSON-stable representation of `PatchRequirement`.
public enum RequirementKind: String, Codable, Sendable, Equatable {
    case required
    case optional
    case conditional
}

/// Named predicate that decides whether a conditional patch applies to an input.
///
/// Each case is 1:1 with a gate string used by the C1 compatibility manifest
/// (`research/firmware_compatibility.json` `methods[].gate`), so the same identifier
/// names the necessity rule in code, in the report JSON, and in the manifest.
public enum PatchRule: String, Sendable, Codable, Equatable {
    /// Always required (equivalent to `.required`, kept for explicit conditionals).
    case always
    /// iPhone base is iOS 18.x.
    case iosBaseIs18
    /// iPhone base is iOS 27.x (gates the iOS-27-only JB kernel patches).
    case iosBaseIs27
    /// Frida kernel patches are active (`enableFrida && cloudOSIsFridaCapable`).
    case cloudOSFridaCapable
    /// EXC_GUARD disable is active (`variant == .dev || iosBaseIs18 || forceExcGuard`).
    case excGuardActive

    /// Evaluate the rule against the run's gate snapshot.
    public func evaluate(_ gates: PatchGateSnapshot) -> Bool {
        switch self {
        case .always: true
        case .iosBaseIs18: gates.iosBaseIs18
        case .iosBaseIs27: gates.iosBaseIs27
        case .cloudOSFridaCapable: gates.applyFrida
        case .excGuardActive: gates.excGuardActive
        }
    }
}
