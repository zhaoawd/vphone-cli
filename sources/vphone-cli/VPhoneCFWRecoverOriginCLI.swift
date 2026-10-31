import ArgumentParser
import Darwin
import Foundation
import VPhoneCore

/// Recovery consumes the sealed producer attestation. It never reruns CFW or
/// manufactures a source for a legacy transaction.
struct VPhoneCFWRecoverOriginCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "recover-origin",
        abstract: "Recover one pending qualified Guest disk/origin publication using its sealed attestation")
    @OptionGroup var lib: VPhoneLibraryOption
    @Argument var name: String?
    @Option var transaction: String
    @Flag(name: .customLong("root-popup")) var rootPopup = false

    func validate() throws {
        guard transaction.hasPrefix(".cfw_disk."), transaction.count > ".cfw_disk.".count,
              !transaction.contains("/"), !transaction.contains("\0"),
              transaction != ".", transaction != ".." else {
            throw ValidationError("Guest recovery requires one pending .cfw_disk.<name> directory")
        }
    }

    func run() throws {
        let selected = try VPhoneVMSelection.resolveExisting(name, in: lib.library)
        let bundle = try lib.library.bundle(named: selected)
        let work = bundle.url.appendingPathComponent(transaction)
        if geteuid() != 0 {
            let args = ["cfw", "recover-origin", selected, "--library-root", lib.library.root.path,
                        "--transaction", transaction]
            var environment = VPhoneInvoker.environment()
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            let executable = VPhoneResources.runningExecutable()
            let code: Int32
            if rootPopup {
                code = try VPhoneProcessRunner.runWithAdminPrivileges(executable, args, env: environment)
            } else {
                code = try VPhoneProcessRunner.runStreaming(URL(fileURLWithPath: "/usr/bin/sudo"),
                    ["-E", executable.path] + args, env: environment)
            }
            throw ExitCode(code)
        }
        guard work == work.resolvingSymlinksInPath(),
              FileManager.default.fileExists(atPath: work.appendingPathComponent("guest-origin-source.json").path) else {
            throw ValidationError("Recovery target has no existing qualified Guest source")
        }
        try VPhoneCFWTrustedProducer.requireDefaultResources(projectRoot: nil,
            environment: ProcessInfo.processInfo.environment)
        let code = try VPhoneCFWTrustedProducer.withLease(machine: bundle.url) { source, input in
            let resources = VPhoneResources.resolve()
            let python = try resources.pythonExecutable(allowBootstrap: false)
            var environment = ProcessInfo.processInfo.environment
            environment.merge(source) { _, source in source }
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            return try VPhoneProcessRunner.runStreaming(python,
                [resources.scriptsDir.appendingPathComponent("vm_lock.py").path, bundle.url.path,
                 VPhoneVMOperation.cfwRecord, "--", python.path,
                 resources.scriptsDir.appendingPathComponent("cfw_disk_txn.py").path, "recover", bundle.url.path, work.path],
                 env: environment, input: input)
        }
        throw ExitCode(code)
    }
}
