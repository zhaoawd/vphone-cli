import ArgumentParser
import Foundation
import Testing
import VPhoneCore
@testable import vphone_cli

struct GuestEnvironmentEntryTests {
    @Test func unsupportedV2VariantsAreRejectedBeforeExecution() {
        for variant in ["dev", "jb", "exp", "less"] {
            do {
                _ = try VPhoneVMCreateCommand.parse(["example", "--variant", variant, "--guest-environment", "v2"])
                Issue.record("create accepted v2 for \(variant)")
            } catch {
                #expect(String(describing: error).contains("guest environment v2 supports only variant regular"))
            }
            if variant != "less" {
                do {
                    _ = try VPhoneCFWInstallCommand.parse(["example", "--variant", variant, "--guest-environment", "v2"])
                    Issue.record("install accepted v2 for \(variant)")
                } catch {
                    #expect(String(describing: error).contains("guest environment v2 supports only variant regular"))
                }
            }
        }
    }

    @Test func standaloneInstallRequiresMatchingRecordedEnvironment() throws {
        try VPhoneCFWInstallCommand.validateRecordedEnvironment(requested: .classic, recorded: .classic)
        try VPhoneCFWInstallCommand.validateRecordedEnvironment(requested: .v2, recorded: .v2)
        #expect(throws: (any Error).self) {
            try VPhoneCFWInstallCommand.validateRecordedEnvironment(requested: .v2, recorded: .classic)
        }
        #expect(throws: (any Error).self) {
            try VPhoneCFWInstallCommand.validateRecordedEnvironment(requested: .classic, recorded: .v2)
        }
    }

    @Test func createAndInstallAcceptGuestEnvironmentOption() throws {
        _ = try VPhoneVMCreateCommand.parse(["example", "--guest-environment", "v2"])
        _ = try VPhoneCFWInstallCommand.parse(["example", "--variant", "regular", "--guest-environment", "v2"])
    }
}
