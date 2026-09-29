import ArgumentParser
import Darwin
import Foundation
import VPhoneBundleStore

struct VPhoneCoreBundleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "core-bundle",
        abstract: "Install and verify root-owned Core Bundles",
        subcommands: [VPhoneCoreBundleInstallCommand.self, VPhoneCoreBundleVerifyCommand.self]
    )
}

struct VPhoneCoreBundleInstallCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install a new Core Bundle version using sudo; existing versions are refused",
        discussion: "Supply a SHA-256 from a trusted source. Ad hoc signatures verify integrity, not publisher identity. This command does not change AMFI policy or activate a VM."
    )

    @Option(help: "Bundle version, at least 2.0.8; local builds may use -local")
    var version: String

    @Option(help: "Archive containing VPhone.bundle", transform: URL.init(fileURLWithPath:))
    var archive: URL

    @Option(help: "Expected archive SHA-256 (64 hexadecimal digits)")
    var sha256: String

    func run() throws {
        guard geteuid() == 0 else { throw ValidationError("Run core-bundle install using sudo.") }
        let fd = open(archive.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ValidationError("Cannot open the archive as a regular file: \(archive.path)") }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        let receipt = try VPhoneCoreBundleStore().install(version: version, archive: input, sha256: sha256)
        FileHandle.standardOutput.write(try receipt.encoded() + Data("\n".utf8))
    }
}

struct VPhoneCoreBundleVerifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify", abstract: "Verify ownership, receipt, signatures and cdhashes; no root required"
    )

    @Option(help: "Installed Core Bundle version")
    var version: String

    func run() throws {
        let receipt = try VPhoneCoreBundleStore().verify(version: version)
        FileHandle.standardOutput.write(try receipt.encoded() + Data("\n".utf8))
    }
}
