import Foundation
import Testing
import VPhoneCore
@testable import VPhoneLaunchpadKit

/// Exercises the real library, route and child lifecycle with isolated producer stand-ins.
/// It does not install or authenticate a root-owned Core Bundle.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct BundleChangeLibraryTests {
    private func fixture(updateExit: Int32 = 0) async throws -> (LaunchpadEditStandIn, VPhoneLaunchpadMachineLibrary, URL) {
        let standIn = try LaunchpadEditStandIn()
        try standIn.makeMachines(["phone"])
        let machine = standIn.path("phone").url
        try Data("ready\n".utf8).write(to: machine.appendingPathComponent("Disk.img"))
        try JSONEncoder().encode(VPhoneMachineBinding(bundle: "2.6.1", guestEnvironment: "2.6.0"))
            .write(to: machine.appendingPathComponent("launchpad.json"))
        var script = try String(contentsOf: standIn.script, encoding: .utf8)
        script = script.replacingOccurrences(of: "*) echo", with: """
        bind-core-bundle)
          printf '%s' '{"bundle":"2.6.2","guestEnvironment":"2.6.0"}' > "$root/$name/launchpad.json"
          echo 'bound' ;;
        *) echo
        """)
        try script.write(to: standIn.script, atomically: false, encoding: .utf8)
        let launcher = standIn.temp.url.appendingPathComponent("launcher")
        let log = standIn.temp.url.appendingPathComponent("launcher-arguments")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(log.path)'
        echo 'environment child'
        exit \(updateExit)
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let library = VPhoneLaunchpadMachineLibrary(defaults: InMemoryDefaults(), libraryRoot: standIn.root,
            logsDirectory: standIn.temp.url.appendingPathComponent("Logs"),
            runStateReader: VPhoneLaunchpadRunStateReader(readRecord: { _ in nil }, identity: { _ in nil }))
        library.startMonitoring(with: VPhoneLaunchpadCommandLine(executable: standIn.script, history: standIn.history, launcher: launcher))
        library.stopMonitoring()
        await library.refresh()
        return (standIn, library, log)
    }

    @Test(arguments: [Int32(0), Int32(9)])
    func bindsThenRunsOnlyTheSelectedProducer(updateExit: Int32) async throws {
        let (standIn, library, log) = try await fixture(updateExit: updateExit)
        let machine = standIn.path("phone")
        let previous = try #require(try VPhoneMachineBinding.snapshot(machine.url))
        var announcements = 0
        let result = await library.setBundle(machine, version: "2.6.2", updateEnvironment: true,
            workParent: standIn.temp.url.appendingPathComponent("work parent"),
            expectedBindingSHA256: previous.sha256, willUpdate: { announcements += 1 })
        #expect(result == (updateExit == 0 ? .updated : .boundButNotUpdated))
        #expect(announcements == 1)
        let selected = try #require(try VPhoneMachineBinding.snapshot(machine.url))
        #expect(selected.binding.bundle == "2.6.2")
        #expect(selected.binding.guestEnvironment == "2.6.0")
        let arguments = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(arguments == ["/Library/Application Support/vphone-launchpad/Bundles/2.6.2/VPhone.bundle/Contents/MacOS/vphone-cli",
            "cfw", "update-environment", "phone", "--library-root", standIn.root, "--root-popup",
            "--work-parent", standIn.temp.url.appendingPathComponent("work parent").path,
            "--expected-binding-sha256", selected.sha256])
        #expect(standIn.edits.count == 1)
        #expect(standIn.edits[0].hasPrefix("vm bind-core-bundle phone --version 2.6.2"))
        #expect(standIn.edits[0].contains(previous.sha256))
        #expect(library.actionError == nil || updateExit != 0)
        if updateExit != 0 {
            #expect(library.actionError?.detail?.contains("host binding was saved as 2.6.2") == true)
        }
    }

    @Test func hostBindingDoesNotStartAnEnvironmentChild() async throws {
        let (standIn, library, log) = try await fixture()
        let result = await library.setBundle(standIn.path("phone"), version: "2.6.2")
        #expect(result == .bound)
        #expect(!FileManager.default.fileExists(atPath: log.path))
        #expect(standIn.edits.count == 1)
    }

    @Test func diskReaderRefusesBeforeBindingAndIsNotStopped() async throws {
        let (standIn, library, log) = try await fixture()
        let machine = standIn.path("phone")
        let previous = try Data(contentsOf: machine.url.appendingPathComponent("launchpad.json"))
        let reader = Process()
        reader.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        reader.arguments = ["-c", "+1", "-f", machine.url.appendingPathComponent("Disk.img").path]
        let output = Pipe()
        reader.standardOutput = output
        try reader.run()
        defer { reader.terminate(); reader.waitUntilExit() }
        #expect(output.fileHandleForReading.readData(ofLength: 6) == Data("ready\n".utf8))
        let result = await library.setBundle(machine, version: "2.6.2", updateEnvironment: true)
        guard case let .refused(holders) = result else { Issue.record("expected disk refusal"); return }
        #expect(holders.map(\.pid) == [reader.processIdentifier])
        #expect(reader.isRunning)
        #expect(standIn.edits.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: log.path))
        #expect(try Data(contentsOf: machine.url.appendingPathComponent("launchpad.json")) == previous)
    }

    @Test func staleFrozenBindingRefusesBeforeSpawn() async throws {
        let (standIn, _, log) = try await fixture()
        let machine = standIn.path("phone").url
        let command = VPhoneLaunchpadCommandLine(executable: standIn.script, history: standIn.history,
            launcher: standIn.temp.url.appendingPathComponent("launcher"))
        var announced = false
        await #expect(throws: VPhoneLaunchpadError.self) {
            try await command.run(["cfw", "update-environment", "phone"], machine: machine,
                onStart: { announced = true }, expectedBindingSHA256: String(repeating: "0", count: 64))
        }
        #expect(!announced)
        #expect(!FileManager.default.fileExists(atPath: log.path))
    }

    @Test func cancellingTheEnvironmentChildRetainsThePublishedBinding() async throws {
        let (standIn, library, _) = try await fixture()
        let launcher = standIn.temp.url.appendingPathComponent("launcher")
        try """
        #!/bin/sh
        trap 'exit 130' INT
        while :; do sleep 0.03; done
        """.write(to: launcher, atomically: false, encoding: .utf8)
        let machine = standIn.path("phone")
        let result = await library.setBundle(machine, version: "2.6.2", updateEnvironment: true,
            willUpdate: { withUnsafeCurrentTask { $0?.cancel() } })
        #expect(result == .boundButNotUpdated)
        #expect(try VPhoneMachineBinding.snapshot(machine.url)?.binding.bundle == "2.6.2")
        #expect(library.actionError?.detail?.contains("host binding was saved as 2.6.2") == true)
        #expect(standIn.history.entries.allSatisfy { $0.outcome != .running })
    }
}
