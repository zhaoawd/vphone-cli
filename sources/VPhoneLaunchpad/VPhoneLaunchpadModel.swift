import Foundation
import Observation
import VPhoneLaunchpadKit

/// Owns the embedded toolchain check, the machine library and the read-only
/// Host Setup and Core Bundle panels (B5). There is no helper client and no
/// control socket.
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
    /// The sheet on screen and the one queued behind it (upstream `ded81cb`).
    let panels = VPhoneLaunchpadPanelQueue()

    private(set) var toolchain: ToolchainState = .checking
    private(set) var isStarted = false
    /// Set once the toolchain is verified; the panels run only through it.
    private(set) var host: VPhoneLaunchpadHostSetup?
    private(set) var coreBundle: VPhoneLaunchpadCoreBundle?

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
            let commandLine = VPhoneLaunchpadCommandLine(toolchain: verified, history: history)
            host = VPhoneLaunchpadHostSetup(commandLine: commandLine, libraryRoot: machines.libraryRoot)
            coreBundle = VPhoneLaunchpadCoreBundle(commandLine: commandLine)
            machines.startMonitoring(with: commandLine)
            openRequestedPanel()
        case let .failure(failure):
            toolchain = .failed(failure)
            FileHandle.standardError.write(Data("[launchpad] embedded toolchain rejected at \(failure.step.rawValue): \(failure.reason)\n".utf8))
        }
    }

    // MARK: - Panels

    /// Opens a panel named on the command line (`-VPhoneLaunchpadOpenPanel
    /// hostSetup|coreBundle`), for the UI smoke check. Only the arguments
    /// domain is read, so nothing persists.
    private func openRequestedPanel() {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        guard let name = arguments["VPhoneLaunchpadOpenPanel"] as? String,
              let panel = VPhoneLaunchpadPanel(rawValue: name)
        else { return }
        panels.present(panel)
    }
}
