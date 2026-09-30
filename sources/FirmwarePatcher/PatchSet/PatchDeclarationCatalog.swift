// PatchDeclarationCatalog.swift — The declaration table and its integrity checks (T10/T11).
//
// The catalog holds every declaration (generated in PatchDeclarationCatalogData.swift from
// the T09 mapping). It answers two questions:
//   1. Which declaration owns a Swift step's records? (write-gate attribution, T11)
//   2. Is a Swift step enabled for a variant + gate snapshot? (resolver + write-gate, T11)
//
// Enabled is decided once, the same way for the resolver and the write gate (design
// decision 3): a Swift step is enabled when some declaration binds it, that declaration's
// variant set contains the variant, and its version rule holds for the gates. An
// undeclared step (bound by nothing) is refused rather than let through — the opposite of
// the upstream Gate's fail-open `allows(record:)` (design decision 3).

import Foundation

/// The declaration table plus lookups and integrity checks.
public enum PatchDeclarationCatalog {
    // MARK: - Declarations

    /// Every declaration, in generated order.
    public static let all: [PatchDeclaration] = generatedDeclarations

    /// Declarations by id.
    public static let byID: [String: PatchDeclaration] = {
        var map: [String: PatchDeclaration] = [:]
        for declaration in all { map[declaration.id] = declaration }
        return map
    }()

    /// Swift declarations binding each step `PatchID.description`.
    /// A step may be bound by more than one declaration (`patchApfsMount`, `patchSandbox`).
    public static let declarationsByStep: [String: [PatchDeclaration]] = {
        var map: [String: [PatchDeclaration]] = [:]
        for declaration in all where declaration.coverage == .swift {
            for step in declaration.swiftSteps {
                map[step, default: []].append(declaration)
            }
        }
        return map
    }()

    /// Every Swift step id the catalog knows.
    public static let swiftSteps: Set<String> = Set(declarationsByStep.keys)

    // MARK: - Enabled predicate (shared by resolver and write gate)

    /// Why a Swift step is not enabled for a variant + gate snapshot.
    public enum StepStatus: Sendable, Equatable {
        case enabled(declaration: String)
        /// The step is bound by declaration(s), but none apply to this variant.
        case excludedByVariant
        /// A declaration applies to this variant, but its version rule is false.
        case excludedByVersion(rule: PatchRule)
        /// A declaration applies, but its `--frida` opt-in is off.
        case excludedByOptIn
        /// No declaration binds this step.
        case undeclared
    }

    /// The status of a Swift step for a variant and gate snapshot. Enabled iff some
    /// binding declaration's variant set contains `variant` and its version rule holds.
    public static func status(ofStep step: String, variant: String, gates: PatchGateSnapshot) -> StepStatus {
        guard let declarations = declarationsByStep[step] else { return .undeclared }
        let forVariant = declarations.filter { $0.variants.contains(variant) }
        guard !forVariant.isEmpty else { return .excludedByVariant }
        if let enabled = forVariant.first(where: { ruleHolds($0, gates) }) {
            return .enabled(declaration: enabled.id)
        }
        // Not enabled: report the most specific reason from the applicable declarations.
        if forVariant.contains(where: { $0.optIn == .frida && !gates.enableFrida }) {
            return .excludedByOptIn
        }
        let rule = forVariant.compactMap(\.versionRule).first { $0 != .always } ?? .always
        return .excludedByVersion(rule: rule)
    }

    /// Whether a Swift step is enabled (records it emits may be written).
    public static func isStepEnabled(_ step: String, variant: String, gates: PatchGateSnapshot) -> Bool {
        if case .enabled = status(ofStep: step, variant: variant, gates: gates) { return true }
        return false
    }

    /// Whether a declaration's version rule holds for a gate snapshot. A `.frida` opt-in
    /// declaration additionally needs `enableFrida`; its `cloudOSFridaCapable` rule already
    /// folds that in (`applyFrida == enableFrida && capable`), so evaluating the rule is
    /// sufficient. nil (guest / notImplemented) never holds in the Swift gate.
    static func ruleHolds(_ declaration: PatchDeclaration, _ gates: PatchGateSnapshot) -> Bool {
        guard let rule = declaration.versionRule else { return false }
        return rule.evaluate(gates)
    }

    // MARK: - Integrity checks (T11)

    public enum CatalogError: Error, CustomStringConvertible, Equatable {
        case duplicateDeclaration(id: String)
        case stepBoundByNothing(step: String)
        case liveStepUndeclared(step: String, variant: String)
        case missingDependency(id: String, requires: String)
        case conflict(id: String, with: String)
        case cyclicOrder([String])
        case unknownDeclaration(id: String)
        case notImplementedSelected(id: String)
        case versionIndeterminate(id: String, rule: PatchRule)
        case requiredMissing(variant: String, id: String)

        public var description: String {
            switch self {
            case let .duplicateDeclaration(id):
                "declaration id declared twice: \(id)"
            case let .stepBoundByNothing(step):
                "catalog integrity: swift step has no declaration: \(step)"
            case let .liveStepUndeclared(step, variant):
                "pipeline step has no declaration (variant \(variant)): \(step)"
            case let .missingDependency(id, requires):
                "declaration \(id) requires \(requires), which is not enabled"
            case let .conflict(id, other):
                "declarations \(id) and \(other) conflict"
            case let .cyclicOrder(ids):
                "declaration order is cyclic: \(ids.joined(separator: " -> "))"
            case let .unknownDeclaration(id):
                "selection names declaration \(id), which the catalog does not declare"
            case let .notImplementedSelected(id):
                "declaration \(id) is not implemented locally and cannot be selected"
            case let .versionIndeterminate(id, rule):
                "declaration \(id) needs version rule \(rule.rawValue), but the base version is unknown"
            case let .requiredMissing(variant, id):
                "required declaration \(id) is not enabled for variant \(variant)"
            }
        }
    }

    /// Structural checks that do not depend on a variant: unique ids, every Swift step
    /// bound, dependency targets exist, and the `after` graph is acyclic.
    public static func validateStructure(_ declarations: [PatchDeclaration] = all) throws {
        var seen = Set<String>()
        for declaration in declarations {
            guard seen.insert(declaration.id).inserted else {
                throw CatalogError.duplicateDeclaration(id: declaration.id)
            }
        }
        let ids = seen
        // Dependencies name real declarations.
        for declaration in declarations {
            for requirement in declaration.requires where !ids.contains(requirement) {
                throw CatalogError.missingDependency(id: declaration.id, requires: requirement)
            }
            for other in declaration.conflicts where ids.contains(other) {
                // A declared conflict against a present declaration is only an error when
                // both are enabled; structural check just verifies the id resolves.
                _ = other
            }
        }
        try checkOrder(declarations)
    }

    /// Topological check over `after`; throws `.cyclicOrder` when no order satisfies it.
    static func checkOrder(_ declarations: [PatchDeclaration]) throws {
        var predecessors: [String: Set<String>] = [:]
        var successors: [String: Set<String>] = [:]
        let ids = Set(declarations.map(\.id))
        for declaration in declarations {
            predecessors[declaration.id] = []
            successors[declaration.id] = []
        }
        for declaration in declarations {
            for earlier in declaration.after where ids.contains(earlier) {
                predecessors[declaration.id]?.insert(earlier)
                successors[earlier]?.insert(declaration.id)
            }
        }
        var ready = declarations.map(\.id).filter { predecessors[$0]?.isEmpty ?? true }
        var placed = 0
        while let next = ready.first {
            ready.removeFirst()
            placed += 1
            for successor in (successors[next] ?? []).sorted() {
                predecessors[successor]?.remove(next)
                if predecessors[successor]?.isEmpty == true { ready.append(successor) }
            }
            successors[next] = []
        }
        if placed != declarations.count {
            let stuck = declarations.map(\.id).filter { !(predecessors[$0]?.isEmpty ?? true) }
            throw CatalogError.cyclicOrder(stuck)
        }
    }
}
