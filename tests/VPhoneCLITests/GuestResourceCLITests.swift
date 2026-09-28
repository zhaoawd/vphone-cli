import ArgumentParser
import Foundation
import Testing
import VPhoneCore
@testable import vphone_cli

struct GuestResourceCLITests {
    @Test func bootSelectsPackagedVariantUnlessExplicitlyOverridden() throws {
        let normal = try VPhoneBootCLI.parse(["--config", "/tmp/config.plist"])
        #expect(normal.guestBinaryURL.lastPathComponent == "vphoned")
        let less = try VPhoneBootCLI.parse(["--config", "/tmp/config.plist", "--variant", "less"])
        #expect(less.guestBinaryURL.lastPathComponent == "vphoned-less")
        let explicit = try VPhoneBootCLI.parse(["--config", "/tmp/config.plist", "--vphoned-bin", "/tmp/custom"])
        #expect(explicit.guestBinaryURL.path == "/tmp/custom")
    }
    @Test func launchForwardsSelectedResourceBaseToChild() throws {
        let resources = VPhoneResources(base: URL(fileURLWithPath: "/tmp/custom resources"))
        let normal = try VPhoneVMLaunchCommand.parse(["sample"])
        #expect(normal.guestPayloadArguments(resources: resources) == ["--vphoned-bin", resources.vphoned.path])
        let less = try VPhoneVMLaunchCommand.parse(["sample", "--variant", "less"])
        #expect(less.guestPayloadArguments(resources: resources) == ["--vphoned-bin", resources.vphonedLess.path])
        for flag in ["--dfu", "--no-vphoned"] {
            let command = try VPhoneVMLaunchCommand.parse(["sample", flag])
            #expect(command.guestPayloadArguments(resources: resources).isEmpty)
        }
    }
}
