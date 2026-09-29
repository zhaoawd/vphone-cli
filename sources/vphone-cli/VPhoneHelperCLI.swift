import ArgumentParser
import Darwin
import Foundation
import VPhoneHelperKit

struct VPhoneHelperCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "helper",
        abstract: "Manage the signed privileged helper (requires a configured Apple signing team)",
        subcommands: [VPhoneHelperStatusCommand.self, VPhoneHelperRegisterCommand.self,
                      VPhoneHelperInstallBundleCommand.self, VPhoneHelperVerifyBundleCommand.self])
}

struct VPhoneHelperStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Inspect signing configuration and helper protocol")
    func run() throws {
        do {
            let client = try VPhoneHelperClient()
            print("helper protocol: \(try client.version())")
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }
}

struct VPhoneHelperRegisterCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "register", abstract: "Register the bundled signed helper with administrator authorization")
    func run() throws {
        try VPhoneHelperClient().register()
        print("Registered \(VPhoneHelperIdentity.label), protocol \(VPhoneHelperIdentity.protocolVersion)")
    }
}

struct VPhoneHelperInstallBundleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "install-bundle", abstract: "Ask the authorized helper to install a verified Core Bundle")
    @Option var version: String
    @Option(transform: URL.init(fileURLWithPath:)) var archive: URL
    @Option(help: "Archive SHA-256 from a trusted source") var sha256: String
    func run() throws {
        let client = try VPhoneHelperClient()
        let fd = open(archive.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ValidationError("Unable to open archive: \(archive.path)") }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        FileHandle.standardOutput.write(try client.installBundle(version: version, archive: input, sha256: sha256) + Data("\n".utf8))
    }
}

struct VPhoneHelperVerifyBundleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "verify-bundle", abstract: "Ask the signed helper to verify an installed Core Bundle")
    @Option var version: String
    func run() throws {
        FileHandle.standardOutput.write(try VPhoneHelperClient().verifyBundle(version: version) + Data("\n".utf8))
    }
}
