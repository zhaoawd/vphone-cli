import Foundation
import Testing
@testable import VPhoneLaunchpadKit

// MARK: - Menu bar setting and Dock icon (B6)

struct MenuBarSettingTests {
    @Test func offByDefaultAndClosingTheLastWindowQuits() {
        let defaults = InMemoryDefaults()
        #expect(!VPhoneLaunchpadMenuBar.isEnabled(defaults))
        #expect(VPhoneLaunchpadMenuBar.terminatesAfterLastWindowClosed(defaults))
    }

    @Test func menuBarModeKeepsTheAppAfterTheLastWindowCloses() {
        let defaults = InMemoryDefaults()
        defaults.set(true, forKey: VPhoneLaunchpadMenuBar.key)
        #expect(VPhoneLaunchpadMenuBar.isEnabled(defaults))
        #expect(!VPhoneLaunchpadMenuBar.terminatesAfterLastWindowClosed(defaults))
        defaults.set(false, forKey: VPhoneLaunchpadMenuBar.key)
        #expect(VPhoneLaunchpadMenuBar.terminatesAfterLastWindowClosed(defaults))
    }

    /// A launch argument leaves a string in the arguments domain.
    @Test func argumentStringsAreRead() {
        let defaults = InMemoryDefaults()
        for (value, enabled) in [("YES", true), ("true", true), ("1", true), ("NO", false), ("0", false), ("", false)] {
            defaults.set(value, forKey: VPhoneLaunchpadMenuBar.key)
            #expect(VPhoneLaunchpadMenuBar.isEnabled(defaults) == enabled, "\(value)")
        }
        defaults.set(NSNumber(value: 1), forKey: VPhoneLaunchpadMenuBar.key)
        #expect(VPhoneLaunchpadMenuBar.isEnabled(defaults))
    }

    @Test func dockIconFollowsWindowsAndMenusOnlyInMenuBarMode() {
        typealias M = VPhoneLaunchpadMenuBar
        for hasWindow in [false, true] {
            for menus in [0, 1] {
                #expect(M.dockPresence(menuBarEnabled: false, hasWindow: hasWindow, menusOpen: menus) == .regular)
            }
        }
        #expect(M.dockPresence(menuBarEnabled: true, hasWindow: true, menusOpen: 0) == .regular)
        #expect(M.dockPresence(menuBarEnabled: true, hasWindow: false, menusOpen: 1) == .regular)
        #expect(M.dockPresence(menuBarEnabled: true, hasWindow: false, menusOpen: 0) == .accessory)
    }
}

// MARK: - Menu entries (B6)

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct MenuBarEntryTests {
    @Test func onlyStartAndStopAreOffered() {
        #expect(VPhoneLaunchpadMenuBarEntry.Action.allCases == [.start, .startHeadless, .stop])
    }

    @Test func stoppedMachinesOfferStartAndRunningOnesStop() async throws {
        let standIn = try LaunchpadStandIn()
        try standIn.makeMachines(["alpha", "beta"])
        let library = await standIn.library()
        let alpha = standIn.path("alpha")
        let beta = standIn.path("beta")

        var entries = library.menuBarEntries
        #expect(entries.map(\.name) == ["alpha", "beta"])
        #expect(entries.allSatisfy { $0.actions == [.start, .startHeadless] && !$0.isRunning && $0.activity == nil })

        await library.performMenuBarAction(.startHeadless, on: alpha)
        let child = try #require(library.launchedProcess(alpha))
        #expect(await eventually { standIn.log("alpha").contains("serial alpha 1") })
        #expect(standIn.arguments.contains("vm launch alpha --library-root \(standIn.root) --headless"))
        entries = library.menuBarEntries
        #expect(entries.first { $0.path == alpha }?.actions == [.stop])
        #expect(entries.first { $0.path == alpha }?.isRunning == true)
        #expect(entries.first { $0.path == beta }?.actions == [.start, .startHeadless])

        // Stop on a stopped machine runs nothing.
        await library.performMenuBarAction(.stop, on: beta)
        #expect(!standIn.arguments.contains { $0.hasPrefix("vm stop beta") })

        // Start on a running machine runs nothing more.
        await library.performMenuBarAction(.start, on: alpha)
        #expect(standIn.arguments.filter { $0.hasPrefix("vm launch alpha") }.count == 1)

        // Stop goes through vm stop, then SIGINT to the own child, as the toolbar's Stop.
        await library.performMenuBarAction(.stop, on: alpha)
        let childStatus = await child.wait()
        #expect(childStatus == 130)
        #expect(standIn.arguments.contains("vm stop alpha --library-root \(standIn.root)"))
        #expect(standIn.arguments.contains("stop alpha saw no SIGINT"))
        #expect(await eventually { library.launchedProcess(alpha) == nil })
        #expect(library.menuBarEntries.first { $0.path == alpha }?.actions == [.start, .startHeadless])
    }

    /// Without a verified toolchain (no command line) nothing is offered.
    @Test func noActionsWithoutAToolchain() throws {
        let temp = try LaunchpadTemporaryDirectory("launchpad-menubar")
        let library = VPhoneLaunchpadMachineLibrary(
            defaults: InMemoryDefaults(), libraryRoot: temp.canonicalPath,
            logsDirectory: temp.url.appendingPathComponent("Logs"),
            runStateReader: VPhoneLaunchpadRunStateReader(readRecord: { _ in nil }, identity: { _ in nil })
        )
        #expect(library.menuBarEntries.isEmpty)
        #expect(!library.canStart(VPhoneLaunchpadMachinePath(libraryRoot: temp.canonicalPath, name: "m")))
    }
}

// MARK: - Recent Commands outcome (B6)

@MainActor
struct CommandOutcomeTests {
    @Test func doctorExitThreeIsAWarningAndOtherNonZeroStatusesFail() {
        let history = VPhoneLaunchpadCommandHistory()
        let doctor = VPhoneLaunchpadReadOnlyCommand.doctor(libraryRoot: "/fixture/VMs")!
        #expect(doctor.warningStatuses == [3])
        #expect(VPhoneLaunchpadReadOnlyCommand.helperStatus.warningStatuses.isEmpty)
        #expect(VPhoneLaunchpadReadOnlyCommand.coreBundleVerify(version: "2.2.3")!.warningStatuses.isEmpty)

        let expected: [(Set<Int32>, Int32?, VPhoneLaunchpadCommandOutcome)] = [
            (doctor.warningStatuses, nil, .running),
            (doctor.warningStatuses, 0, .succeeded),
            (doctor.warningStatuses, 3, .warning),
            (doctor.warningStatuses, 4, .failed),
            (doctor.warningStatuses, 5, .failed),
            (doctor.warningStatuses, 64, .failed),
            ([], 3, .failed),
            ([], 0, .succeeded),
            ([], 1, .failed),
        ]
        for (warnings, status, outcome) in expected {
            let id = history.record("vphone-cli fixture", warningStatuses: warnings)
            if let status {
                history.finish(id, status: status)
            }
            #expect(history.entries.last?.outcome == outcome, "\(warnings) \(String(describing: status))")
        }
    }

    /// Through the read-only entry point: doctor exit 3 is recorded as a
    /// warning, helper status exit 3 as a failure.
    @Test func readOnlyRunsRecordTheirWarningStatuses() async throws {
        let temp = try LaunchpadTemporaryDirectory("launchpad-outcome")
        let cli = try LaunchpadStandInCLI(in: temp.url)
        try cli.respond("doctor", output: "{}", status: 3)
        try cli.respond("helper", output: "Error: not configured", status: 3)
        let commandLine = cli.commandLine()
        _ = try await commandLine.run(try #require(VPhoneLaunchpadReadOnlyCommand.doctor(libraryRoot: "/fixture/VMs")))
        _ = try await commandLine.run(.helperStatus)
        try cli.respond("doctor", output: "{}", status: 4)
        _ = try await commandLine.run(try #require(VPhoneLaunchpadReadOnlyCommand.doctor(libraryRoot: "/fixture/VMs")))
        #expect(commandLine.history.entries.map(\.status) == [3, 3, 4])
        #expect(commandLine.history.entries.map(\.outcome) == [.warning, .failed, .failed])
    }
}
