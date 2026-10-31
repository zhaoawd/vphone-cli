import Darwin
import Foundation
import VPhoneBundleStore
import VPhoneLaunchpadKit

// Ordinary child execution; this launcher provides no privilege escalation.
func fail(_ status: Int32, _ message: String) -> Never {
    let line = "vphone-launchpad-launcher: \(message)\n"
    _ = line.withCString { write(STDERR_FILENO, $0, strlen($0)) }
    exit(status)
}
let arguments = Array(CommandLine.arguments.dropFirst())
guard let executable = arguments.first else {
    fail(64, "usage: vphone-launchpad-launcher <vphone-cli> vm launch <machine> [options]")
}
let request: VPhoneLaunchpadLauncherRequest
do { request = try .init(executable: executable, arguments: Array(arguments.dropFirst())) }
catch { fail(77, "refused: \(error.localizedDescription)") }
// Execute only our sealed local wrapper. An upstream CLI may automatically
// update the guest daemon or widen VM file permissions during ordinary boot.
let toolchain: VPhoneLaunchpadToolchain
do { toolchain = try VPhoneLaunchpadToolchain.verifyEmbedded().get() }
catch { fail(77, "local embedded toolchain failed verification: \(error)") }
guard URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL == toolchain.launcher else {
    fail(77, "launcher is outside the verified app")
}
let status: Int32
do {
    status = try request.withVerifiedExecutable { _ in
        try VPhoneLaunchpadLauncherProcess.run(path: toolchain.executable.path,
            argv: [toolchain.executable.path] + request.arguments + ["--expected-core-bundle", request.version])
    }
} catch let error as VPhoneLaunchpadLauncherFailure { fail(71, error.message) }
catch { fail(77, "refused: \(error.localizedDescription)") }
VPhoneLaunchpadLauncherProcess.exit(withStatusOf: status)
