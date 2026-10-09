import ArgumentParser
import Foundation
import VPhoneCore

struct VPhoneFWInspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect", abstract: "Read a local IPSW BuildManifest without extracting firmware")

    @Argument(help: "Local iPhone IPSW path") var input: String
    @Option(help: "Optional local cloudOS IPSW path; validate the pair") var cloudosSource: String?
    @Flag(help: "Emit JSON") var json = false

    func run() throws {
        let phone = try VPhoneIPSWCache.inspect(URL(fileURLWithPath: input))
        var archives = [phone]
        if let cloudosSource {
            let cloud = try VPhoneIPSWCache.inspect(URL(fileURLWithPath: cloudosSource))
            try VPhoneIPSWCache.checkPair(iPhone: phone, cloudOS: cloud)
            archives.append(cloud)
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(archives), as: UTF8.self))
        } else {
            for archive in archives {
                print("\(archive.file.path): \(archive.version) (\(archive.build))")
                print("  products: \(archive.productTypes.joined(separator: ", "))")
                print("  device classes: \(archive.deviceClasses.sorted().joined(separator: ", "))")
            }
        }
    }
}
