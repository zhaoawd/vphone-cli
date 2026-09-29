import ArgumentParser
import Foundation
import Testing
@testable import vphone_cli

struct CoreBundleCLITests {
    @Test func parsesInstallAndVerify() throws {
        let install = try #require(VPhoneCLI.parseAsRoot(["core-bundle", "install", "--version", "2.0.8-local",
            "--archive", "/tmp/bundle.tar", "--sha256", String(repeating: "a", count: 64)]) as? VPhoneCoreBundleInstallCommand)
        #expect(install.version == "2.0.8-local")
        #expect(install.archive.path == "/tmp/bundle.tar")
        #expect(try VPhoneCLI.parseAsRoot(["core-bundle", "verify", "--version", "2.0.8"]) is VPhoneCoreBundleVerifyCommand)
    }

    @Test(arguments: ["--store", "--executable", "--skip-signature-check", "--force"])
    func noPathOrVerificationBypass(_ option: String) {
        #expect(throws: (any Error).self) {
            try VPhoneCLI.parseAsRoot(["core-bundle", "install", "--version", "2.0.8", "--archive", "/tmp/bundle.tar",
                                      "--sha256", String(repeating: "a", count: 64), option, "/tmp/override"])
        }
    }
}
