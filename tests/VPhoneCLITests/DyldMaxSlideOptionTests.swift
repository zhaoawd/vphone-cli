import ArgumentParser
import Testing
@testable import vphone_cli

/// T13a: `--force-dsc-maxslide` is removed from every command (upstream d930e50).
/// The maxSlide decision belongs to `patch-dsc-maxslide`'s own span check.
struct DyldMaxSlideOptionTests {
    @Test func createAndInstallRejectTheRemovedFlag() {
        #expect(throws: (any Error).self) {
            _ = try VPhoneVMCreateCommand.parse(["test", "--force-dsc-maxslide"])
        }
        #expect(throws: (any Error).self) {
            _ = try VPhoneVMCreateCommand.parse(["test", "--resume", "--force-dsc-maxslide"])
        }
        #expect(throws: (any Error).self) {
            _ = try VPhoneCFWInstallCommand.parse(["vm", "--force-dsc-maxslide"])
        }
    }

    @Test func createAndInstallStillParseWithoutIt() throws {
        _ = try VPhoneVMCreateCommand.parse(["test"])
        _ = try VPhoneCFWInstallCommand.parse(["vm", "--variant", "jb"])
    }

    @Test func helpNoLongerOffersTheFlag() {
        #expect(!VPhoneVMCreateCommand.helpMessage().contains("force-dsc-maxslide"))
        #expect(!VPhoneCFWInstallCommand.helpMessage().contains("force-dsc-maxslide"))
    }
}
