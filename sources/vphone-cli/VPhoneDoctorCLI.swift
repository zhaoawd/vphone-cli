import ArgumentParser
import FirmwarePatcher
import Foundation
import VPhoneCore

// MARK: - doctor

/// Read-only diagnostics of the host and, optionally, one VM.
struct VPhoneDoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Diagnose the host and a VM without changing anything (read-only)",
        discussion: """
        Without a VM name: host conditions, signing, dependencies, resources, occupancy,
        and any non-ok state of the bundles in the library. With a name: the same host
        checks plus that VM's files, locks, firmware transaction, restore state, create
        checkpoint and host control channel (one read-only `capabilities` request).

        Nothing is repaired. Each finding may carry a suggested action, which is never run.
        Output omits passwords, tokens, URL credentials/queries and environment values,
        and shortens the home directory to ~.

        Exit status: 0 all ok, 3 worst finding is a warning, 4 worst is unknown (a check
        could not run), 5 worst is an error. 64 is a usage error.
        """)

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name (omit for host-only diagnostics)") var name: String?
    @Flag(name: .shortAndLong, help: "Emit JSON (schema vphone.diagnostics, version 1)") var json = false
    @Option(name: .customLong("patch-record"), help: "Include a patch experiment record written by --record-out")
    var patchRecord: String?
    @Option(name: .shortAndLong, help: "Resource base override (default: inferred from the running binary path)")
    var projectRoot: String?

    func run() throws {
        let report = makeReport(probes: .live())
        if json {
            print(String(decoding: try report.jsonData(), as: UTF8.self))
        } else {
            print(report.text)
        }
        if report.exitCode != 0 { throw ExitCode(report.exitCode) }
    }

    func makeReport(probes: VPhoneDiagnosticProbes) -> VPhoneDiagnosticReport {
        let resources = projectRoot.map { VPhoneResources(base: URL(fileURLWithPath: $0)) } ?? .resolve()
        let diagnostics = VPhoneDiagnostics(resources: resources, library: lib.library, probes: probes)
        var findings = diagnostics.run(vm: name)
        if let patchRecord {
            findings.append(Self.patchRecordFinding(URL(fileURLWithPath: patchRecord), vm: name))
        }
        return VPhoneDiagnosticReport(
            vm: name, libraryRoot: lib.library.root, toolCommit: VPhoneBuildInfo.commitHash, findings: findings)
    }

    // MARK: Patch record

    static func patchRecordFinding(_ url: URL, vm: String?) -> VPhoneDiagnosticFinding {
        let record: PatchExperimentRecord
        do {
            record = try PatchExperimentRecord.load(from: url)
        } catch {
            return .init(.patch, .patchRecordInvalid, .error, "the patch experiment record cannot be used",
                         evidence: ["record": url.path, "reason": "\(error)"], vm: vm)
        }
        var evidence = ["record": url.path, "run_id": record.runIdentifier, "status": record.status.rawValue,
                        "variant": record.variantName, "transaction": record.transactionState]
        switch record.status {
        case .succeeded:
            return .init(.patch, .patchRecord, .ok, "the recorded patch run succeeded", evidence: evidence, vm: vm)
        case .running:
            return .init(.patch, .patchRecordRunning, .warning,
                         "the record was never finished; the run is still going or was killed",
                         evidence: evidence, action: "vphone-cli fw record show \(url.path)", vm: vm)
        case .failed, .cancelled:
            if let stage = record.failedStageName { evidence["failed_stage"] = stage }
            if let component = record.failedComponentName { evidence["failed_component"] = component }
            if let error = record.errorMessage { evidence["last_error"] = error }
            if !record.failedRequiredPatches.isEmpty {
                evidence["failed_required"] = record.failedRequiredPatches.joined(separator: ", ")
            }
            let category = record.failedRequiredPatches.isEmpty ? category(forRunStage: record.failedStageName) : .patch
            return .init(category, .patchRecordFailed, .error, "the recorded patch run \(record.status.rawValue)",
                         evidence: evidence, action: "vphone-cli fw record show \(url.path)", vm: vm)
        }
    }

    /// Stages before any component is patched fail on inputs (restore tree,
    /// pending transaction, ablation ids); later stages fail in patching itself.
    static func category(forRunStage stage: String?) -> VPhoneDiagnosticCategory {
        switch stage.flatMap(FirmwareRunStage.init(rawValue:)) {
        case .notStarted?, .preflight?, .prepare?, .stageInputs?: .input
        default: .patch
        }
    }
}
