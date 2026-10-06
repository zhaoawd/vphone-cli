// PatchDeclarationGate.swift — Strict write-side declaration check (T11).
//
// Before a patched firmware transaction is committed, every emitted record must
// have exactly one owning result with a valid component-local index, attributable to a
// declaration the plan enables for this variant + gate snapshot. A step bound by no
// declaration (undeclared), or bound only by declarations excluded for this variant /
// version / opt-in (not enabled), fails the run before the original firmware is
// replaced. This is strict by design (decision 3): unlike the upstream Gate, which
// applies an undeclared record and only warns, an undeclared record here is refused.
//
// StructuredExecution assigns each step the record-count delta, including records
// emitted before a failure. Check these records regardless of the reported outcome.
// Ablated and not-applicable results cannot own writes; already-applied results may
// legitimately omit records. The gate runs before publishing staged firmware.

import Foundation

public enum PatchDeclarationGate {
    /// A declaration or record-ownership violation in a component report.
    public struct Violation: Sendable, Equatable {
        public enum Kind: String, Sendable, Equatable {
            case undeclared
            case notEnabled
            case invalidRecordIndex
            case duplicateRecordOwnership
            case unattributedRecord
            case unexpectedRecords
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
            var owners: [Int: String] = [:]
            for result in component.results {
                let step = result.id.description
                for index in result.recordIndices {
                    guard component.records.indices.contains(index) else {
                        found.append(Violation(step: step, kind: .invalidRecordIndex,
                            detail: "record index \(index) is outside \(component.component)'s \(component.records.count) records"))
                        continue
                    }
                    if let owner = owners[index] {
                        found.append(Violation(step: step, kind: .duplicateRecordOwnership,
                            detail: "record index \(index) is already owned by \(owner)"))
                    } else {
                        owners[index] = step
                    }
                }
                if !result.recordIndices.isEmpty,
                   result.outcome == .ablated || result.outcome == .notApplicable {
                    found.append(Violation(step: step, kind: .unexpectedRecords,
                        detail: "\(result.outcome.rawValue) result cannot own emitted records"))
                }
                guard !result.recordIndices.isEmpty
                    || result.outcome == .applied || result.outcome == .alreadyApplied else { continue }
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
            for index in component.records.indices where owners[index] == nil {
                found.append(Violation(step: component.component, kind: .unattributedRecord,
                    detail: "record index \(index) (\(component.records[index].patchID)) has no owning result"))
            }
        }
        return found
    }

    /// Throw when record ownership is invalid or an owning step is not enabled. Called before commit,
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
                "declaration gate rejected \(violations.count) violation(s) before commit: \(detail)")
        }
    }
}
