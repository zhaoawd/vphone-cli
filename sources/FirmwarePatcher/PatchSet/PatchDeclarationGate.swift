// PatchDeclarationGate.swift — Strict write-side declaration check (T11).
//
// Before a patched firmware transaction is committed, every record a Swift step
// committed (an `applied` / `alreadyApplied` step result) must be attributable to a
// declaration the plan enables for this variant + gate snapshot. A step bound by no
// declaration (undeclared), or bound only by declarations excluded for this variant /
// version / opt-in (not enabled), fails the run before the original firmware is
// replaced. This is strict by design (decision 3): unlike the upstream Gate, which
// applies an undeclared record and only warns, an undeclared record here is refused.
//
// For correct configurations the gate never fires: a step emits records only when its
// requirement rule was true, and the catalog enables exactly those steps, so the check
// passes and the output is byte-identical to the pre-gate path (decision 6). The gate
// only fires on catalog / pipeline drift — a step writing records it is not declared to.

import Foundation

public enum PatchDeclarationGate {
    /// A record whose owning step is undeclared or not enabled in the plan.
    public struct Violation: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable {
            case undeclared
            case notEnabled
        }

        public let step: String
        public let kind: Kind
        public let detail: String
    }

    /// Every violation in `report` for `variant` + `gates`. Empty when the run is clean.
    public static func violations(
        in report: PatchRunReport,
        variant: String,
        gates: PatchGateSnapshot
    ) -> [Violation] {
        var found: [Violation] = []
        for component in report.components {
            for result in component.results
            where result.outcome == .applied || result.outcome == .alreadyApplied {
                let step = result.id.description
                if component.coverage == .legacy {
                    // A legacy aggregate carries method "*"; no local component is legacy,
                    // so treat one that matches no enabled step as undeclared.
                    let prefix = result.id.component + "."
                    let enabled = PatchDeclarationCatalog.swiftSteps.contains {
                        $0.hasPrefix(prefix)
                            && PatchDeclarationCatalog.isStepEnabled($0, variant: variant, gates: gates)
                    }
                    if !enabled {
                        found.append(Violation(step: step, kind: .undeclared,
                            detail: "legacy component \(result.id.component) has no enabled declared step"))
                    }
                    continue
                }
                switch PatchDeclarationCatalog.status(ofStep: step, variant: variant, gates: gates) {
                case .enabled:
                    continue
                case .undeclared:
                    found.append(Violation(step: step, kind: .undeclared,
                        detail: "no declaration binds this step"))
                case .excludedByVariant:
                    found.append(Violation(step: step, kind: .notEnabled,
                        detail: "declared, but not for variant \(variant)"))
                case let .excludedByVersion(rule):
                    found.append(Violation(step: step, kind: .notEnabled,
                        detail: "declared, but version rule \(rule.rawValue) is false for these gates"))
                case .excludedByOptIn:
                    found.append(Violation(step: step, kind: .notEnabled,
                        detail: "declared, but its --frida opt-in is off"))
                }
            }
        }
        return found
    }

    /// Throw when any committed record is undeclared or not enabled. Called before commit,
    /// so a violation leaves the original firmware unchanged.
    public static func enforce(
        report: PatchRunReport,
        variant: String,
        gates: PatchGateSnapshot
    ) throws {
        let violations = violations(in: report, variant: variant, gates: gates)
        guard violations.isEmpty else {
            let detail = violations
                .map { "\($0.step) [\($0.kind.rawValue)]: \($0.detail)" }
                .joined(separator: "; ")
            throw PatcherError.patchVerificationFailed(
                "declaration gate rejected \(violations.count) record(s) before commit: \(detail)")
        }
    }
}
