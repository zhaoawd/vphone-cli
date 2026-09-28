import AppKit
import ArgumentParser
import Darwin
import Foundation
import VPhoneCore

@MainActor
public enum VPhoneEntry {
    public static func runCLI() {
        do {
            let command = try VPhoneCLI.parseAsRoot()
            if command is VPhoneBootCLI {
                let runtime = VPhoneResources.vmExecutable()
                guard FileManager.default.isExecutableFile(atPath: runtime.path) else {
                    throw ValidationError("VM executable is missing: \(runtime.path); run make build")
                }
                var arguments = Array(CommandLine.arguments.dropFirst())
                if arguments.first == "boot" { arguments.removeFirst() }
                let strings = ([runtime.path] + arguments).map { strdup($0) }
                defer { strings.forEach { free($0) } }
                guard strings.allSatisfy({ $0 != nil }) else { throw POSIXError(.ENOMEM) }
                var argv = strings + [nil]
                // Replace the command process before a VM or lock is created.
                // The runtime keeps the PID and inherited signal/stdio behavior.
                _ = execv(runtime.path, &argv)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            var runnable = command
            try runnable.run()
        } catch {
            VPhoneCLI.exit(withError: error)
        }
    }

    public static func runVM() {
        do {
            let command = try VPhoneVMRuntimeCLI.parseAsRoot()
            guard let runtime = command as? VPhoneVMRuntimeCLI else { return }
            let app = NSApplication.shared
            let delegate = VPhoneAppDelegate(cli: runtime.boot)
            app.delegate = delegate
            app.run()
        } catch {
            VPhoneVMRuntimeCLI.exit(withError: error)
        }
    }
}

struct VPhoneVMRuntimeCLI: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "vphone-vm", abstract: "Virtual iPhone runtime")
    @OptionGroup var boot: VPhoneBootCLI
}
