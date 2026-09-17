import Darwin
import Foundation
import Testing
@testable import VPhoneCore

// D5: `vphone-cli doctor` checks with injected host observations and
// temporary libraries. Nothing here boots, mounts, restores or uses sudo.

// MARK: - Fixture

private final class DiagnosticsWorkspace {
    let root: URL
    let base: URL
    let library: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("d5-" + UUID().uuidString)
        base = root.appendingPathComponent("res")
        library = root.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let resources = VPhoneResources(base: base, environment: [:])
        for url in resources.runtimeResources {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let python = base.appendingPathComponent(".venv/bin/python3")
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: python)
        chmod(python.path, 0o755)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func resources(environment: [String: String] = [:]) -> VPhoneResources {
        VPhoneResources(base: base, environment: environment)
    }

    @discardableResult
    func makeBundle(_ name: String = "vm", machineIdentifier: Data = Data([1, 2, 3]), disk: Bool = true) throws -> URL {
        let url = library.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try VPhoneVirtualMachineManifest(machineIdentifier: machineIdentifier, cpuCount: 2, memorySize: 1 << 30,
                                         romImages: nil).write(to: url.appendingPathComponent("config.plist"))
        if disk { try Data("disk".utf8).write(to: url.appendingPathComponent("Disk.img")) }
        return url
    }

    func diagnostics(_ probes: VPhoneDiagnosticProbes, environment: [String: String] = [:]) -> VPhoneDiagnostics {
        VPhoneDiagnostics(resources: resources(environment: environment), library: VPhoneLibrary(root: library), probes: probes)
    }
}

private let pythonOK = #"{"ok": true, "version": "3.14.4", "lock": "/x/dependencies/python-darwin-arm64-3.14.lock", "packages": {"capstone": "5"}}"#

/// Every probe answers as a healthy host with no VM running.
private func healthyProbes() -> VPhoneDiagnosticProbes {
    VPhoneDiagnosticProbes(
        environment: [:],
        operatingSystemVersion: { OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0) },
        sysctlInt: { $0 == "kern.hv_support" ? 1 : 0 },
        run: { executable, args, _, _ in
            if args.contains("allow-research-guests") {
                return VPhoneProcessResult(exitCode: 0, stdout: "Allow Research Guests status: enabled\n", stderr: "")
            }
            if executable.path == "/usr/bin/csrutil" {
                return VPhoneProcessResult(exitCode: 0, stdout: "System Integrity Protection status: disabled.\n", stderr: "")
            }
            return VPhoneProcessResult(exitCode: 0, stdout: pythonOK, stderr: "")
        },
        hasEntitlement: { _ in true },
        executableURL: { URL(fileURLWithPath: "/Applications/vphone-cli.app/Contents/MacOS/vphone-cli") },
        findExecutable: { "/opt/homebrew/bin/" + $0 },
        processList: { "" },
        attachedImages: { [] },
        bundleLockHeld: { _ in false },
        createRunLockHeld: { _ in false },
        libraryLockHeld: { _ in false },
        processIdentity: { _ in nil },
        hostControlCapabilities: { _ in .missing },
        freeBytes: { _ in 500 * 1024 * 1024 * 1024 })
}

private func find(_ findings: [VPhoneDiagnosticFinding], _ code: VPhoneDiagnosticCode) -> VPhoneDiagnosticFinding? {
    findings.first { $0.code == code }
}

private func writeRuntimeRecord(_ bundle: URL, operation: String, pid: Int32) throws {
    try VPhoneVMRuntimeState(bundleIdentifier: "1:2", bundlePath: bundle.path, pid: pid, instanceID: "i",
                             startedAt: Date(timeIntervalSince1970: 1_800_000_000), operation: operation).write(in: bundle)
}

private func checkpoint(bundle: URL, variant: String = "jb", upTo stage: VPhoneCreateStage, status: VPhoneCreateStageStatus,
                        error: String? = nil, reason: String? = nil) -> VPhoneCreateCheckpoint {
    let options = VPhoneCreateEffectiveOptions(
        variant: variant, iphoneSource: nil, cloudosSource: nil, spoofBuild: nil, forceDscMaxSlide: false,
        enableFrida: false, cpuCount: 2, memoryMb: 1024, diskSizeGb: 8)
    var checkpoint = VPhoneCreateCheckpoint(
        identity: .init(name: bundle.lastPathComponent, path: bundle.path, directoryId: "1:2"), options: options,
        tool: .init(executableSha256: nil, stageContractVersion: 1), now: Date(timeIntervalSince1970: 1_800_000_000))
    for index in checkpoint.stages.indices where checkpoint.stages[index].status != .notApplicable {
        let record = checkpoint.stages[index].stage
        guard record <= stage else { break }
        checkpoint.stages[index].attemptId = checkpoint.attemptId
        checkpoint.stages[index].startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        if record < stage || status == .succeeded || status == .unverified {
            checkpoint.stages[index].status = record < stage ? .succeeded : status
            checkpoint.stages[index].executorResult = "completed"
            checkpoint.stages[index].verifierVersion = "test"
            checkpoint.stages[index].finishedAt = Date(timeIntervalSince1970: 1_800_000_100)
            if record == stage, status == .unverified { checkpoint.stages[index].reason = reason ?? "no evidence" }
        } else {
            checkpoint.stages[index].status = status
            checkpoint.stages[index].error = error
            checkpoint.stages[index].reason = reason
        }
    }
    return checkpoint
}

private func writeCheckpoint(_ checkpoint: VPhoneCreateCheckpoint, to bundle: URL) throws {
    try checkpoint.validate()
    let directory = bundle.appendingPathComponent(VPhoneCreateCheckpointStore.directoryName)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try VPhoneCreateJSON.encoder.encode(checkpoint).write(to: directory.appendingPathComponent(VPhoneCreateCheckpointStore.fileName))
}

// MARK: - Severity, schema

struct DiagnosticsReportTests {
    @Test func severityMapsToExitCodeAndUnknownOutranksWarning() {
        #expect(VPhoneDiagnosticSeverity.ok.exitCode == 0)
        #expect(VPhoneDiagnosticSeverity.warning.exitCode == 3)
        #expect(VPhoneDiagnosticSeverity.unknown.exitCode == 4)
        #expect(VPhoneDiagnosticSeverity.error.exitCode == 5)
        #expect([VPhoneDiagnosticSeverity.warning, .unknown, .ok].max() == .unknown)
        let root = URL(fileURLWithPath: "/lib")
        let warning = VPhoneDiagnosticReport(vm: nil, libraryRoot: root, toolCommit: nil, findings: [
            .init(.environment, .sipStatus, .warning, "w"), .init(.dependency, .hostTools, .ok, "o"),
        ])
        #expect(warning.exitCode == 3)
        let unknown = VPhoneDiagnosticReport(vm: nil, libraryRoot: root, toolCommit: nil, findings: [
            .init(.environment, .sipStatus, .warning, "w"), .init(.internal, .checkFailed, .unknown, "u"),
        ])
        #expect(unknown.exitCode == 4)
        let error = VPhoneDiagnosticReport(vm: nil, libraryRoot: root, toolCommit: nil, findings: [
            .init(.internal, .checkFailed, .unknown, "u"), .init(.input, .vmNotFound, .error, "e"),
        ])
        #expect(error.exitCode == 5)
        #expect(VPhoneDiagnosticReport(vm: nil, libraryRoot: root, toolCommit: nil, findings: []).exitCode == 0)
    }

    @Test func jsonSchemaIsStable() throws {
        let report = VPhoneDiagnosticReport(
            vm: "vm", libraryRoot: URL(fileURLWithPath: "/lib"), toolCommit: "abc",
            findings: [.init(.patch, .firmwareTransactionPending, .error, "m", evidence: ["phase": "staged"],
                             action: "vphone-cli fw patch vm --recover", vm: "vm"),
                       .init(.environment, .macosVersion, .ok, "ok")],
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let object = try #require(try JSONSerialization.jsonObject(with: report.jsonData()) as? [String: Any])
        #expect(Set(object.keys) == ["schema", "schema_version", "generated_at", "read_only", "scope", "tool_commit", "summary", "findings"])
        #expect(object["schema"] as? String == "vphone.diagnostics")
        #expect(object["schema_version"] as? Int == 1)
        #expect(object["read_only"] as? Bool == true)
        #expect(object["generated_at"] as? String == "2027-01-15T08:00:00Z")
        let scope = try #require(object["scope"] as? [String: Any])
        #expect(Set(scope.keys) == ["vm", "library_root"])
        let summary = try #require(object["summary"] as? [String: Any])
        #expect(Set(summary.keys) == ["worst_severity", "exit_code", "counts"])
        #expect(summary["exit_code"] as? Int == 5)
        #expect(summary["counts"] as? [String: Int] == ["ok": 1, "warning": 0, "unknown": 0, "error": 1])
        let findings = try #require(object["findings"] as? [[String: Any]])
        // Grouped by category order: environment first.
        #expect(findings.map { $0["code"] as? String } == ["macos_version", "firmware_transaction_pending"])
        for finding in findings {
            #expect(Set(finding.keys) == ["category", "code", "severity", "message", "evidence", "suggested_action", "vm"])
        }
        #expect(findings[0]["suggested_action"] is NSNull)
        #expect(findings[0]["vm"] is NSNull)
    }

    @Test func vocabularyIsStable() {
        #expect(VPhoneDiagnosticCategory.allCases.map(\.rawValue) ==
            ["environment", "dependency", "occupancy", "input", "patch", "restore", "guest_runtime", "internal"])
        #expect(VPhoneDiagnosticSeverity.allCases.map(\.rawValue) == ["ok", "warning", "unknown", "error"])
        #expect(VPhoneDiagnosticCode.allCases.map(\.rawValue) == [
            "macos_version", "hypervisor_support", "nested_virtualization", "sip_status", "research_guests",
            "signing_entitlements", "disk_space", "python_runtime", "runtime_resources", "host_tools",
            "library_root", "bundle_unreadable", "vm_not_found", "vm_manifest_invalid", "vm_files",
            "create_checkpoint_absent", "create_checkpoint_invalid", "create_succeeded", "create_incomplete",
            "create_interrupted", "create_stage_failed", "create_cancelled", "create_completed_unverified",
            "create_recovery_required", "firmware_transaction_pending", "firmware_history", "patch_record",
            "patch_record_failed", "patch_record_running", "patch_record_invalid", "restore_state", "library_lock",
            "running_vm_processes", "vm_running", "vm_idle", "vm_operation_in_progress", "vm_lock_holder_unknown",
            "vm_boot_process_without_lock", "create_run_in_progress", "attached_images", "cfw_mount_residue",
            "guest_not_running", "guest_connected", "guest_disconnected", "host_control_socket_missing",
            "host_control_unreachable", "host_control_capabilities_unavailable", "check_failed",
        ])
    }

    @Test func stageCategoriesSeparateInputPatchRestoreAndGuest() {
        #expect(VPhoneDiagnostics.category(for: .prepare) == .input)
        #expect(VPhoneDiagnostics.category(for: .patch) == .patch)
        #expect(VPhoneDiagnostics.category(for: .cfw) == .patch)
        #expect(VPhoneDiagnostics.category(for: .restore) == .restore)
        #expect(VPhoneDiagnostics.category(for: .firstBoot) == .guestRuntime)
        #expect(VPhoneDiagnostics.category(for: .jbFinalize) == .guestRuntime)
        #expect(VPhoneDiagnostics.category(for: .verification) == .guestRuntime)
    }
}

// MARK: - Redaction

struct DiagnosticsRedactionTests {
    let redactor = VPhoneDiagnosticRedactor(homePath: "/Users/alice")

    @Test func redactsCredentialsQueriesSecretsAndHome() {
        let url = redactor.redact("download https://bob:hunter2@cdn.example.com/a/b.ipsw?token=s3cr3t#frag failed")
        #expect(url == "download https://<redacted>@cdn.example.com/a/b.ipsw?<redacted>#<redacted> failed")
        #expect(redactor.redact("vphone-cli vm create x --sudo-password hunter2 -v") == "vphone-cli vm create x --sudo-password <redacted> -v")
        #expect(redactor.redact("--sudo-password=hunter2") == "--sudo-password=<redacted>")
        #expect(redactor.redact("GITHUB_TOKEN=ghp_abc and password: pw1") == "GITHUB_TOKEN=<redacted> and password: <redacted>")
        #expect(redactor.redact("Authorization: Bearer abc.def") == "Authorization: Bearer <redacted>")
        #expect(redactor.redact("/Users/alice/.vphone/VMs and /Users/alicex/y and /Users/alice") == "~/.vphone/VMs and /Users/alicex/y and ~")
        #expect(redactor.redact("https://updates.cdn-apple.com/x/iPhone.ipsw") == "https://updates.cdn-apple.com/x/iPhone.ipsw")
    }

    @Test func reportRedactsEvidenceMessagesAndActions() throws {
        let finding = VPhoneDiagnosticFinding(
            .input, .createStageFailed, .error, "fetch https://u:p4ss@host/f?sig=zzz failed",
            evidence: ["sudo_password": "hunter2", "askpass_helper": "/Users/alice/ask.sh", "path": "/Users/alice/vm",
                       "last_error": "curl -H 'Authorization: Bearer tok123' https://host/x?key=abc"],
            action: "vphone-cli vm create --resume vm --sudo-password hunter2")
        let report = VPhoneDiagnosticReport(vm: "vm", libraryRoot: URL(fileURLWithPath: "/Users/alice/lib"),
                                            toolCommit: nil, findings: [finding], redactor: redactor)
        let json = String(decoding: try report.jsonData(), as: UTF8.self)
        for secret in ["hunter2", "p4ss", "zzz", "tok123", "key=abc", "/Users/alice", "ask.sh"] {
            #expect(!json.contains(secret), "leaked \(secret)")
            #expect(!report.text.contains(secret), "leaked \(secret) in text")
        }
        #expect(json.contains("~/vm"))
    }

    @Test func checkpointErrorWithCredentialsIsRedactedEndToEnd() throws {
        let workspace = try DiagnosticsWorkspace()
        let bundle = try workspace.makeBundle()
        try writeCheckpoint(checkpoint(bundle: bundle, upTo: .prepare, status: .failed,
                                       error: "download https://user:pa55@example.com/i.ipsw?X-Amz-Signature=deadbeef failed"),
                            to: bundle)
        let findings = workspace.diagnostics(healthyProbes()).run(vm: "vm")
        let report = VPhoneDiagnosticReport(vm: "vm", libraryRoot: workspace.library, toolCommit: nil, findings: findings)
        let json = String(decoding: try report.jsonData(), as: UTF8.self)
        #expect(!json.contains("pa55"))
        #expect(!json.contains("deadbeef"))
        #expect(json.contains("https://<redacted>@example.com/i.ipsw?<redacted>"))
    }

    @Test func environmentOverrideValueIsNeverReported() throws {
        let workspace = try DiagnosticsWorkspace()
        let secretPath = workspace.root.appendingPathComponent("private-token-dir/python3").path
        var probes = healthyProbes()
        probes.environment = ["VPHONE_PYTHON": secretPath]
        let finding = try #require(find(workspace.diagnostics(probes, environment: probes.environment).run(vm: nil), .pythonRuntime))
        #expect(finding.severity == .error)
        #expect(!"\(finding)".contains("private-token-dir"))
        #expect(finding.evidence["candidates"]?.contains("(from VPHONE_PYTHON)") == true)
    }
}

// MARK: - Host checks

struct DiagnosticsHostTests {
    @Test func healthyHostIsAllOk() throws {
        let workspace = try DiagnosticsWorkspace()
        let findings = workspace.diagnostics(healthyProbes()).run(vm: nil)
        #expect(findings.allSatisfy { $0.severity == .ok }, "\(findings.filter { $0.severity != .ok })")
        #expect(find(findings, .pythonRuntime)?.evidence["source"] == "dev_venv")
        #expect(find(findings, .pythonRuntime)?.evidence["lock"] == "python-darwin-arm64-3.14.lock")
    }

    @Test func environmentProblemsAreEnvironmentCategory() throws {
        let workspace = try DiagnosticsWorkspace()
        var probes = healthyProbes()
        probes.sysctlInt = { $0 == "kern.hv_vmm_present" ? 1 : nil }
        probes.operatingSystemVersion = { OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 0) }
        probes.run = { _, args, _, _ in
            args.contains("allow-research-guests")
                ? VPhoneProcessResult(exitCode: 0, stdout: "Allow Research Guests status: disabled\n", stderr: "") : nil
        }
        probes.hasEntitlement = { $0 != "com.apple.private.virtualization.security-research" }
        let findings = workspace.diagnostics(probes).hostFindings(.init(processList: nil, attachedImages: nil))
        #expect(find(findings, .macosVersion)?.severity == .error)
        #expect(find(findings, .nestedVirtualization)?.severity == .error)
        #expect(find(findings, .hypervisorSupport)?.severity == .unknown)
        #expect(find(findings, .sipStatus)?.severity == .unknown)
        #expect(find(findings, .researchGuests)?.severity == .error)
        let signing = try #require(find(findings, .signingEntitlements))
        #expect(signing.severity == .error)
        #expect(signing.evidence["missing"] == "com.apple.private.virtualization.security-research")
        #expect(signing.suggestedAction?.contains("make build") == true)
        for code in [VPhoneDiagnosticCode.macosVersion, .nestedVirtualization, .researchGuests, .signingEntitlements] {
            #expect(find(findings, code)?.category == .environment)
        }
        // Process list unavailable is reported, not guessed.
        #expect(find(findings, .runningVMProcesses)?.severity == .unknown)
    }

    @Test func unreadableEntitlementsAreUnknownAndCustomSIPIsWarning() throws {
        let workspace = try DiagnosticsWorkspace()
        var probes = healthyProbes()
        probes.hasEntitlement = { _ in nil }
        probes.run = { executable, _, _, _ in
            executable.path == "/usr/bin/csrutil"
                ? VPhoneProcessResult(exitCode: 0, stdout: "System Integrity Protection status: unknown (Custom Configuration).\n\n\tKext Signing: enabled\n\tDebugging Restrictions: disabled\n", stderr: "") : nil
        }
        let findings = workspace.diagnostics(probes).hostFindings(.init(processList: "", attachedImages: []))
        #expect(find(findings, .signingEntitlements)?.severity == .unknown)
        let sip = try #require(find(findings, .sipStatus))
        #expect(sip.severity == .warning)
        #expect(sip.evidence["Kext Signing"] == "enabled")
        #expect(find(findings, .researchGuests)?.severity == .unknown)
    }

    @Test func missingPythonRuntimeIsDependencyError() throws {
        let workspace = try DiagnosticsWorkspace()
        try FileManager.default.removeItem(at: workspace.base.appendingPathComponent(".venv"))
        // Point the managed venv into the workspace so a real ~/.vphone/venv is not found.
        let environment = ["VPHONE_VENV_DIR": workspace.root.appendingPathComponent("venv").path]
        let finding = try #require(find(workspace.diagnostics(healthyProbes(), environment: environment).run(vm: nil), .pythonRuntime))
        #expect(finding.category == .dependency)
        #expect(finding.severity == .error)
        #expect(finding.suggestedAction?.contains("vphone-cli setup") == true)
        #expect(finding.evidence["candidates"]?.contains("dev_venv: not an executable") == true)
    }

    @Test func missingRuntimeCheckScriptMakesPythonUnknown() throws {
        let workspace = try DiagnosticsWorkspace()
        try FileManager.default.removeItem(at: workspace.resources().pythonRuntimeCheckScript)
        let finding = workspace.diagnostics(healthyProbes()).pythonRuntime()
        #expect(finding.category == .dependency)
        #expect(finding.severity == .unknown)
    }

    @Test func pythonLockMismatchNamesPackagesOnly() throws {
        let workspace = try DiagnosticsWorkspace()
        var probes = healthyProbes()
        probes.run = { _, _, env, _ in
            #expect(env?["PYTHONDONTWRITEBYTECODE"] == "1")
            return VPhoneProcessResult(exitCode: 1, stdout: #"{"ok": false, "differences": {"capstone": {"expected": "5", "actual": "6"}}, "packages": {"secretpkg": "1"}}"#, stderr: "")
        }
        let finding = workspace.diagnostics(probes).pythonRuntime()
        #expect(finding.severity == .error)
        #expect(finding.evidence["candidates"]?.contains("installed packages differ from the lock: capstone") == true)
        #expect(!"\(finding)".contains("secretpkg"))
    }

    @Test func missingResourcesAreDependencyError() throws {
        let workspace = try DiagnosticsWorkspace()
        let resources = workspace.resources()
        try FileManager.default.removeItem(at: resources.resourceArchivesDir.appendingPathComponent("cfw_jb_input.tar.zst"))
        try Data().write(to: resources.toolsBinDir.appendingPathComponent("trustcache"))
        let finding = workspace.diagnostics(healthyProbes()).runtimeResources()
        #expect(finding.category == .dependency)
        #expect(finding.severity == .error)
        #expect(finding.evidence["missing"] == "scripts/resources/cfw_jb_input.tar.zst, .tools/bin/trustcache")
    }

    @Test func missingToolsAreDependencyErrorOrWarning() throws {
        let workspace = try DiagnosticsWorkspace()
        var probes = healthyProbes()
        probes.findExecutable = { ["ipsw", "aria2c", "curl", "wget"].contains($0) ? nil : "/bin/" + $0 }
        let missing = workspace.diagnostics(probes).hostTools()
        #expect(missing.category == .dependency)
        #expect(missing.severity == .error)
        #expect(missing.message.contains("ipsw"))
        #expect(missing.message.contains("aria2c|curl|wget"))
        probes.findExecutable = { $0 == "zstd" ? nil : "/bin/" + $0 }
        let jailbreakOnly = workspace.diagnostics(probes).hostTools()
        #expect(jailbreakOnly.severity == .warning)
        #expect(jailbreakOnly.evidence["zstd"] == "missing")
    }

    @Test func lowDiskSpaceIsWarning() throws {
        let workspace = try DiagnosticsWorkspace()
        var probes = healthyProbes()
        probes.freeBytes = { _ in 10 * 1024 * 1024 * 1024 }
        #expect(workspace.diagnostics(probes).diskSpace().severity == .warning)
        probes.freeBytes = { _ in nil }
        #expect(workspace.diagnostics(probes).diskSpace().severity == .unknown)
    }
}

// MARK: - VM checks

struct DiagnosticsVMTests {
    private func vm(_ workspace: DiagnosticsWorkspace, _ probes: VPhoneDiagnosticProbes = healthyProbes(),
                    snapshot: VPhoneDiagnostics.Snapshot = .init(processList: "", attachedImages: []),
                    probeGuest: Bool = true) -> [VPhoneDiagnosticFinding] {
        workspace.diagnostics(probes).vmFindings(name: "vm", snapshot: snapshot, probeGuest: probeGuest)
    }

    @Test func missingVMAndFilesAreInputErrors() throws {
        let workspace = try DiagnosticsWorkspace()
        let notFound = try #require(find(vm(workspace), .vmNotFound))
        #expect(notFound.category == .input)
        #expect(notFound.severity == .error)

        try workspace.makeBundle(disk: false)
        let files = try #require(find(vm(workspace), .vmFiles))
        #expect(files.category == .input)
        #expect(files.severity == .error)
        #expect(files.evidence["missing"] == "Disk.img")

        try Data("not a plist".utf8).write(to: workspace.library.appendingPathComponent("vm/config.plist"))
        let manifest = try #require(find(vm(workspace), .vmManifestInvalid))
        #expect(manifest.category == .input)
        #expect(manifest.severity == .error)
    }

    @Test func unrestoredBundleIsRestoreWarning() throws {
        let workspace = try DiagnosticsWorkspace()
        try workspace.makeBundle(machineIdentifier: Data())
        let restore = try #require(find(vm(workspace), .restoreState))
        #expect(restore.category == .restore)
        #expect(restore.severity == .warning)
        #expect(restore.evidence["machine_identifier"] == "absent")
    }

    @Test func restoredBundleReportsVersions() throws {
        let workspace = try DiagnosticsWorkspace()
        let bundle = try workspace.makeBundle()
        try VPhoneRestoreInfo(ios: .init(version: "26.1", build: "23B85"), cloudOS: .init(version: "26.1", build: "23B85"),
                              variant: "jb").write(toBundle: VPhoneBundle.load(at: bundle))
        let restore = try #require(find(vm(workspace), .restoreState))
        #expect(restore.severity == .ok)
        #expect(restore.evidence["variant"] == "jb")
    }

    @Test func corruptCheckpointIsInputError() throws {
        let workspace = try DiagnosticsWorkspace()
        let bundle = try workspace.makeBundle()
        let directory = bundle.appendingPathComponent(VPhoneCreateCheckpointStore.directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"schema_version\": 1, \"creation_id\": ".utf8).write(to: directory.appendingPathComponent("checkpoint.json"))
        let finding = try #require(find(vm(workspace), .createCheckpointInvalid))
        #expect(finding.category == .input)
        #expect(finding.severity == .error)
        #expect(finding.suggestedAction == "vphone-cli vm create-status vm")

        try Data(#"{"schema_version": 9}"#.utf8).write(to: directory.appendingPathComponent("checkpoint.json"))
        #expect(find(vm(workspace), .createCheckpointInvalid)?.evidence["reason"]?.contains("schema_version 9") == true)
    }

    @Test func absentCheckpointIsOk() throws {
        let workspace = try DiagnosticsWorkspace()
        try workspace.makeBundle()
        #expect(find(vm(workspace), .createCheckpointAbsent)?.severity == .ok)
    }

    @Test func failedCreateStageCategoryFollowsStage() throws {
        let cases: [(VPhoneCreateStage, VPhoneDiagnosticCategory)] = [
            (.prepare, .input), (.patch, .patch), (.restore, .restore), (.cfw, .patch), (.firstBoot, .guestRuntime),
        ]
        for (stage, category) in cases {
            let workspace = try DiagnosticsWorkspace()
            let bundle = try workspace.makeBundle()
            try writeCheckpoint(checkpoint(bundle: bundle, upTo: stage, status: .failed, error: "\(stage.rawValue) broke"), to: bundle)
            let finding = try #require(find(vm(workspace), .createStageFailed))
            #expect(finding.category == category, "\(stage)")
            #expect(finding.severity == .error)
            #expect(finding.evidence["stage"] == stage.rawValue)
            #expect(finding.evidence["last_error"] == "\(stage.rawValue) broke")
            #expect(finding.suggestedAction == "vphone-cli vm create --resume vm")
        }
    }

    @Test func interruptedUnverifiedAndSucceededCreates() throws {
        let workspace = try DiagnosticsWorkspace()
        let bundle = try workspace.makeBundle()
        try writeCheckpoint(checkpoint(bundle: bundle, upTo: .restore, status: .running), to: bundle)
        let interrupted = try #require(find(vm(workspace), .createInterrupted))
        #expect(interrupted.category == .restore)
        #expect(interrupted.severity == .warning)
        // The same stored state while a run holds the run lock is progress, not an interruption.
        var live = healthyProbes()
        live.createRunLockHeld = { _ in true }
        let running = vm(workspace, live)
        #expect(find(running, .createInterrupted) == nil)
        #expect(find(running, .createRunInProgress)?.evidence["running_stage"] == "restore")
        #expect(find(running, .createRunInProgress)?.category == .occupancy)

        try writeCheckpoint(checkpoint(bundle: bundle, variant: "regular", upTo: .verification, status: .unverified,
                                       reason: "less boot has no success marker"), to: bundle)
        let unverified = try #require(find(vm(workspace), .createCompletedUnverified))
        #expect(unverified.category == .guestRuntime)
        #expect(unverified.evidence["unverified_stages"] == "verification")

        try writeCheckpoint(checkpoint(bundle: bundle, variant: "regular", upTo: .verification, status: .succeeded), to: bundle)
        #expect(find(vm(workspace), .createSucceeded)?.severity == .ok)

        var recovery = checkpoint(bundle: bundle, upTo: .patch, status: .failed, error: "pending")
        recovery.recoveryRequired = .init(kind: "firmware_transaction", stage: .patch, detail: "uncommitted", action: "vphone-cli fw patch vm --recover")
        try writeCheckpoint(recovery, to: bundle)
        let required = try #require(find(vm(workspace), .createRecoveryRequired))
        #expect(required.category == .patch)
        #expect(required.suggestedAction == "vphone-cli fw patch vm --recover")
    }

    @Test func pendingFirmwareTransactionIsPatchError() throws {
        let workspace = try DiagnosticsWorkspace()
        let bundle = try workspace.makeBundle()
        let transaction = bundle.appendingPathComponent(".firmware-transaction")
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        try Data(#"{"phase": "publishing", "failure": "disk full", "options": {"variant": "jb"}}"#.utf8)
            .write(to: transaction.appendingPathComponent("journal.json"))
        let pending = try #require(find(vm(workspace), .firmwareTransactionPending))
        #expect(pending.category == .patch)
        #expect(pending.severity == .error)
        #expect(pending.evidence["phase"] == "publishing")
        #expect(pending.evidence["failure"] == "disk full")
        #expect(pending.suggestedAction == "vphone-cli fw patch vm --recover")

        // While fw patch itself holds the bundle, the transaction is expected.
        try writeRuntimeRecord(bundle, operation: VPhoneVMOperation.fwPatch, pid: getpid())
        var probes = healthyProbes()
        probes.bundleLockHeld = { _ in true }
        probes.processIdentity = { VPhoneProcessIdentity(pid: $0, startedAt: 1, uid: 501) }
        let running = vm(workspace, probes)
        #expect(find(running, .firmwareTransactionPending)?.severity == .ok)
        #expect(find(running, .vmOperationInProgress)?.severity == .warning)
    }

    @Test func committedHistoryIsReported() throws {
        let workspace = try DiagnosticsWorkspace()
        let bundle = try workspace.makeBundle()
        let archive = bundle.appendingPathComponent(".firmware-history/ce394982")
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        try Data(#"{"phase": "committed", "options": {"variant": "exp"}}"#.utf8).write(to: archive.appendingPathComponent("journal.json"))
        let history = try #require(find(vm(workspace), .firmwareHistory))
        #expect(history.severity == .ok)
        #expect(history.evidence["latest_variant"] == "exp")
    }

    @Test func staleRuntimeRecordWithFreeLockIsIdle() throws {
        let workspace = try DiagnosticsWorkspace()
        let bundle = try workspace.makeBundle()
        try writeRuntimeRecord(bundle, operation: VPhoneVMOperation.boot, pid: 999_999)
        let findings = vm(workspace)
        let idle = try #require(find(findings, .vmIdle))
        #expect(idle.category == .occupancy)
        #expect(idle.severity == .ok)
        #expect(idle.evidence["record_pid_alive"] == "false")
        #expect(idle.evidence["record_operation"] == "boot")
        #expect(find(findings, .guestNotRunning)?.severity == .ok)
    }

    @Test func heldLockWithDeadRecordIsHolderUnknown() throws {
        let workspace = try DiagnosticsWorkspace()
        let bundle = try workspace.makeBundle()
        try writeRuntimeRecord(bundle, operation: VPhoneVMOperation.boot, pid: 999_999)
        var probes = healthyProbes()
        probes.bundleLockHeld = { _ in true }
        probes.processIdentity = { VPhoneProcessIdentity(pid: $0, startedAt: 1, uid: 501, isZombie: true) }
        let finding = try #require(find(vm(workspace, probes), .vmLockHolderUnknown))
        #expect(finding.severity == .warning)
        #expect(finding.category == .occupancy)
    }

    @Test func bootProcessWithoutLockIsOccupancyError() throws {
        let workspace = try DiagnosticsWorkspace()
        let bundle = try workspace.makeBundle()
        // A launcher-relative spelling with `..` still names this bundle.
        let spelled = bundle.deletingLastPathComponent().path + "/../lib/vm/config.plist"
        let ps = "  4242 /Apps/vphone-cli.app/Contents/MacOS/vphone-cli --config \(spelled)\n"
        let finding = try #require(find(vm(workspace, snapshot: .init(processList: ps, attachedImages: [])), .vmBootProcessWithoutLock))
        #expect(finding.severity == .error)
        #expect(finding.evidence["boot_pids"] == "4242")
    }

    @Test func attachedImagesAndMountResidueWithoutHolderAreWarnings() throws {
        let workspace = try DiagnosticsWorkspace()
        let bundle = try workspace.makeBundle()
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent(".cfw_mount.AbCd1234"), withIntermediateDirectories: true)
        let findings = vm(workspace, snapshot: .init(processList: "", attachedImages: [bundle.appendingPathComponent("Disk.img").path, "/elsewhere.dmg"]))
        #expect(find(findings, .attachedImages)?.severity == .warning)
        #expect(find(findings, .attachedImages)?.evidence["images"] == bundle.appendingPathComponent("Disk.img").path)
        #expect(find(findings, .cfwMountResidue)?.severity == .warning)
        #expect(find(vm(workspace, snapshot: .init(processList: "", attachedImages: nil)), .attachedImages)?.severity == .unknown)
    }

    @Test func guestRuntimeFindingsForRunningVM() throws {
        let workspace = try DiagnosticsWorkspace()
        let bundle = try workspace.makeBundle()
        try writeRuntimeRecord(bundle, operation: VPhoneVMOperation.boot, pid: 4242)
        let ps = "4242 /x/vphone-cli --config \(bundle.path)/config.plist\n"
        var probes = healthyProbes()
        probes.bundleLockHeld = { _ in true }
        probes.processIdentity = { VPhoneProcessIdentity(pid: $0, startedAt: 1, uid: 501) }
        let snapshot = VPhoneDiagnostics.Snapshot(processList: ps, attachedImages: [])

        let answers: [(VPhoneDiagnosticProbes.HostControlAnswer, VPhoneDiagnosticCode, VPhoneDiagnosticSeverity)] = [
            (.missing, .hostControlSocketMissing, .error),
            (.connectFailed("Connection refused"), .hostControlUnreachable, .error),
            (.rejected("unknown command: capabilities"), .hostControlCapabilitiesUnavailable, .unknown),
            (.capabilities(guestConnected: false, screenAvailable: true, protocolVersion: 1, guestCapabilityCount: 0), .guestDisconnected, .warning),
            (.capabilities(guestConnected: true, screenAvailable: true, protocolVersion: 1, guestCapabilityCount: 9), .guestConnected, .ok),
        ]
        for (answer, code, severity) in answers {
            probes.hostControlCapabilities = { path in
                #expect(path == bundle.appendingPathComponent("vphone.sock").path)
                return answer
            }
            let findings = vm(workspace, probes, snapshot: snapshot)
            #expect(find(findings, .vmRunning)?.evidence["record_pid_is_boot_process"] == "true")
            let finding = try #require(find(findings, code), "\(answer)")
            #expect(finding.category == .guestRuntime)
            #expect(finding.severity == severity)
        }

        // DFU and the host-scope summary never touch the socket.
        try writeRuntimeRecord(bundle, operation: VPhoneVMOperation.dfu, pid: 4242)
        probes.hostControlCapabilities = { _ in Issue.record("socket probed"); return .missing }
        #expect(find(vm(workspace, probes, snapshot: snapshot), .guestNotRunning)?.severity == .ok)
        #expect(vm(workspace, probes, snapshot: snapshot, probeGuest: false).allSatisfy { $0.category != .guestRuntime })
    }

    @Test func librarySummaryListsOnlyProblems() throws {
        let workspace = try DiagnosticsWorkspace()
        let good = try workspace.makeBundle("good")
        try VPhoneRestoreInfo(ios: .init(version: "26.1", build: "23B85"), cloudOS: .init(version: "26.1", build: "23B85"))
            .write(toBundle: VPhoneBundle.load(at: good))
        try workspace.makeBundle("broken", disk: false)
        let unreadable = workspace.library.appendingPathComponent("junk")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: unreadable.appendingPathComponent("config.plist"))
        let findings = workspace.diagnostics(healthyProbes()).libraryFindings(.init(processList: "", attachedImages: []))
        #expect(find(findings, .libraryRoot)?.evidence["bundles"] == "broken, good")
        #expect(findings.first { $0.code == .bundleUnreadable }?.vm == "junk")
        #expect(findings.contains { $0.code == .vmFiles && $0.vm == "broken" && $0.severity == .error })
        #expect(!findings.contains { $0.vm == "good" })
    }
}

// MARK: - Live probes

/// Written by the fake server thread before the semaphore, read after wait().
private final class RequestBox: @unchecked Sendable { var text = "" }

struct DiagnosticsLiveProbeTests {
    @Test func capabilitiesQueryParsesAnswersFromARealSocket() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("d5s-" + String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(VPhoneDiagnosticProbes.queryCapabilities(socketPath: directory.appendingPathComponent("none.sock").path) == .missing)
        let regular = directory.appendingPathComponent("file.sock")
        try Data().write(to: regular)
        #expect(VPhoneDiagnosticProbes.queryCapabilities(socketPath: regular.path) == .notSocket)

        for (reply, expected) in [
            (#"{"ok":true,"protocol_version":1,"guest_connected":true,"guest_capabilities":["hid","shell"],"screen_available":false}"#,
             VPhoneDiagnosticProbes.HostControlAnswer.capabilities(guestConnected: true, screenAvailable: false, protocolVersion: 1, guestCapabilityCount: 2)),
            (#"{"ok":false,"error":"unknown command: capabilities"}"#, .rejected("unknown command: capabilities")),
        ] {
            let path = directory.appendingPathComponent("s.sock").path
            unlink(path)
            let server = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: path.utf8)
                buffer[path.utf8.count] = 0
            }
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            #expect(bound == 0)
            #expect(listen(server, 1) == 0)
            let received = DispatchSemaphore(value: 0)
            let request = RequestBox()
            // A dedicated thread: the global queue can be saturated by parallel tests.
            Thread {
                let client = accept(server, nil, nil)
                var buffer = [UInt8](repeating: 0, count: 256)
                let count = read(client, &buffer, buffer.count)
                request.text = String(decoding: buffer[..<max(count, 0)], as: UTF8.self)
                _ = (reply + "\n").withCString { write(client, $0, strlen($0)) }
                close(client)
                received.signal()
            }.start()
            #expect(VPhoneDiagnosticProbes.queryCapabilities(socketPath: path, timeout: 30) == expected)
            received.wait()
            close(server)
            #expect(request.text == "{\"t\":\"capabilities\"}\n")
        }
    }

    @Test func boundedRunnerTimesOutAndClosesStdin() throws {
        let start = Date()
        let slow = try VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: "/bin/sleep"), ["5"], timeout: 0.2)
        #expect(slow.timedOut)
        #expect(Date().timeIntervalSince(start) < 4)
        // stdin is /dev/null, so cat ends at once instead of waiting on the terminal.
        let cat = try VPhoneProcessRunner.runCapturing(URL(fileURLWithPath: "/bin/cat"), [], timeout: 5)
        #expect(!cat.timedOut)
        #expect(cat.succeeded)
    }

    @Test func bootProcessParserIgnoresOtherCommands() {
        let ps = """
          10 /x/vphone-cli --config /a/config.plist
          11 /usr/bin/python3 tool.py --config /a/config.plist
          12 /x/vphone-cli vm list
        """
        let parsed = VPhoneDiagnostics.bootProcesses(ps)
        #expect(parsed.map(\.0) == [10])
        #expect(parsed.first?.1 == "/a/config.plist")
    }
}
