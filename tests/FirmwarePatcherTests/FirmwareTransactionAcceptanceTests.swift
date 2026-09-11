import Darwin
import Foundation
import XCTest
@testable import FirmwarePatcher

final class FirmwareTransactionAcceptanceTests: XCTestCase {
    func testLargeImageDigestUsesBoundedMemory() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("c4-memory-" + UUID().uuidString)
        FileManager.default.createFile(atPath: file.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 128 * 1024 * 1024)
        try handle.close()
        var before = rusage(), after = rusage()
        XCTAssertEqual(getrusage(RUSAGE_SELF, &before), 0)
        let first = try FirmwareTransaction.digest(file)
        XCTAssertEqual(try FirmwareTransaction.digest(file), first)
        XCTAssertEqual(getrusage(RUSAGE_SELF, &after), 0)
        // Darwin reports ru_maxrss in bytes. A 1 MiB streaming buffer must not
        // retain two complete 128 MiB images across successive digest calls.
        XCTAssertLessThan(after.ru_maxrss - before.ru_maxrss, 64 * 1024 * 1024)
    }

    func testProductionArtifacts() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["VPHONE_C4_PIPELINE_VM"] else { throw XCTSkip("Set an isolated C4 firmware fixture directory") }
        let vm = URL(fileURLWithPath: path).standardizedFileURL
        guard vm.path.contains("research/artifacts/c4-"), vm.resolvingSymlinksInPath() == vm else {
            throw PatcherError.invalidFormat("C4 acceptance requires an isolated artifacts/c4- directory")
        }
        if env["VPHONE_C4_RECOVER_ONLY"] == "1" {
            XCTAssertNotNil(try FirmwarePipeline.recoverFirmware(in: vm))
            XCTAssertFalse(FirmwareTransaction.exists(vm.appendingPathComponent(".firmware-transaction")))
            return
        }
        let variant = try XCTUnwrap(FirmwarePipeline.Variant(rawValue: env["VPHONE_C4_VARIANT"] ?? "regular"))
        let pipeline = FirmwarePipeline(vmDirectory: vm, variant: variant, verbose: true)
        let restore = try pipeline.findRestoreDirectory()
        let historyURL = vm.appendingPathComponent(".firmware-history")
        let previous = Set((try? FileManager.default.contentsOfDirectory(atPath: historyURL.path)) ?? [])
        let original = try FirmwareTransaction.digest(restore)
        let report = try pipeline.patchAllStructured()
        XCTAssertTrue(report.failedRequired.isEmpty)
        XCTAssertFalse(report.isAblationRun)
        let history = try FileManager.default.contentsOfDirectory(at: historyURL, includingPropertiesForKeys: nil).filter { !previous.contains($0.lastPathComponent) }
        XCTAssertEqual(history.count, 1)
        let archive = try XCTUnwrap(history.first)
        let backup = archive.appendingPathComponent("backup").appendingPathComponent(restore.lastPathComponent)
        XCTAssertEqual(try FirmwareTransaction.digest(backup), original)
        XCTAssertFalse(FirmwareTransaction.exists(vm.appendingPathComponent(".firmware-transaction")))
        if variant == .less {
            try FirmwarePipeline.validateManifest(in: restore)
        } else if let baselinePath = env["VPHONE_C4_BASELINE_VM"] {
            let baseline = URL(fileURLWithPath: baselinePath)
            for component in pipeline.buildComponentList() {
                let base = component.inRestoreDir ? restore : vm
                let output = try pipeline.findFile(in: base, patterns: component.searchPatterns, label: component.name)
                let relative = String(output.path.dropFirst(vm.path.count + 1))
                XCTAssertEqual(try pipeline.loader.load(from: output),
                               try pipeline.loader.load(from: baseline.appendingPathComponent(relative)), component.name)
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: vm.deletingLastPathComponent().appendingPathComponent("report.json"))
    }
}

final class FirmwareTransactionCrashTests: XCTestCase {
    func testChildProcess() throws {
        guard let path = ProcessInfo.processInfo.environment["VPHONE_C4_CRASH_CHILD"] else {
            throw XCTSkip("Only invoked by the crash recovery test")
        }
        let root = URL(fileURLWithPath: path).standardizedFileURL
        guard root.lastPathComponent.hasPrefix("c4-crash-"),
              root.path.hasPrefix(FileManager.default.temporaryDirectory.standardizedFileURL.path) else {
            throw PatcherError.invalidFormat("Crash test must use its temporary fixture")
        }
        let boot = root.appendingPathComponent("AVPBooter.fixture.bin")
        let restore = root.appendingPathComponent("FixtureRestore")
        let t = try FirmwareTransaction(vmDirectory: root, inputs: [boot, restore], options: [:], inject: {
            if $0 == .afterPublish(boot.lastPathComponent) { _exit(73) }
        }, mounts: { _, _ in })
        try Data("new".utf8).write(to: t.stage.appendingPathComponent(boot.lastPathComponent))
        _ = try t.commit()
        XCTFail("Child should exit during publication")
    }

    func testRecoveryAfterProcessExitsWithoutUnwinding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("c4-crash-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("FixtureRestore"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let boot = root.appendingPathComponent("AVPBooter.fixture.bin")
        try Data("old".utf8).write(to: boot)
        let child = Process(); child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "FirmwarePatcherTests.FirmwareTransactionCrashTests/testChildProcess", Bundle(for: Self.self).bundleURL.path]
        child.environment = ProcessInfo.processInfo.environment.merging(["VPHONE_C4_CRASH_CHILD": root.path]) { _, new in new }
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run(); child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 73)
        XCTAssertEqual(try Data(contentsOf: boot), Data("new".utf8))
        XCTAssertNotNil(try FirmwareTransaction.recover(vmDirectory: root, mounts: { _, _ in }))
        XCTAssertEqual(try Data(contentsOf: boot), Data("old".utf8))
    }
}
