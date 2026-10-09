import Foundation
import Observation
import VPhoneLaunchpadKit

/// Owns the embedded toolchain check, the machine library (with its create
/// runs, B4), the command history and the panels: read-only Host Setup and
/// Core Bundle (B5) and Recent Commands (B3). There is no helper client and
/// no control socket.
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
    /// The embedded `vphone-cli`, once verified (New Machine's catalog).
    private(set) var commandLine: VPhoneLaunchpadCommandLine?

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
            self.commandLine = commandLine
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

    /// Opens the panels named on the command line, for the UI smoke check:
    /// `-VPhoneLaunchpadOpenPanel hostSetup|coreBundle|commandHistory`, or a
    /// comma-separated list such as `hostSetup,commandHistory`. Each later
    /// panel opens once the commands the earlier one ran have finished, so
    /// Recent Commands shows them. Only the arguments domain is read, so
    /// nothing persists.
    private func openRequestedPanel() {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        guard let names = arguments["VPhoneLaunchpadOpenPanel"] as? String else {
            return
        }
        let requested = names.split(separator: ",").compactMap { VPhoneLaunchpadPanel(rawValue: String($0)) }
        guard let first = requested.first else {
            return
        }
        panels.present(first)
        Task {
            for next in requested.dropFirst() {
                try? await Task.sleep(for: .seconds(1))
                while history.entries.contains(where: { $0.status == nil }) || host?.isChecking == true {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                panels.present(next)
            }
        }
    }
}
