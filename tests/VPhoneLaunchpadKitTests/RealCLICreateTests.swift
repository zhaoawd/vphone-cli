import Foundation
import Testing
import VPhoneCore
@testable import VPhoneLaunchpadKit

// MARK: - The embedded vphone-cli, read-only create commands

/// Checks B4's command shapes and decoders against the `vphone-cli` embedded
/// in a built `vphone-launchpad.app`. It runs only read-only commands:
/// `fw catalog --json`, `vm create --help`, and `vm create-status --json` on a
/// `vm new` fixture with a fixture checkpoint in a temporary library. It
/// never runs `vm create` itself: nothing downloads, restores or boots.
///
/// Opt-in, like `RealCLIEditTests`:
///
///     VPHONE_LAUNCHPAD_APP=$PWD/.build/vphone-launchpad.app \
///     VPHONE_LIBRARY_ROOT=<empty temporary folder> \
///     swift test --disable-sandbox --filter RealCLICreateTests
@MainActor
@Suite(.serialized, .enabled(if: RealCLI.app != nil), .timeLimit(.minutes(2)))
struct RealCLICreateTests {
    @Test func catalogHelpAndStatusMatchTheEmbeddedCLI() async throws {
        let toolchain = try RealCLI.toolchain()
        let history = VPhoneLaunchpadCommandHistory()
        let commandLine = VPhoneLaunchpadCommandLine(toolchain: toolchain, history: history)

        // fw catalog --json decodes, and matches the catalog compiled into this test.
        let catalog = try VPhoneLaunchpadFirmwareCatalog.decode(
            try await commandLine.run(VPhoneLaunchpadCreateCommand.catalog, recordInHistory: false))
        #expect(!catalog.pairings.isEmpty)
        #expect(catalog.pairings.map(\.iosURL) == VPhoneFirmwareCatalog.report.pairings.map(\.ios.url))
        RealCLI.report("fw catalog: \(catalog.device), \(catalog.pairings.count) pairings")

        // Every option the factories emit is one vm create accepts.
        let help = try await commandLine.run(["vm", "create", "--help"], recordInHistory: false)
        #expect(help.succeeded)
        let text = help.lines.joined(separator: "\n")
        var request = CreateCommandTests.request(.exp)
        request.keepArtifacts = true
        request.frida = true
        request.spoofBuild = "23B85"
        request.prepareBackend = .script
        request.restoreBackend = .python
        let machine = VPhoneLaunchpadMachinePath(libraryRoot: CreateCommandTests.root, name: "m")
        let commands = try [
            #require(VPhoneLaunchpadCreateCommand.create(request)),
            #require(VPhoneLaunchpadCreateCommand.resume(
                machine, variant: "jb", restartFrom: .cfw, acceptToolChange: true, keepArtifacts: true)),
        ]
        let options = Set(commands.flatMap(\.arguments).filter { $0.hasPrefix("--") })
        #expect(options.count == 14)
        for option in options.sorted() {
            #expect(text.contains(option), "vm create --help lacks \(option)")
        }
        for option in ["--sudo-password", "--interactive", "--root-popup"] {
            #expect(text.contains(option))
        }
        // The help wraps its discussion; compare with single spaces.
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(flat.contains("'less' (patchless) variant must itself be run with sudo"))
        RealCLI.report("vm create --help lists all \(options.count) options the factories emit")

        // vm create-status --json on a fixture: the decoder reads what the CLI prints.
        let temp = try LaunchpadTemporaryDirectory(short: "lpr")
        let root = try RealCLI.makeRoot(temp, "l")
        try RealCLI.newMachine("m", in: root, toolchain: toolchain)
        let path = VPhoneLaunchpadMachinePath(libraryRoot: root, name: "m")
        try CheckpointFixture.write(CheckpointFixture.make(variant: "jb") { checkpoint in
            CheckpointFixture.done(&checkpoint, .prepare)
            CheckpointFixture.began(&checkpoint, .patch, .failed, error: "stage patch failed: exit 1")
        }, to: path.url)
        let progress = try #require(VPhoneLaunchpadCreateProgress.read(path, live: false)).get()
        let statusCommand = try #require(VPhoneLaunchpadCreateCommand.status(path))
        let status = try VPhoneLaunchpadCreateStatus.decode(try await commandLine.run(statusCommand))
        #expect(status.overallStatus == "failed")
        #expect(status.overallStatus == progress.overallStatus)
        #expect(status.nextStage == "patch")
        #expect(status.checkpointError == nil)
        #expect(!status.live.createRunInProgress)
        #expect(!status.live.bundleLockHeld)
        #expect(status.live.firmwareTransaction == nil)
        #expect(history.entries.map(\.text) == [statusCommand.display])
        #expect(history.entries.first?.status == 0)
        RealCLI.report("vm create-status: overall \(status.overallStatus ?? "-"), next \(status.nextStage ?? "-")")
    }
}
