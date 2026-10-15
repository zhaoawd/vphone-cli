import ArgumentParser
import Foundation
import Testing
import FirmwarePatcher
@testable import vphone_cli

@Suite struct FWDesiredPlanCLITests {
    @Test(arguments: [["--apply"], ["--apply", "--expected-missing", "--expected-sha256", "abc"]])
    func publicationRequiresOneCASObservation(_ extra: [String]) {
        #expect(throws: (any Error).self) {
            _ = try VPhoneCLI.parseAsRoot(["fw", "desired-plan", "fixture", "--generation", "abc"] + extra)
        }
    }
    @Test func previewAndReadbackAreDistinctCommands() throws {
        _ = try VPhoneCLI.parseAsRoot(["fw", "desired-plan", "fixture", "--generation", "abc"])
        _ = try VPhoneCLI.parseAsRoot(["fw", "desired-plan", "fixture", "--readback"])
        _ = try VPhoneCLI.parseAsRoot(["fw", "desired-plan", "fixture", "--show"])
        #expect(throws: (any Error).self) {
            _ = try VPhoneCLI.parseAsRoot(["fw", "desired-plan", "fixture", "--readback", "--apply"])
        }
    }
    @Test func selectionMigrateCannotCreateExecutableDesiredPlan() throws {
        let f = PatchSelectionFileMigrationTests()
        let root = try f.directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("PatchSelection.plist")
        let data = try f.fixture(file)
        var command = try f.parse(file, apply: true, digest: f.sha(data))
        try command.run()
        guard case .legacy = try FirmwareDesiredPlanStore.read(in: root) else {
            Issue.record("selection-migrate granted ready status"); return
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(FirmwareDesiredPlanStore.filename).path))
    }
}

import VPhoneCore
extension FWDesiredPlanCLITests {
    @Test func showRejectsCorruptAndUnsupportedRecordsThroughCLI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let vm = root.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try VPhoneVirtualMachineManifest(cpuCount: 2, memorySize: 1 << 30, romImages: nil)
            .write(to: vm.appendingPathComponent("config.plist"))
        let file = vm.appendingPathComponent(FirmwareDesiredPlanStore.filename)
        for (bytes, expected) in [("broken", FirmwareDesiredPlanStore.Failure.corrupt),
                                  ("{\"schemaVersion\":999}", .unsupportedSchema(999))] {
            try Data(bytes.utf8).write(to: file)
            var command = try VPhoneCLI.parseAsRoot(["fw", "desired-plan", "fixture", "--library-root", root.path, "--show"])
            #expect(throws: expected) { try command.run() }
            #expect(try String(contentsOf: file, encoding: .utf8) == bytes)
        }
    }
}
