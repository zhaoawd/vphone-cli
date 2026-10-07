import Testing
@testable import vphone_cli

struct StartupUnlockCLITests {
    @Test func defaultOffAndOptInRequiresAPISurface() throws {
        let plain = try VPhoneBootCLI.parse(["--config", "/tmp/config.plist"])
        #expect(!plain.unlockAtStartup)
        #expect(throws: (any Error).self) {
            try VPhoneBootCLI.parse(["--config", "/tmp/config.plist", "--unlock-at-startup"])
        }
    }
}
