import Darwin
import Foundation
import VPhoneHelperKit

do {
    if CommandLine.arguments.dropFirst() == ["--check-configuration"] {
        let configuration = try VPhoneHelperDaemon.configuration()
        print("configured: \(configuration.team), protocol \(VPhoneHelperIdentity.protocolVersion)")
    } else if CommandLine.arguments.count == 1 {
        try VPhoneHelperDaemon.run()
    } else {
        throw VPhoneHelperError("Usage: vphone-helper [--check-configuration]")
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(78)
}
