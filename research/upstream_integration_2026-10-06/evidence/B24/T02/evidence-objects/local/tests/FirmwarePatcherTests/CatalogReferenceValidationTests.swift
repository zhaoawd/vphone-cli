import Testing
@testable import FirmwarePatcher

@Suite struct CatalogReferenceValidationTests {
    @Test(arguments: ["requires", "conflicts", "after"])
    func refusesAReferenceToAnUnknownDeclaration(relation: String) {
        let owner = DeclarationGateTests.decl("owner",
            requires: relation == "requires" ? ["missing"] : [],
            conflicts: relation == "conflicts" ? ["missing"] : [],
            after: relation == "after" ? ["missing"] : [])
        let expected: PatchDeclarationCatalog.CatalogError = relation == "requires"
            ? .missingDependency(id: "owner", requires: "missing")
            : .unknownReference(id: "owner", relation: relation, target: "missing")
        #expect(throws: expected) {
            try PatchDeclarationCatalog.validateStructure([owner])
        }
    }

    @Test func knownConflictAndOrderTargetsMayBeInactive() throws {
        let owner = DeclarationGateTests.decl("owner", conflicts: ["inactive"], after: ["inactive"])
        let inactive = DeclarationGateTests.decl("inactive", variants: [])
        let catalog = PatchDeclarationCatalog.all + [owner, inactive]
        try PatchDeclarationCatalog.validateStructure(catalog)
        let plan = try VariantPlanResolver.resolve(variant: .regular,
            gates: DeclarationGateTests.gates(), catalog: catalog)
        #expect(plan.selected.contains { $0.id == "owner" })
        #expect(plan.excludedByVariant.contains { $0.id == "inactive" })
    }
}
