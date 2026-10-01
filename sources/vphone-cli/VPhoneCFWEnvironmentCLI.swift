import ArgumentParser
import Foundation
import VPhoneCore

// MARK: - Eligibility decision

/// What `cfw update-environment` does with the read-only check's result.
/// The check is `scripts/cfw_env_update.py check-vm`; its exit codes are
/// 0 (classified), 2 (input error), 4 (VM busy) and 5 (disk access failed).
enum VPhoneEnvironmentDecision: Equatable {
    /// offline_update: run the root driver (`--update-environment`).
    case replace(libraries: [String])
    /// The read-only check could not read the disk without root; the root
    /// driver repeats the classification on the staged copy and refuses
    /// anything other than offline_update.
    case replaceAfterRootCheck(detail: String)
    /// already_current: nothing to write.
    case nothingToDo
    /// full_migration_required, not_applicable, a busy VM or an input error.
    case refuse(classification: String?, reasons: [String], exitCode: Int32)

    static let refusedExitCode: Int32 = 3

    static func decide(checkStatus: Int32, stdout: String, stderr: String) -> Self {
        switch checkStatus {
        case 0:
            break
        case 5:
            return .replaceAfterRootCheck(detail: stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .refuse(classification: nil, reasons: detail.isEmpty ? [] : [detail], exitCode: checkStatus)
        }
        guard let data = stdout.data(using: .utf8),
              let report = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let classification = report["classification"] as? String
        else {
            return .refuse(classification: nil, reasons: ["the eligibility check returned no classification"], exitCode: 2)
        }
        let reasons = report["reasons"] as? [String] ?? []
        switch classification {
        case "offline_update":
            return .replace(libraries: report["replace"] as? [String] ?? [])
        case "already_current":
            return .nothingToDo
        default:
            var details = reasons
            if let migration = report["migration"] as? String { details.append(migration) }
            return .refuse(classification: classification, reasons: details, exitCode: refusedExitCode)
        }
    }
}

// MARK: - cfw update-environment

struct VPhoneCFWUpdateEnvironmentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update-environment",
        abstract: "Check, or replace on a stopped VM, the guest environment libraries (offline_update only)",
        discussion: """
        The check is read-only and runs as the invoking user: it holds the VM \
        lock without writing a record, attaches Disk.img read-only and mounts \
        the System volume read-only outside the bundle. It prints JSON with \
        one classification: already_current, offline_update, \
        full_migration_required or not_applicable.

        Without --check, only offline_update proceeds. The root CFW driver \
        (scripts/cfw_install_host.sh --update-environment) stages a copy of \
        Disk.img (T15 transaction), checks it again, replaces the libraries \
        that exist and differ from the signed candidates, and publishes the \
        copy; the previous disk stays in .cfw-history. Missing libraries or \
        load paths are never added. The VM configuration, device identity \
        and recorded variant are not written. No guest process is restarted.

        libmisfix.dylib is reported as upstream_only and is never replaced.
        """)

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Flag(name: .long, help: "Only print the read-only eligibility report (JSON)") var check = false
    @Option(name: .long, help: "Candidate stage (default: <resource base>/.build/guest-components-v2/stage)")
    var components: String?
    @Flag(name: .customLong("root-popup"), help: "Elevate the replacement via macOS's native authentication dialog (osascript) instead of the sudo re-exec") var rootPopup = false
    @Option(name: .shortAndLong, help: "Resource base override (default: inferred from the running binary path)")
    var projectRoot: String?
    @Flag(name: .customShort("v"), help: "Increase verbosity: -v tool detail, -vv guest serial, -vvv internal trace")
    var verboseCount: Int

    func run() throws {
        let v = max(VPhoneVerbosity.info, VPhoneVerbosity(count: verboseCount))
        let name = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: name)
        let resources = projectRoot.map { VPhoneResources(base: URL(fileURLWithPath: $0)) } ?? .resolve()
        let python = try resources.pythonExecutable()
        let stage = components.map { URL(fileURLWithPath: $0).standardizedFileURL } ?? resources.guestComponentsStage

        let result = try VPhoneProcessRunner.runCapturing(
            python, [resources.cfwEnvUpdateScript.path, "check-vm", bundle.url.path, "--components", stage.path])
        if !result.stdout.isEmpty { print(result.stdout, terminator: result.stdout.hasSuffix("\n") ? "" : "\n") }
        if !result.stderr.isEmpty { FileHandle.standardError.write(Data(result.stderr.utf8)) }
        if check { throw ExitCode(result.exitCode) }

        switch VPhoneEnvironmentDecision.decide(
            checkStatus: result.exitCode, stdout: result.stdout, stderr: result.stderr)
        {
        case .nothingToDo:
            print("[cfw] already_current: every environment library equals its candidate; nothing was written")
            return
        case let .refuse(classification, reasons, exitCode):
            FileHandle.standardError.write(Data(
                "[cfw] environment update refused: \(classification ?? "check failed")\n".utf8))
            for reason in reasons { FileHandle.standardError.write(Data("    - \(reason)\n".utf8)) }
            throw ExitCode(exitCode)
        case let .replaceAfterRootCheck(detail):
            print("[cfw] the read-only check could not read the disk as this user (\(detail)); "
                + "the root update checks the staged copy and refuses anything other than offline_update")
        case let .replace(libraries):
            print("[cfw] offline_update: replacing \(libraries.joined(separator: ", ")) on a staged copy")
        }

        let scriptEnv = [
            "VPHONE_PYTHON": python.path,
            "VPHONE_GUEST_COMPONENTS": stage.path,
        ]
        let args = Self.driverArguments(resources: resources, bundle: bundle.url)
        let invocation = VPhoneCreateOrchestrator.cfwInvocation(
            scriptEnv: scriptEnv, sudoEnvExtras: [:], rootPopup: rootPopup)
        let code: Int32
        if invocation.usePopup {
            code = try VPhoneProcessRunner.runWithAdminPrivileges(
                URL(fileURLWithPath: "/bin/zsh"), args, env: invocation.env, echo: v.showsToolDetail)
        } else {
            code = try VPhoneProcessRunner.runStreaming(
                URL(fileURLWithPath: "/bin/zsh"), args, env: invocation.env, echo: v.showsToolDetail)
        }
        // The recorded variant is deliberately not rewritten: the update
        // changes no patch, and `cfw install` alone records a variant.
        throw ExitCode(code)
    }

    static func driverArguments(resources: VPhoneResources, bundle: URL) -> [String] {
        [resources.cfwInstallHostScript.path, "--update-environment", bundle.path]
    }
}
