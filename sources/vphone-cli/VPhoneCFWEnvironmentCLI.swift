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

// MARK: - Elevated read-only check

/// `cfw update-environment --check` as root, through the CFW driver's own
/// elevation: `scripts/cfw_install_host.sh --check-environment --report FILE`
/// re-executes under `sudo -E`, or runs under `--root-popup`'s authentication
/// dialog, with VPHONE_INVOKER_UID/GID as for `cfw install`
/// (`VPhoneCreateOrchestrator.cfwInvocation`). The check writes nothing in the
/// VM directory; its result goes to FILE, a new file in a private (0700)
/// directory this process creates beneath the temporary directory. The file
/// carries the check's exit code, because `osascript` reports every failure
/// as 1. The directory and the file are removed here after reading.
enum VPhoneElevatedEnvironmentCheck {
    typealias Invocation = (usePopup: Bool, env: [String: String])

    struct Outcome: Equatable {
        var exitCode: Int32
        /// The eligibility report (JSON), when the check classified the VM.
        var report: String?
        /// Stage, message and next step of a failure.
        var message: String?
    }

    static func driverArguments(resources: VPhoneResources, bundle: URL, report: URL) -> [String] {
        [resources.cfwInstallHostScript.path, "--check-environment", "--report", report.path, bundle.path]
    }

    static func run(
        resources: VPhoneResources, bundle: URL, scriptEnv: [String: String], rootPopup: Bool,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        runner: (_ args: [String], _ invocation: Invocation) throws -> Int32
    ) throws -> Outcome {
        var template = Array(temporaryDirectory.appendingPathComponent("vphone-env-check.XXXXXXXX").path.utf8CString)
        let created: String? = template.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress).map { String(cString: $0) }
        }
        guard let created else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let directory = URL(fileURLWithPath: created)
        let report = directory.appendingPathComponent("report.json")
        // The directory is this user's, so the file goes even if root still owns it.
        defer {
            unlink(report.path)
            rmdir(directory.path)
        }
        let invocation = VPhoneCreateOrchestrator.cfwInvocation(
            scriptEnv: scriptEnv, sudoEnvExtras: [:], rootPopup: rootPopup)
        let status = try runner(driverArguments(resources: resources, bundle: bundle, report: report), invocation)
        return outcome(reportData: try? Data(contentsOf: report), status: status)
    }

    static func outcome(reportData: Data?, status: Int32) -> Outcome {
        guard let data = reportData,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = (object["exit_code"] as? NSNumber)?.int32Value
        else {
            return Outcome(
                exitCode: status == 0 ? 1 : status, report: nil,
                message: "the elevated check left no report (exit status \(status)): authentication was "
                    + "cancelled or refused, or the driver stopped before the check; see the output above")
        }
        var printed: String?
        if let report = object["report"] as? [String: Any],
           let json = try? JSONSerialization.data(
               withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        {
            printed = String(decoding: json, as: UTF8.self)
        }
        var message: String?
        if let error = object["error"] as? [String: Any] {
            var text = (error["stage"] as? String).map { "stage \($0): " } ?? ""
            text += error["message"] as? String ?? "the check failed"
            if let advice = error["advice"] as? String { text += "\n    next: \(advice)" }
            message = text
        }
        return Outcome(exitCode: code, report: printed, message: message)
    }
}

// MARK: - cfw update-environment

struct VPhoneCFWUpdateEnvironmentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update-environment",
        abstract: "Check, or replace on a stopped VM, the guest environment libraries (offline_update only)",
        discussion: """
        The check is read-only: it holds the VM lock without writing a record, \
        attaches Disk.img read-only, mounts the System volume read-only outside \
        the bundle, then unmounts and detaches. It prints JSON with one \
        classification: already_current, offline_update, \
        full_migration_required or not_applicable. --check runs it as root \
        (sudo, or --root-popup), because a normal user may not be allowed to \
        mount a VM's System volume; nothing is written to the VM directory and \
        the result file is removed after printing. Each disk step has a time \
        limit; a failure names its stage (attach, locate, mount, read, \
        unmount, detach) and the next step.

        Without --check, a read-only pre-check runs as the invoking user, and \
        only offline_update proceeds (a pre-check that cannot mount the volume \
        hands over to the root driver, which checks its staged copy). The root CFW driver \
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
    @Flag(name: .long, help: "Only print the read-only eligibility report (JSON); the check runs as root (sudo, or --root-popup)") var check = false
    @Option(name: .long, help: "Candidate stage (default: <resource base>/.build/guest-components-v2/stage)")
    var components: String?
    @Flag(name: .customLong("root-popup"), help: "Elevate the check (--check) or the replacement via macOS's native authentication dialog (osascript) instead of the sudo re-exec") var rootPopup = false
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
        let scriptEnv = [
            "VPHONE_PYTHON": python.path,
            "VPHONE_GUEST_COMPONENTS": stage.path,
        ]

        if check && geteuid() != 0 {
            try runElevatedCheck(resources: resources, bundle: bundle.url, scriptEnv: scriptEnv)
        }
        if !check && geteuid() != 0 {
            // The unprivileged pre-check keeps refusals free of an authentication
            // prompt where this user can mount the volume. Each disk step has a
            // limit (cfw_env_update.py STAGE_TIMEOUTS); a failed mount hands over
            // to the root driver, which checks the staged copy again.
            print("[cfw] read-only pre-check as uid \(getuid()); if this user cannot mount the System volume, "
                + "the check stops at stage mount and the root update checks its staged copy instead. "
                + "Use --check for a report read as root.")
        }

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

    /// `--check` for a non-root caller: the check runs as root and its
    /// report (or failure) is printed here. Always ends with ExitCode.
    func runElevatedCheck(resources: VPhoneResources, bundle: URL, scriptEnv: [String: String]) throws -> Never {
        print(rootPopup
            ? "[cfw] the read-only check runs as root: macOS asks for an administrator password"
            : "[cfw] the read-only check runs as root: sudo asks for your macOS password")
        let zsh = URL(fileURLWithPath: "/bin/zsh")
        let outcome = try VPhoneElevatedEnvironmentCheck.run(
            resources: resources, bundle: bundle, scriptEnv: scriptEnv, rootPopup: rootPopup
        ) { args, invocation in
            if invocation.usePopup {
                return try VPhoneProcessRunner.runWithAdminPrivileges(zsh, args, env: invocation.env, echo: true)
            }
            // sudo prompts on the terminal: run as its foreground job (see runForeground).
            return try VPhoneProcessRunner.runForeground(zsh, args, env: invocation.env, echo: true)
        }
        if let report = outcome.report { print(report) }
        if let message = outcome.message {
            FileHandle.standardError.write(Data("[cfw] environment check failed at \(message)\n".utf8))
        }
        throw ExitCode(outcome.exitCode)
    }

    static func driverArguments(resources: VPhoneResources, bundle: URL) -> [String] {
        [resources.cfwInstallHostScript.path, "--update-environment", bundle.path]
    }
}
