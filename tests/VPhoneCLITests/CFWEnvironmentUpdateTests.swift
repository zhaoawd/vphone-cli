import ArgumentParser
import Foundation
import Testing
import VPhoneCore
@testable import vphone_cli

/// `cfw update-environment` acts only on offline_update. The classification
/// itself is tested in tests/test_cfw_env_update.py.
struct CFWEnvironmentUpdateTests {
    static func report(_ classification: String, replace: [String] = [], reasons: [String] = [],
                       migration: String? = nil) -> String {
        var object: [String: Any] = ["classification": classification, "replace": replace, "reasons": reasons]
        if let migration { object["migration"] = migration }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    @Test func offlineUpdateIsTheOnlyClassificationThatReplaces() {
        #expect(VPhoneEnvironmentDecision.decide(
            checkStatus: 0, stdout: Self.report("offline_update", replace: ["libcamfix.dylib"]), stderr: "")
            == .replace(libraries: ["libcamfix.dylib"]))
        #expect(VPhoneEnvironmentDecision.decide(
            checkStatus: 0, stdout: Self.report("already_current"), stderr: "") == .nothingToDo)
        #expect(VPhoneEnvironmentDecision.decide(
            checkStatus: 0,
            stdout: Self.report("full_migration_required", reasons: ["/usr/lib/libcamfix.dylib is missing"],
                                migration: "create a new VM"),
            stderr: "")
            == .refuse(classification: "full_migration_required",
                       reasons: ["/usr/lib/libcamfix.dylib is missing", "create a new VM"], exitCode: 3))
        #expect(VPhoneEnvironmentDecision.decide(
            checkStatus: 0, stdout: Self.report("not_applicable", reasons: ["recorded variant less installs no CFW"]),
            stderr: "")
            == .refuse(classification: "not_applicable", reasons: ["recorded variant less installs no CFW"], exitCode: 3))
    }

    @Test func checkFailuresRefuseExceptUnreadableDisk() {
        #expect(VPhoneEnvironmentDecision.decide(checkStatus: 4, stdout: "", stderr: "[-] VM lock held\n")
            == .refuse(classification: nil, reasons: ["[-] VM lock held"], exitCode: 4))
        #expect(VPhoneEnvironmentDecision.decide(checkStatus: 2, stdout: "", stderr: "")
            == .refuse(classification: nil, reasons: [], exitCode: 2))
        #expect(VPhoneEnvironmentDecision.decide(checkStatus: 0, stdout: "not json", stderr: "")
            == .refuse(classification: nil, reasons: ["the eligibility check returned no classification"], exitCode: 2))
        // The root driver repeats the classification on the staged copy.
        #expect(VPhoneEnvironmentDecision.decide(checkStatus: 5, stdout: "", stderr: "[-] disk access failed: x\n")
            == .replaceAfterRootCheck(detail: "[-] disk access failed: x"))
    }

    @Test func driverRunsInEnvironmentModeWithoutAVariant() {
        let resources = VPhoneResources(base: URL(fileURLWithPath: "/res"))
        let args = VPhoneCFWUpdateEnvironmentCommand.driverArguments(
            resources: resources, bundle: URL(fileURLWithPath: "/vms/a"))
        #expect(args == ["/res/scripts/cfw_install_host.sh", "--update-environment", "/vms/a"])
        #expect(resources.cfwEnvUpdateScript.path == "/res/scripts/cfw_env_update.py")
        #expect(resources.guestComponentsStage.path == "/res/.build/guest-components-v2/stage")
    }

    @Test func commandIsRegisteredUnderCFW() throws {
        let parsed = try VPhoneCFWCommand.parseAsRoot(["update-environment", "vm-a", "--check"])
        let command = try #require(parsed as? VPhoneCFWUpdateEnvironmentCommand)
        #expect(command.check)
        #expect(command.name == "vm-a")
    }
}

/// `cfw update-environment --check` runs the read-only check through the
/// driver's elevation (sudo re-exec or --root-popup). The elevated check
/// writes its result into a private directory of the caller; the caller reads
/// it, prints it and removes the directory. The driver side is tested in
/// tests/test_cfw_env_update.py (ElevatedCheckTests).
struct CFWEnvironmentElevatedCheckTests {
    typealias Invocation = (usePopup: Bool, env: [String: String])

    static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vphone-env-check-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func wrapper(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    @Test func checkRunsTheDriverInCheckModeWithAReportPath() {
        let resources = VPhoneResources(base: URL(fileURLWithPath: "/res"))
        let args = VPhoneElevatedEnvironmentCheck.driverArguments(
            resources: resources, bundle: URL(fileURLWithPath: "/vms/a"),
            report: URL(fileURLWithPath: "/private/tmp/x/report.json"))
        #expect(args == ["/res/scripts/cfw_install_host.sh", "--check-environment",
                         "--report", "/private/tmp/x/report.json", "/vms/a"])
    }

    @Test(arguments: [false, true]) func reportIsReadAndTheDirectoryRemoved(rootPopup: Bool) throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let resources = VPhoneResources(base: URL(fileURLWithPath: "/res"))
        var seen: (args: [String], invocation: Invocation, mode: Int)?
        let outcome = try VPhoneElevatedEnvironmentCheck.run(
            resources: resources, bundle: URL(fileURLWithPath: "/vms/a"),
            scriptEnv: ["VPHONE_PYTHON": "/py", "VPHONE_GUEST_COMPONENTS": "/stage"], rootPopup: rootPopup,
            temporaryDirectory: base
        ) { args, invocation in
            let report = URL(fileURLWithPath: args[3])
            let mode = (try FileManager.default.attributesOfItem(
                atPath: report.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
            seen = (args, invocation, mode)
            try Self.wrapper(["exit_code": 0, "error": NSNull(),
                              "report": ["classification": "full_migration_required", "reasons": ["x"]]])
                .write(to: report)
            return 0
        }
        let call = try #require(seen)
        #expect(call.mode == 0o700)
        #expect(URL(fileURLWithPath: call.args[3]).deletingLastPathComponent()
            .deletingLastPathComponent().standardizedFileURL.path == base.standardizedFileURL.path)
        #expect(call.invocation.usePopup == rootPopup)
        #expect(call.invocation.env[VPhoneInvoker.uidKey] == String(getuid()))
        #expect(call.invocation.env[VPhoneInvoker.gidKey] == String(getgid()))
        #expect(call.invocation.env["VPHONE_GUEST_COMPONENTS"] == "/stage")
        if rootPopup {
            #expect(call.invocation.env["SUDO_UID"] == nil)
            #expect(call.invocation.env["SUDO_USER"] == NSUserName())
        }
        #expect(outcome.exitCode == 0)
        let printed = try #require(outcome.report)
        let decoded = try JSONSerialization.jsonObject(with: Data(printed.utf8)) as? [String: Any]
        #expect(decoded?["classification"] as? String == "full_migration_required")
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
    }

    @Test func failureCarriesTheStageAndAdvice() throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let outcome = try VPhoneElevatedEnvironmentCheck.run(
            resources: VPhoneResources(base: URL(fileURLWithPath: "/res")), bundle: URL(fileURLWithPath: "/vms/a"),
            scriptEnv: [:], rootPopup: true, temporaryDirectory: base
        ) { args, _ in
            try Self.wrapper(["exit_code": 5, "report": NSNull(),
                              "error": ["kind": "disk_access", "stage": "mount",
                                        "message": "mount_apfs timed out after 30 s", "advice": "inspect mount"]])
                .write(to: URL(fileURLWithPath: args[3]))
            return 1   // osascript reports any failure as 1; the report carries the real code
        }
        #expect(outcome.exitCode == 5)
        #expect(outcome.report == nil)
        #expect(outcome.message?.contains("stage mount") == true)
        #expect(outcome.message?.contains("inspect mount") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
    }

    @Test func missingReportIsAFailureThatNamesTheElevationStep() throws {
        let base = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: base) }
        let outcome = try VPhoneElevatedEnvironmentCheck.run(
            resources: VPhoneResources(base: URL(fileURLWithPath: "/res")), bundle: URL(fileURLWithPath: "/vms/a"),
            scriptEnv: [:], rootPopup: true, temporaryDirectory: base
        ) { _, _ in 1 }
        #expect(outcome.exitCode == 1)
        #expect(outcome.report == nil)
        #expect(outcome.message?.contains("no report") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path).isEmpty)
    }
}

/// Run the real CLI with a report-writing driver in a temporary resource tree.
/// The stand-in never elevates privileges, mounts a disk or contacts a guest.
struct CFWEnvironmentCheckOutputTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    @Test(arguments: [Int32(0), Int32(5)])
    func checkKeepsStdoutMachineReadable(exitCode: Int32) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cfw-output-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let scripts = root.appendingPathComponent("scripts")
        try fm.createDirectory(at: scripts, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: scripts.appendingPathComponent("check_python_runtime.py"),
            withDestinationURL: Self.repo.appendingPathComponent("scripts/check_python_runtime.py"))
        let driver = scripts.appendingPathComponent("cfw_install_host.sh")
        try #"""
        #!/bin/zsh
        set -euo pipefail
        [[ "$1" == --check-environment && "$2" == --report ]]
        if [[ "$CHECK_TEST_EXIT" == 0 ]]; then
          /bin/cat > "$3" <<'JSON'
        {"exit_code":0,"error":null,"report":{"classification":"already_current","reasons":[]}}
        JSON
        else
          /bin/cat > "$3" <<'JSON'
        {"exit_code":5,"report":null,"error":{"stage":"mount","message":"fixture failure","advice":"inspect fixture"}}
        JSON
        fi
        echo "check driver diagnostic" >&2
        exit "$CHECK_TEST_EXIT"
        """#.write(to: driver, atomically: true, encoding: .utf8)
        let library = VPhoneLibrary(root: root.appendingPathComponent("VMs"))
        let rom = root.appendingPathComponent("rom.bin")
        try Data([1]).write(to: rom)
        _ = try VPhoneBundleOps.create(.init(name: "test", cpuCount: 2, memoryMB: 2048,
            diskSizeGB: 0, romSource: rom, sepromSource: rom), in: library)
        let result = try VPhoneProcessRunner.runCapturing(
            Self.repo.appendingPathComponent(".build/debug/vphone-cli"),
            ["cfw", "update-environment", "test", "--check", "--library-root", library.root.path,
             "--project-root", root.path],
            env: ["VPHONE_PYTHON": Self.repo.appendingPathComponent(".venv/bin/python3").path,
                  "CHECK_TEST_EXIT": String(exitCode)], timeout: 20)
        #expect(!result.timedOut)
        #expect(result.exitCode == exitCode)
        #expect(result.stderr.contains("check driver diagnostic"))
        #expect(result.stderr.contains("read-only check runs as root"))
        if exitCode == 0 {
            let report = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            #expect(report?["classification"] as? String == "already_current")
        } else {
            #expect(result.stdout.isEmpty)
            #expect(result.stderr.contains("stage mount"))
        }
    }
}
