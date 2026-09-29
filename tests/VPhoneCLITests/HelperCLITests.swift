import ArgumentParser
import Testing
@testable import vphone_cli

struct HelperCLITests {
    @Test func parsesFixedHelperOperations() throws {
        #expect(try VPhoneCLI.parseAsRoot(["helper", "status"]) is VPhoneHelperStatusCommand)
        #expect(try VPhoneCLI.parseAsRoot(["helper", "register"]) is VPhoneHelperRegisterCommand)
        #expect(try VPhoneCLI.parseAsRoot(["helper", "verify-bundle", "--version", "2.0.8"]) is VPhoneHelperVerifyBundleCommand)
        #expect(try VPhoneCLI.parseAsRoot(["helper", "install-bundle", "--version", "2.0.8", "--archive", "/tmp/input", "--sha256", "abc"])
            is VPhoneHelperInstallBundleCommand)
    }
    @Test(arguments: ["run", "shell", "cfw", "allow-amfi", "remove-bundle"])
    func unsupportedPrivilegedVerbsAreNotExposed(_ verb: String) {
        #expect(throws: (any Error).self) { try VPhoneCLI.parseAsRoot(["helper", verb]) }
    }
}
