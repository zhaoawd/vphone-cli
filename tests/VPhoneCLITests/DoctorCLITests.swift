import ArgumentParser
import FirmwarePatcher
import Foundation
import Testing
import VPhoneCore
@testable import vphone_cli

// D5: `vphone-cli doctor` wiring — patch experiment records and the exit code.
// Uses temporary directories and injected probes; nothing boots or mounts.

private func quietProbes() -> VPhoneDiagnosticProbes {
    VPhoneDiagnosticProbes(
        environment: [:],
        operatingSystemVersion: { OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0) },
        sysctlInt: { $0 == "kern.hv_support" ? 1 : 0 },
        run: { _, _, _, _ in nil },
        hasEntitlement: { _ in true },
        executableURL: { URL(fileURLWithPath: "/x/vphone-cli") },
        findExecutable: { "/bin/" + $0 },
        processList: { "" },
        attachedImages: { [] },
        bundleLockHeld: { _ in false },
        createRunLockHeld: { _ in false },
        libraryLockHeld: { _ in false },
        processIdentity: { _ in nil },
        hostControlCapabilities: { _ in .missing },
        freeBytes: { _ in 1 << 40 })
}

struct DoctorCLITests {
    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("d5-cli-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func failedPatchRunRecordIsPatchError() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Same synthetic input as the C5 CLI test: the required AVPBooter patch fails.
        let restore = dir.appendingPathComponent("vm/iPhone17,3_26.1_23B85_Restore")
        try FileManager.default.createDirectory(at: restore, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 64).write(to: dir.appendingPathComponent("vm/AVPBooter.vresearch1.bin"))
        for name in ["iPhone-BuildManifest.plist", "BuildManifest.plist"] {
            try PropertyListSerialization.data(
                fromPropertyList: ["ProductVersion": "26.1", "ProductBuildVersion": "23B85"], format: .xml, options: 0)
                .write(to: restore.appendingPathComponent(name))
        }
        let record = dir.appendingPathComponent("records/run.json")
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        var patch = try PatchFirmwareCLI.parse(["--vm-directory", dir.appendingPathComponent("vm").path,
                                                "--record-out", record.path, "--quiet"])
        #expect(throws: (any Error).self) { try patch.run() }

        let finding = VPhoneDoctorCommand.patchRecordFinding(record, vm: "vm")
        #expect(finding.code == .patchRecordFailed)
        #expect(finding.severity == .error)
        #expect(finding.category == .patch)
        #expect(finding.evidence["status"] == "failed")
        #expect(finding.evidence["failed_required"]?.isEmpty == false)
        #expect(finding.suggestedAction == "vphone-cli fw record show \(record.path)")
    }

    @Test func invalidRecordIsReportedNotThrown() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let garbage = dir.appendingPathComponent("bad.json")
        try Data("{\"schema\": \"something-else\"}".utf8).write(to: garbage)
        let invalid = VPhoneDoctorCommand.patchRecordFinding(garbage, vm: nil)
        #expect(invalid.code == .patchRecordInvalid)
        #expect(invalid.severity == .error)
        let missing = VPhoneDoctorCommand.patchRecordFinding(dir.appendingPathComponent("none.json"), vm: nil)
        #expect(missing.code == .patchRecordInvalid)
    }

    @Test func runStageCategories() {
        #expect(VPhoneDoctorCommand.category(forRunStage: "preflight") == .input)
        #expect(VPhoneDoctorCommand.category(forRunStage: "prepare") == .input)
        #expect(VPhoneDoctorCommand.category(forRunStage: "stageInputs") == .input)
        #expect(VPhoneDoctorCommand.category(forRunStage: "patch") == .patch)
        #expect(VPhoneDoctorCommand.category(forRunStage: "commit") == .patch)
        #expect(VPhoneDoctorCommand.category(forRunStage: "record") == .patch)
    }

    @Test func reportExitCodeFollowsWorstFindingAndCommandParses() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = dir.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let command = try VPhoneDoctorCommand.parse(["missing-vm", "--library-root", library.path, "--json",
                                                     "--project-root", dir.path])
        #expect(command.json)
        let report = command.makeReport(probes: quietProbes())
        #expect(report.vm == "missing-vm")
        let notFound = try #require(report.findings.first { $0.code == .vmNotFound })
        #expect(notFound.category == .input)
        #expect(report.exitCode == 5)
        // Resources and Python are absent under the empty project root: dependency errors, not crashes.
        #expect(report.findings.contains { $0.code == .runtimeResources && $0.category == .dependency && $0.severity == .error })
        // Without check_python_runtime.py no interpreter can be verified: unknown, not a guess.
        #expect(report.findings.contains { $0.code == .pythonRuntime && $0.severity == .unknown })
        // csrutil probes return nil here: reported as unknown.
        #expect(report.findings.contains { $0.code == .sipStatus && $0.severity == .unknown })
        let object = try JSONSerialization.jsonObject(with: report.jsonData()) as? [String: Any]
        #expect((object?["summary"] as? [String: Any])?["exit_code"] as? Int == 5)
    }
}
