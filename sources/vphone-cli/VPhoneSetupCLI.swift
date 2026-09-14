import ArgumentParser
import Foundation
import VPhoneCore

// MARK: - setup

/// Provision (or verify) the host Python environment the guest pipeline needs.
/// Runs implicitly on first use, but this makes it an explicit, up-front step
/// so a freshly-copied .app can be prepared before a long `vm create`.
struct VPhoneSetupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Provision/verify the host Python environment (~/.vphone/venv)")

    @Flag(name: .shortAndLong, help: "Recreate the managed venv even if one already works")
    var force = false
    @Option(name: .shortAndLong, help: "Resource base override (default: inferred from the running binary path)")
    var projectRoot: String?

    func run() throws {
        let resources = projectRoot.map { VPhoneResources(base: URL(fileURLWithPath: $0)) } ?? .resolve()
        let python = try resources.pythonExecutable(forceManaged: force)
        print("python: \(python.path)")
    }
}
