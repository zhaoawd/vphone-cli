import Foundation
import Testing
import VPhoneCore
@testable import VPhoneLaunchpadKit

struct MachineSnapshotsTests {
    // MARK: - vm snapshot list --json

    @Test func snapshotListDecodesAndRejectsMalformedPayloads() throws {
        let json = #"[{"created":"2026-10-06T14:30:00Z","name":"fresh","note":"before frida"},{"created":"2026-10-06T15:00:00Z","name":"second"}]"#
        let snapshots = try VPhoneLaunchpadMachineSnapshot.list(from: Data(json.utf8))
        #expect(snapshots.map(\.name) == ["fresh", "second"])
        #expect(snapshots[0].note == "before frida")
        #expect(snapshots[1].note == nil)
        #expect(snapshots[0].created == Date(timeIntervalSince1970: 1_791_297_000))
        #expect(snapshots[0].id == "fresh")

        let empty = try VPhoneLaunchpadMachineSnapshot.list(from: Data("[]".utf8))
        #expect(empty.isEmpty)

        for bad in [
            #"[{"created":"yesterday","name":"x"}]"#,
            #"[{"created":"2026-10-06T14:30:00Z"}]"#,
            #"{"name":"x"}"#,
        ] {
            #expect((try? VPhoneLaunchpadMachineSnapshot.list(from: Data(bad.utf8))) == nil, "Rejected list: \(bad)")
        }

        let result = VPhoneLaunchpadCommandResult(status: 0, lines: ["warning: something", json])
        let afterWarning = try VPhoneLaunchpadMachineSnapshot.list(from: try #require(result.jsonData))
        #expect(afterWarning.count == 2)
    }

    // MARK: - Default names

    @Test func defaultNamesFollowMachineNameRulesAndIncrementOnCollision() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let date = Date(timeIntervalSince1970: 1_791_297_000) // 22:30 in Shanghai
        let name = VPhoneLaunchpadMachineSnapshot.defaultName(at: date, taken: [], calendar: calendar)
        #expect(name == "2026-10-06-2230")
        #expect(VPhoneLaunchpadMachineName.isValidNewName(name))
        let next = VPhoneLaunchpadMachineSnapshot.defaultName(
            at: date,
            taken: ["2026-10-06-2230", "2026-10-06-2230-2"],
            calendar: calendar
        )
        #expect(next == "2026-10-06-2230-3")
    }

    // MARK: - Arguments

    @Test func cloneAndSnapshotArguments() {
        let machine = VPhoneLaunchpadMachinePath(libraryRoot: "/Volumes/Lab/machines", name: "frida-lab")
        let library = ["--library-root", "/Volumes/Lab/machines"]

        #expect(machine.cloneArguments(as: "frida-lab-clone", newIdentity: true)
            == ["vm", "clone", "frida-lab", "frida-lab-clone", "--new-identity"] + library)
        #expect(machine.cloneArguments(as: "frida-lab-clone", newIdentity: false)
            == ["vm", "clone", "frida-lab", "frida-lab-clone"] + library)
        #expect(VPhoneLaunchpadEditCommand.clone(machine, as: "frida-lab-clone", newIdentity: true)?.arguments
            == ["vm", "clone", "frida-lab", "frida-lab-clone", "--new-identity"] + library)

        #expect(machine.snapshotListArguments == ["vm", "snapshot", "list", "frida-lab", "--json"] + library)
        #expect(machine.snapshotCreateArguments("fresh", note: nil)
            == ["vm", "snapshot", "create", "frida-lab", "fresh"] + library)
        #expect(machine.snapshotCreateArguments("fresh", note: "  \n ")
            == ["vm", "snapshot", "create", "frida-lab", "fresh"] + library)
        #expect(machine.snapshotCreateArguments("fresh", note: " -before frida ")
            == ["vm", "snapshot", "create", "frida-lab", "fresh", "--note=-before frida"] + library)
        #expect(machine.snapshotRevertArguments("fresh")
            == ["vm", "snapshot", "revert", "frida-lab", "fresh", "--force"] + library)
        #expect(machine.snapshotDeleteArguments("fresh")
            == ["vm", "snapshot", "delete", "frida-lab", "fresh", "--force"] + library)
    }

    // MARK: - Binding saved with a snapshot

    @Test func bindingSidecarRoundTripsRefusesSymlinksAndReconcilesFourLayers() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "machine-snapshots-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        let machine = VPhoneLaunchpadMachinePath(libraryRoot: root.path, name: "research-01")
        let snapshots = machine.url.appendingPathComponent("Snapshots", isDirectory: true)
        try fileManager.createDirectory(at: machine.url, withIntermediateDirectories: true)

        let taken = try VPhoneLaunchpadMachineBinding(
            bundle: "2.7.0",
            guestEnvironment: "2.6.1",
            kernel: "2.6.0",
            bootChain: "2.6.0"
        )

        #expect(VPhoneLaunchpadMachineBinding.url(for: machine, snapshot: "fresh") == nil)
        #expect((try? taken.save(to: machine, snapshot: "fresh")) == nil)

        try fileManager.createDirectory(at: snapshots.appendingPathComponent("fresh"), withIntermediateDirectories: true)
        try taken.save(to: machine, snapshot: "fresh")
        let sidecar = snapshots.appendingPathComponent("fresh/launchpad.json")
        #expect(fileManager.fileExists(atPath: sidecar.path))
        #expect(VPhoneLaunchpadMachineBinding.load(machine, snapshot: "fresh") == taken)
        #expect(VPhoneLaunchpadMachineBinding.load(machine) == .missing)

        let current = try VPhoneLaunchpadMachineBinding(
            bundle: "2.7.1-local.ab12cd34",
            guestEnvironment: "2.7.1-local.ab12cd34",
            kernel: "2.7.1-local.ab12cd34",
            bootChain: "2.7.0"
        )
        let reverted = current.reverted(to: taken)
        #expect(reverted == (try VPhoneLaunchpadMachineBinding(
            bundle: "2.7.1-local.ab12cd34",
            guestEnvironment: "2.6.1",
            kernel: "2.6.0",
            bootChain: "2.6.0"
        )))
        #expect(reverted.hasMixedVersions)
        #expect(try current.reverted(to: VPhoneLaunchpadMachineBinding(bundle: "2.7.0")).guestEnvironment == nil)
        #expect(try current.reverted(to: VPhoneLaunchpadMachineBinding(bundle: "2.7.0")).kernel == nil)

        let unsaved = current.reverted(to: nil)
        #expect(unsaved == (try VPhoneLaunchpadMachineBinding(bundle: "2.7.1-local.ab12cd34")))
        #expect(!unsaved.hasMixedVersions)
        #expect(VPhoneLaunchpadMachineBinding.load(machine, snapshot: "missing") == nil)
        #expect(current.reverted(to: VPhoneLaunchpadMachineBinding.load(machine, snapshot: "fresh")) == reverted)

        try Data(#"{"bundle":"2.7.0","guestEnvironment":"../evil"}"#.utf8).write(to: sidecar)
        #expect(VPhoneLaunchpadMachineBinding.load(machine, snapshot: "fresh") == nil)
        #expect(current.reverted(to: VPhoneLaunchpadMachineBinding.load(machine, snapshot: "fresh")) == unsaved)

        for name in ["", ".", "..", "../research-02", "a/b", ".hidden"] {
            #expect(VPhoneLaunchpadMachineBinding.url(for: machine, snapshot: name) == nil, "Rejected: \(name)")
        }
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try fileManager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: snapshots.appendingPathComponent("linked"),
            withDestinationURL: elsewhere
        )
        #expect(VPhoneLaunchpadMachineBinding.url(for: machine, snapshot: "linked") == nil)
        #expect((try? taken.save(to: machine, snapshot: "linked")) == nil)
        #expect(!fileManager.fileExists(atPath: elsewhere.appendingPathComponent("launchpad.json").path))

        let otherMachine = VPhoneLaunchpadMachinePath(libraryRoot: root.path, name: "research-02")
        try fileManager.createDirectory(at: otherMachine.url, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: otherMachine.url.appendingPathComponent("Snapshots"),
            withDestinationURL: snapshots
        )
        #expect(VPhoneLaunchpadMachineBinding.url(for: otherMachine, snapshot: "fresh") == nil)
    }
}
