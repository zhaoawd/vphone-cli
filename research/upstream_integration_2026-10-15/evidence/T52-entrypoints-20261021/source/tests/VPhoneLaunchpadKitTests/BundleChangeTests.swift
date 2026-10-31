import Darwin
import Foundation
import Testing
import VPhoneCore
@testable import VPhoneLaunchpadKit

@MainActor
struct BundleChangeTests {
    @Test func explicitArgumentsPreservePathsAndNeverPromptOnATerminal() throws {
        let machine = VPhoneLaunchpadMachinePath(libraryRoot: "/vm library", name: "phone")
        let args = try #require(VPhoneLaunchpadBundleChange.bindingArguments(machine, version: "2.6.2",
            backup: URL(fileURLWithPath: "/backup parent/new"), expectedSHA256: "missing"))
        #expect(args == ["vm", "bind-core-bundle", "phone", "--version", "2.6.2", "--library-root", "/vm library", "--backup", "/backup parent/new", "--expected-binding-sha256", "missing"])
        #expect(VPhoneLaunchpadBundleChange.environmentArguments(machine, workParent: URL(fileURLWithPath: "/private/tmp/work parent"))
            == ["cfw", "update-environment", "phone", "--library-root", "/vm library", "--root-popup", "--work-parent", "/private/tmp/work parent"])
        #expect(VPhoneLaunchpadBundleChange.bindingArguments(machine, version: "2.0.8", backup: nil) == nil)
        #expect(VPhoneLaunchpadBundleChange.bindingArguments(machine, version: "2.6.2", backup: nil, expectedSHA256: "bad") == nil)
    }

    @Test func cancellationAfterBindingDoesNotStartEnvironmentUpdate() async throws {
        var bound = false
        var updated = false
        let task = Task { @MainActor in
            try await VPhoneLaunchpadBundleChange.perform(updatesEnvironment: true,
                diskHolders: { [] }, bind: {
                    bound = true
                    withUnsafeCurrentTask { $0?.cancel() }
                }, updateEnvironment: { updated = true; return true })
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(bound && !updated)
    }

    private let holder = VPhoneProcessHolder(pid: 42, executablePath: "/bin/tail")

    @Test func heldDiskRefusesBeforeBindingOrUpdate() async throws {
        var calls: [String] = []
        let result = try await VPhoneLaunchpadBundleChange.perform(updatesEnvironment: true,
            diskHolders: { calls.append("inspect"); return [holder] },
            bind: { calls.append("bind") }, updateEnvironment: { calls.append("update"); return true })
        #expect(result == .refused([holder]))
        #expect(calls == ["inspect"])
    }

    @Test func failedUpdateRetainsNewBinding() async throws {
        var calls: [String] = []
        let result = try await VPhoneLaunchpadBundleChange.perform(updatesEnvironment: true,
            diskHolders: { calls.append("inspect"); return [] },
            bind: { calls.append("bind") }, updateEnvironment: { calls.append("update"); return false })
        #expect(result == .boundButNotUpdated)
        #expect(calls == ["inspect", "bind", "update"])
    }

    @Test func bindFailureStopsUpdateAndHostOnlyChangeSkipsInspection() async throws {
        var updated = false
        await #expect(throws: VPhoneLaunchpadError.self) {
            try await VPhoneLaunchpadBundleChange.perform(updatesEnvironment: true,
                diskHolders: { [] }, bind: { throw VPhoneLaunchpadError("not writable") },
                updateEnvironment: { updated = true; return true })
        }
        #expect(!updated)
        let result = try await VPhoneLaunchpadBundleChange.perform(updatesEnvironment: false,
            diskHolders: { Issue.record("unexpected disk inspection"); return [holder] }, bind: {},
            updateEnvironment: { Issue.record("unexpected update"); return true })
        #expect(result == .bound)
    }

    @Test func parsesLsofProcessRecordsAndExcludesOwnPID() {
        let output = "p100\nn/vm/Disk.img\np200\nn/vm/Disk.img\nn/vm/Disk.img\np300\nccommand\npbad\nn/ignored\n"
        #expect(VPhoneLaunchpadDiskHolders.parse(output, excluding: 100) == [200])
    }

    @Test func actualLsofExcludesOwnReaderAndFindsAnExternalReader() throws {
        let temp = try LaunchpadTemporaryDirectory("bundle-change-holders")
        let disk = temp.url.appendingPathComponent("Disk.img")
        try Data("ready\n".utf8).write(to: disk)
        let ownFD = open(disk.path, O_RDONLY)
        try #require(ownFD >= 0)
        defer { close(ownFD) }
        #expect(try VPhoneLaunchpadDiskHolders.read(disk).isEmpty)

        let reader = Process()
        reader.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        reader.arguments = ["-c", "+1", "-f", disk.path]
        let output = Pipe()
        reader.standardOutput = output
        try reader.run()
        defer { reader.terminate(); reader.waitUntilExit() }
        #expect(output.fileHandleForReading.readData(ofLength: 6) == Data("ready\n".utf8))
        let found = try VPhoneLaunchpadDiskHolders.read(disk)
        #expect(found.map(\.pid) == [reader.processIdentifier])
        #expect(found.first?.kind == .other)
    }

    @Test func startAnnouncementRequiresSuccessfulSpawn() async throws {
        let history = VPhoneLaunchpadCommandHistory()
        let missing = VPhoneLaunchpadCommandLine(executable: URL(fileURLWithPath: "/missing-\(UUID().uuidString)"), history: history)
        var announced = false
        do {
            _ = try await missing.run([], onStart: { announced = true })
            Issue.record("missing executable unexpectedly started")
        } catch {}
        #expect(!announced)
        let command = VPhoneLaunchpadCommandLine(executable: URL(fileURLWithPath: "/usr/bin/true"), history: history)
        _ = try await command.run([], onStart: { announced = true })
        #expect(announced)
    }
}
