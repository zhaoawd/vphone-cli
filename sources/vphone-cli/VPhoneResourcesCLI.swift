import ArgumentParser
import Foundation
import VPhoneCore

/// A read-only resource probe that does not initialize a VM or Python environment.
struct VPhoneResourcesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resources",
        abstract: "Print the resolved runtime resource directory")

    func run() throws {
        let resources = VPhoneResources.resolve()
        for url in [resources.fwPrepareScript, resources.cfwPy, resources.signcert, resources.requirementsFile] {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ValidationError("Missing runtime resource: \(url.path)")
            }
        }
        print(resources.base.path)
    }
}
