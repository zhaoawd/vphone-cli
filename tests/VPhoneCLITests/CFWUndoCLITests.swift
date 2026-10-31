import ArgumentParser
import Foundation
import Testing
@testable import vphone_cli

@Suite struct CFWUndoCLITests {
    @Test func selectionIsExplicitAndInvalidSelectionFailsBeforeExecution() throws {
        let generation = String(repeating: "a", count: 64)
        #expect(try VPhoneCLI.parseAsRoot(["cfw", "undo", "sample", "--generation", generation,
            "--declaration", "dyld-cfw-camera"]) is VPhoneCFWUndoCommand)
        #expect(try VPhoneCLI.parseAsRoot(["cfw", "receipts", "sample", "--json"]) is VPhoneCFWReceiptsCommand)
        for args in [
            ["cfw", "undo", "sample"],
            ["cfw", "undo", "sample", "--generation", generation],
            ["cfw", "undo", "sample", "--generation", "bad", "--declaration", "camera"],
            ["cfw", "undo", "sample", "--generation", generation, "--declaration", "camera", "camera"],
        ] {
            #expect(throws: (any Error).self) { try VPhoneCLI.parseAsRoot(args) }
        }
    }

    @Test func driverReceivesExactUndoSelectionWithoutAnInstallerProfile() {
        let args = VPhoneCFWUndoCommand.arguments(script: URL(fileURLWithPath: "/app/cfw_install_host.sh"),
            directory: URL(fileURLWithPath: "/machines/sample"), variant: "regular", generation: "generation",
            declarations: ["camera", "maxslide"])
        #expect(args == ["/app/cfw_install_host.sh", "--variant", "regular", "--generation", "generation",
            "--undo-declaration", "camera", "--undo-declaration", "maxslide", "/machines/sample"])
    }

    @Test func installedEffectAuditIsAnExplicitReadOnlyCommand() throws {
        let parsed = try VPhoneCLI.parseAsRoot(["cfw", "verify-effects", "sample",
            "--work-parent", "/audit", "--report", "/audit/result.json", "--root-popup"])
        let command = try #require(parsed as? VPhoneCFWVerifyEffectsCommand)
        #expect(command.name == "sample")
        #expect(command.workParent == "/audit")
        #expect(command.rootPopup)
        #expect(command.report == "/audit/result.json")
        for args in [
            ["cfw", "verify-effects", "sample"],
            ["cfw", "verify-effects", "sample", "--work-parent", "/audit", "--root-popup"],
            ["cfw", "verify-effects", "sample", "--work-parent", "/audit", "--declaration", "camera"],
            ["cfw", "verify-effects", "sample", "--work-parent", "/audit", "--reinstall-cryptex"],
        ] {
            #expect(throws: (any Error).self) { try VPhoneCLI.parseAsRoot(args) }
        }
    }
}
