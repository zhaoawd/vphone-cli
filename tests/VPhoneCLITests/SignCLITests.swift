import ArgumentParser
import Testing
@testable import vphone_cli

struct SignCLITests {
    @Test func signingCommandsAreRegistered() throws {
        #expect(try VPhoneCLI.parseAsRoot(["sign", "/tmp/sample"]) is VPhoneSignCommand)
        #expect(try VPhoneCLI.parseAsRoot(["dump-entitlements", "/tmp/sample"]) is VPhoneDumpEntitlementsCommand)
    }

    @Test func conflictingSignatureStylesAreRefused() {
        #expect(throws: (any Error).self) {
            try VPhoneSignCommand.parse(["/tmp/sample", "--apple-adhoc", "--pkcs12", "/tmp/key.p12"])
        }
    }
}
