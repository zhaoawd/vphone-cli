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
}
