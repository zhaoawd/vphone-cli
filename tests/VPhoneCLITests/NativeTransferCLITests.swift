import ArgumentParser
import Testing
@testable import vphone_cli

struct NativeTransferCLITests {
    @Test func nativeBackendIsExplicitAndDefaultsRemainSystemTar() throws {
        let ordinary = try VPhoneVMExportCommand.parse(["sample", "--out", "/tmp/export.tzst"])
        #expect(ordinary.archiveBackend == .systemTar)
        let export = try VPhoneVMExportCommand.parse(["sample", "--out", "/tmp/export.tzst", "--archive-backend", "native"])
        #expect(export.archiveBackend == .native)
        let imported = try VPhoneVMImportCommand.parse(["/tmp/export.tzst", "--archive-backend", "native"])
        #expect(imported.archiveBackend == .native)
        #expect(throws: (any Error).self) {
            try VPhoneVMImportCommand.parse(["/tmp/export.tzst", "--archive-backend", "unknown"])
        }
    }

    @Test func localIPSWInspectionIsRegistered() throws {
        #expect(try VPhoneCLI.parseAsRoot(["fw", "inspect", "/tmp/phone.ipsw", "--cloudos-source", "/tmp/cloud.ipsw", "--json"]) is VPhoneFWInspectCommand)
    }
}
