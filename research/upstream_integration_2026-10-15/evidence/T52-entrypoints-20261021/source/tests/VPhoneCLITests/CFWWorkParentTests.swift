import ArgumentParser
import Foundation
import Testing
@testable import vphone_cli
import VPhoneCore

struct CFWWorkParentTests {
    @Test func installAndEnvironmentAcceptAndForwardWorkParent() throws {
        let install = try VPhoneCFWInstallCommand.parse(["vm", "--work-parent", "/private/tmp/scratch space"])
        #expect(install.workParent == "/private/tmp/scratch space")
        let update = try VPhoneCFWUpdateEnvironmentCommand.parse(["vm", "--work-parent", "/private/tmp/scratch space"])
        #expect(update.workParent == "/private/tmp/scratch space")
        let script = URL(fileURLWithPath: "/resources/scripts/cfw_install_host.sh")
        #expect(VPhoneCFWInstallCommand.arguments(script: script, directory: URL(fileURLWithPath: "/vm"),
            variant: "regular", guestEnvironment: .classic, reinstallCryptex: false, workParent: "/scratch space")
            == [script.path, "--variant", "regular", "--work-parent", "/scratch space", "/vm"])
        #expect(VPhoneCFWUpdateEnvironmentCommand.driverArguments(resources: VPhoneResources(base: URL(fileURLWithPath: "/resources")),
            bundle: URL(fileURLWithPath: "/vm"), workParent: "/scratch space")
            == [script.path, "--update-environment", "--work-parent", "/scratch space", "/vm"])
    }
}
