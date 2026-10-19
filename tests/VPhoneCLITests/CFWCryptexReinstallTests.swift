import Foundation
import Testing
import VPhoneCore
@testable import vphone_cli

struct CFWCryptexReinstallTests {
    @Test func explicitRegularClassicOptionAndDefault() throws {
        let ordinary = try VPhoneCFWInstallCommand.parse(["sample"])
        #expect(!ordinary.reinstallCryptex)
        let explicit = try VPhoneCFWInstallCommand.parse(["sample", "--variant", "regular", "--reinstall-cryptex"])
        #expect(explicit.reinstallCryptex)
        _ = try VPhoneCFWInstallCommand.parse(["sample", "--reinstall-cryptex"])
        for args in [["--guest-environment", "v2"], ["--variant", "dev"], ["--variant", "jb"], ["--variant", "exp"]] {
            #expect(throws: (any Error).self) {
                _ = try VPhoneCFWInstallCommand.parse(["sample", "--reinstall-cryptex"] + args)
            }
        }
        #expect(throws: (any Error).self) {
            try VPhoneCFWInstallCommand.validateCryptexReinstall(true, variant: "exp", guestEnvironment: .classic)
        }
    }

    @Test func explicitOptionSurvivesDriverArguments() {
        let script = URL(fileURLWithPath: "/app/cfw_install_host.sh")
        let vm = URL(fileURLWithPath: "/machines/sample")
        #expect(VPhoneCFWInstallCommand.arguments(script: script, directory: vm, variant: "regular",
            guestEnvironment: .classic, reinstallCryptex: true) ==
            [script.path, "--variant", "regular", "--reinstall-cryptex", vm.path])
        #expect(VPhoneCFWInstallCommand.arguments(script: script, directory: vm, variant: "regular",
            guestEnvironment: .v2, reinstallCryptex: false) ==
            [script.path, "--variant", "regular", "--guest-environment", "v2", vm.path])
    }
}
