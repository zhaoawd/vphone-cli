import Foundation
import Observation
import VPhoneLaunchpadKit

/// Owns the embedded toolchain check and the machine library. B1 has no Host
/// Setup or Core Bundle panel, no helper client and no control socket: the
/// window shows the machines, read-only.
@MainActor
@Observable
final class VPhoneLaunchpadModel {
    enum ToolchainState {
        case checking
        case verified(VPhoneLaunchpadToolchain)
        case failed(VPhoneLaunchpadToolchain.Failure)
    }

    let history = VPhoneLaunchpadCommandHistory()
    let machines = VPhoneLaunchpadMachineLibrary()

    private(set) var toolchain: ToolchainState = .checking
    private(set) var isStarted = false

    /// Checks the embedded toolchain, then lists machines. Nothing is listed
    /// and no command runs when the check fails.
    func start() async {
        guard !isStarted else {
            return
        }
        isStarted = true
        // Validation hashes the whole nested app; keep it off the main actor.
        let result = await Task.detached { VPhoneLaunchpadToolchain.verifyEmbedded() }.value
        switch result {
        case let .success(verified):
            toolchain = .verified(verified)
            FileHandle.standardOutput.write(Data("[launchpad] embedded toolchain verified (\(verified.manifest.gitHash))\n".utf8))
            machines.startMonitoring(with: VPhoneLaunchpadCommandLine(toolchain: verified, history: history))
        case let .failure(failure):
            toolchain = .failed(failure)
            FileHandle.standardError.write(Data("[launchpad] embedded toolchain rejected at \(failure.step.rawValue): \(failure.reason)\n".utf8))
        }
    }
}
