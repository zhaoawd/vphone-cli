import ArgumentParser
import Foundation
import VPhoneCore

struct VPhoneCFWUndoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "undo",
        abstract: "Restore qualified trailing DSC operations on a staged disk; guest origin becomes unknown")

    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Option(help: "Expected committed generation SHA-256") var generation: String
    @Option(name: .customLong("declaration"), parsing: .upToNextOption,
        help: "Declaration IDs to undo; all later operations on each member must be included")
    var declarations: [String] = []
    @Flag(name: .customLong("root-popup"), help: "Elevate with the macOS authentication dialog") var rootPopup = false

    func validate() throws {
        guard generation.utf8.count == 64,
              generation.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !declarations.isEmpty, declarations.allSatisfy({ !$0.isEmpty }),
              Set(declarations).count == declarations.count else {
            throw ValidationError("CFW Undo requires --generation (64 lowercase hex characters) and unique --declaration IDs")
        }
    }

    static func arguments(script: URL, directory: URL, variant: String, generation: String,
                          declarations: [String]) -> [String] {
        [script.path, "--variant", variant, "--generation", generation] +
            declarations.flatMap { ["--undo-declaration", $0] } + [directory.path]
    }

    func run() throws {
        let selected = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: selected)
        let profile = VPhoneRestoreInfo.load(fromBundle: bundle)?.effectiveGuestEnvironment ?? .classic
        let frozen = try VPhoneBundleGuard.withBundleLock(directory: bundle.url, operation: VPhoneVMOperation.cfwRecord) { _ in
            try VPhoneCFWFrozenContext.prepare(in: bundle.url, requestedVariant: nil,
                guestEnvironment: profile.rawValue, spoofBuild: "")
        }
        guard frozen.generationID == generation else {
            throw ValidationError("CFW Undo generation differs from the current bound plan")
        }
        let resources = VPhoneResources.resolve()
        var environment = try frozen.environment
        environment["VPHONE_PYTHON"] = try resources.pythonExecutable().path
        environment["VPHONE_KEEP_ARTIFACTS"] = "1"
        let invocation = VPhoneCreateOrchestrator.cfwInvocation(scriptEnv: environment,
            sudoEnvExtras: [:], rootPopup: rootPopup)
        let args = Self.arguments(script: resources.cfwInstallHostScript, directory: bundle.url,
            variant: frozen.variant, generation: generation, declarations: declarations)
        let code: Int32
        if invocation.usePopup {
            code = try VPhoneProcessRunner.runWithAdminPrivileges(URL(fileURLWithPath: "/bin/zsh"), args,
                env: invocation.env, echo: true)
        } else {
            code = try VPhoneProcessRunner.runStreaming(URL(fileURLWithPath: "/bin/zsh"), args,
                env: invocation.env, echo: true)
        }
        throw ExitCode(code)
    }
}

struct VPhoneCFWReceiptsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "receipts",
        abstract: "Verify the committed guest disk journal and read component effect receipts")
    @OptionGroup var lib: VPhoneLibraryOption
    @Argument(help: "VM name") var name: String?
    @Flag(help: "Emit the complete verified JSON report") var json = false

    func run() throws {
        let selected = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: selected)
        let resources = VPhoneResources.resolve()
        let python = try resources.pythonExecutable()
        let result = try VPhoneProcessRunner.runCapturing(python,
            [resources.scriptsDir.appendingPathComponent("vm_lock.py").path, bundle.url.path,
             VPhoneVMOperation.fwReceipts, "--", python.path,
             resources.scriptsDir.appendingPathComponent("cfw_disk_txn.py").path, "inspect", bundle.url.path],
            env: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "PYTHONDONTWRITEBYTECODE": "1"])
        guard result.succeeded else { throw ValidationError(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let report = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
              report["schemaVersion"] as? Int == 1, let state = report["state"] as? String else {
            throw ValidationError("Guest journal returned an invalid report")
        }
        if json { print(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) }
        else {
            print("guest component evidence: \(state)")
            if let receipts = report["componentReceipts"] as? [String: Any] {
                print("  removed declarations: \((receipts["removedDeclarations"] as? [String] ?? []).joined(separator: ", "))")
                print("  guest origin: unknown")
            }
        }
    }
}
