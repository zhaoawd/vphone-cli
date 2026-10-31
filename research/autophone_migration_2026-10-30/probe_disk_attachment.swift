import Foundation
import Virtualization
let path = CommandLine.arguments[1]
do {
    let attachment = try VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: path), readOnly: false, cachingMode: .cached, synchronizationMode: .full)
    print("attachment-open")
    fflush(stdout)
    if CommandLine.arguments.count > 2 { Thread.sleep(forTimeInterval: 30) }
    withExtendedLifetime(attachment) {}
} catch {
    fputs("attachment-refused: \(error)\n", stderr)
    exit(1)
}
