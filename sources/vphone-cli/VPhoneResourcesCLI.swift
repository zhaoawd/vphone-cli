import ArgumentParser
import Foundation
import VPhoneCore

/// A read-only resource probe that does not initialize a VM or Python environment.
struct VPhoneResourcesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resources",
        abstract: "Print the resolved runtime resource directory")

    @Flag(help: "Print resource and guest payload paths as JSON") var json = false

    func run() throws {
        let resources = VPhoneResources.resolve()
        for url in resources.coreRuntimeResources {
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ValidationError("Missing runtime resource: \(url.path)")
            }
        }
        if json {
            let paths = ["base": resources.base.path, "guestResources": resources.guestResources.path,
                         "vphoned": resources.vphoned.path, "vphonedLess": resources.vphonedLess.path]
            let data = try JSONSerialization.data(withJSONObject: paths, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } else {
            print(resources.base.path)
        }
    }
}
