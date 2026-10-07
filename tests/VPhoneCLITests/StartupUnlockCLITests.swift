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
    @Test func configOptionIsExplicitAndLaunchForwardingKeepsAPIListener() throws {
        #expect(try VPhoneVMConfigCommand.parse(["vm", "--startup-unlock", "off"]).startupUnlock?.enabled == false)
        let launch = try VPhoneVMLaunchCommand.parse(["vm", "--api-listen", "127.0.0.1:0"])
        #expect(launch.apiProxyArguments() == ["--api-listen", "127.0.0.1:0"])
    }

    @Test func boundHostExecutionDoesNotOfferPackagedDaemonForAutoUpdate() throws {
        let plain = try VPhoneBootCLI.parse(["--config", "/tmp/config.plist"])
        #expect(plain.autoUpdateGuestBinaryURL != nil)
        let bound = try VPhoneBootCLI.parse(["--config", "/tmp/config.plist", "--binding-sha256", String(repeating: "a", count: 64)])
        #expect(bound.autoUpdateGuestBinaryURL == nil)
    }

}
