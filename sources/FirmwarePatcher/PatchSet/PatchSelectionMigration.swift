import Foundation

/// Read-only ID migration. The result preserves explicit overrides; it is not an
/// executable plan. Variant/version/required/guest gates remain the resolver's job.
public enum PatchSelectionMigration {
    public static let mappingRevision = "vphone.patch-id-migration/1"
    public static let upstreamTarget = "2d21d21fbdd4f51f013616273ceda9b35a3e0789"

    public struct Rename: Sendable, Equatable, Codable {
        public let from: String
        public let to: String
        public let enabled: Bool
    }

    public struct Preview: Sendable, Equatable, Codable {
        public let mappingRevision: String
        public let upstreamTarget: String
        public let selected: [String]
        public let blocked: [String]
        public let renames: [Rename]
        /// IDs known to the target but absent from the current local declaration catalog.
        public let notDeclaredLocally: [String]
    }

    public enum MigrationError: Error, Equatable, CustomStringConvertible {
        case unknownBundledPreset(String)
        case unknownID(String)
        case duplicateID(String)
        case duplicateTarget(String)
        case contradictoryID(String)

        public var description: String {
            switch self {
            case let .unknownBundledPreset(id): "unknown bundled patch preset: \(id)"
            case let .unknownID(id): "unknown patch migration id: \(id)"
            case let .duplicateID(id): "explicit patch id supplied more than once: \(id)"
            case let .duplicateTarget(id): "multiple supplied ids migrate to the same patch: \(id)"
            case let .contradictoryID(id): "patch is explicitly selected and blocked: \(id)"
            }
        }
    }

    /// Only the shipped preset namespace is accepted; local modes and custom
    /// preset identifiers must be resolved by their own stores.
    public static func migrateBundledPreset(_ identifier: String) throws -> String {
        switch identifier {
        case "extended": "experimental"
        case "standard", "experimental": identifier
        default: throw MigrationError.unknownBundledPreset(identifier)
        }
    }

    /// Validate arrays before callers convert them to sets. No normalization occurs.
    public static func validateExplicitInputs(select: [String], block: [String]) throws {
        for inputs in [select, block] {
            var seen = Set<String>()
            for id in inputs where !seen.insert(id).inserted {
                throw MigrationError.duplicateID(id)
            }
        }
        if let id = Set(select).intersection(block).sorted().first {
            throw MigrationError.contradictoryID(id)
        }
    }

    public static func preview(select: [String], block: [String]) throws -> Preview {
        try validateExplicitInputs(select: select, block: block)
        var renames: [Rename] = []
        func migrate(_ inputs: [String], enabled: Bool) throws -> [String] {
            var result = Set<String>()
            for id in inputs {
                let canonical = aliases[id] ?? id
                guard knownIDs.contains(canonical) else { throw MigrationError.unknownID(id) }
                guard result.insert(canonical).inserted else {
                    throw MigrationError.duplicateTarget(canonical)
                }
                if canonical != id { renames.append(.init(from: id, to: canonical, enabled: enabled)) }
            }
            return result.sorted()
        }
        let selected = try migrate(select, enabled: true)
        let blocked = try migrate(block, enabled: false)
        if let id = Set(selected).intersection(blocked).sorted().first {
            throw MigrationError.contradictoryID(id)
        }
        let notDeclared = Set(selected + blocked).filter { PatchDeclarationCatalog.byID[$0] == nil }.sorted()
        return Preview(mappingRevision: mappingRevision, upstreamTarget: upstreamTarget,
                       selected: selected, blocked: blocked,
                       renames: renames.sorted { $0.from < $1.from }, notDeclaredLocally: notDeclared)
    }
}
