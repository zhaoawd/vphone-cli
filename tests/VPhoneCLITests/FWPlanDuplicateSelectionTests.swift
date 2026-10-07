import ArgumentParser
import Testing
@testable import vphone_cli

@Suite struct FWPlanDuplicateSelectionTests {
    @Test(arguments: ["--select", "--block"])
    func planRejectsDuplicateIDsBeforeSetConversion(option: String) throws {
        var command = try VPhoneFWPlanCommand.parse([option, "ibss-cfw-serial_label", "ibss-cfw-serial_label", "--json"])
        #expect(throws: (any Error).self) { try command.run() }
    }

    @Test func readOnlyMigrationPreviewAcceptsLegacySelection() throws {
        var command = try VPhoneCLI.parseAsRoot(["fw", "selection-preview", "--variant", "jb",
            "--bundled-preset", "extended", "--select", "ibss.serial_label",
            "--block", "kernel-exp-paravirt_user_clients"])
        try command.run()
    }
}
