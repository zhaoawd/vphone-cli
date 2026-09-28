import ArgumentParser
import Testing
@testable import vphone_cli

struct RestoreInspectCLITests {
    @Test func keepsRestoreAndOfflineInspectionSeparate() throws {
        #expect(try VPhoneCLI.parseAsRoot(["restore-inspect", "/tmp/vm", "--ecid", "0x123", "--ticket", "/tmp/a.shsh", "--json"]) is VPhoneRestoreInspectCommand)
        #expect(try VPhoneCLI.parseAsRoot(["restore", "sample"]) is VPhoneRestoreCommand)
    }
}
