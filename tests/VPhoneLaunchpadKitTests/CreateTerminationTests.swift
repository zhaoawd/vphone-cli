import Foundation
import Testing
@testable import VPhoneLaunchpadKit

@MainActor
struct CreateTerminationTests {
    @Test func confirmedQuitIncludesCreateGroupAndLogDrain() async throws {
        let standIn = try CreateStandIn()
        try standIn.mode(create: "hang")
        let library = await standIn.library()
        let creation = try #require(library.create(standIn.request("quit-create")))
        defer { creation.cancel() }
        try #require(await eventually { standIn.pids.count == 3 })
        let command = try #require(library.currentCommandLine)
        #expect(command.hasActiveCommands)
        VPhoneLaunchpadQuit.confirmed(library)
        #expect(command.beginTermination())
        #expect(await command.waitForTermination() == .drained)
        #expect(!creation.isRunning)
        #expect(standIn.pids.allSatisfy(isGone))
        #expect(command.history.entries.first?.outputDrained == true)
        #expect(command.history.entries.first?.status != nil)
    }

    @Test func uncooperativeCreateCancelsQuitAndKeepsItsLogUntilCompletion() async throws {
        let standIn = try CreateStandIn()
        let release = standIn.control.appendingPathComponent("release")
        defer { try? Data().write(to: release) }
        var script = try String(contentsOf: standIn.script, encoding: .utf8)
        // Test-only stand-in retains stdout and ignores the same SIGINT used
        // by production. Releasing it lets every failed assertion clean up.
        let marker = "case \"$1 $2\" in"
        script = script.replacingOccurrences(of: marker, with: """
        if [ "$1 $2" = "vm create" ]; then
          trap '' INT
          echo "create ready"
          : > "\(standIn.control.path)/ready"
          while [ ! -e "\(release.path)" ]; do sleep 0.02; done
          printf 'create final tail'
          exit 0
        fi
        \(marker)
        """)
        try script.write(to: standIn.script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: standIn.script.path)
        let library = await standIn.library()
        let creation = try #require(library.create(standIn.request("stubborn")))
        try #require(await eventually { FileManager.default.fileExists(atPath: standIn.control.appendingPathComponent("ready").path) })
        let command = try #require(library.currentCommandLine)
        VPhoneLaunchpadQuit.confirmed(library)
        #expect(command.beginTermination())
        #expect(await command.waitForTermination(timeout: .milliseconds(100)) == .timedOut)
        #expect(command.hasActiveCommands)
        #expect(creation.isRunning)
        #expect(command.history.entries.first?.status == nil)
        try Data().write(to: release)
        #expect(await eventually { !creation.isRunning && command.history.entries.first?.outputDrained == true })
        #expect(try String(contentsOf: creation.logFile, encoding: .utf8).hasSuffix("create final tail"))
    }
}
