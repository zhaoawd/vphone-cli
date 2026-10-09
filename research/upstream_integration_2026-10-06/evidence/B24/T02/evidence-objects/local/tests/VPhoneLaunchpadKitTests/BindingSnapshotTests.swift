import VPhoneCore
import Foundation
import Testing
@testable import VPhoneLaunchpadKit

struct BindingSnapshotTests {
    @Test func snapshotFreezesBytesAndRefusesSameSizeRewriteAndReplacement() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let machine = VPhoneLaunchpadMachinePath(libraryRoot: temp.url.path, name: "vm")
        try FileManager.default.createDirectory(at: machine.url, withIntermediateDirectories: true)
        let url = machine.url.appendingPathComponent("launchpad.json")
        let old = Data(#"{"bundle":"2.6.1","guestEnvironment":"2.2.3","kernel":"2.6.0","bootChain":"2.2.3"}"#.utf8)
        try old.write(to: url)
        let snapshot = try #require(try VPhoneLaunchpadMachineBinding.snapshot(machine))
        #expect(snapshot.binding.bundle == "2.6.1")
        #expect(snapshot.sha256.count == 64)
        #expect(snapshot.matches(machine))
        try old.write(to: url)
        #expect(!snapshot.matches(machine))
        let replacement = Data(String(decoding: old, as: UTF8.self).replacingOccurrences(of: "2.6.1", with: "2.6.2").utf8)
        #expect(old.count == replacement.count)
        try replacement.write(to: url)
        #expect(!snapshot.matches(machine))
        #expect(snapshot.binding.bundle == "2.6.1")
        try FileManager.default.removeItem(at: url)
        try old.write(to: url)
        #expect(!snapshot.matches(machine))
    }

    @Test func inPlaceConcurrentMutationIsRefusedInsteadOfPublishingOldSelection() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let machine = VPhoneLaunchpadMachinePath(libraryRoot: temp.url.path, name: "vm")
        try FileManager.default.createDirectory(at: machine.url, withIntermediateDirectories: true)
        let url = machine.url.appendingPathComponent("launchpad.json")
        try Data(#"{"bundle":"2.6.1"}"#.utf8).write(to: url)
        #expect(throws: (any Error).self) {
            try VPhoneLaunchpadMachineBinding.snapshot(machine, afterRead: {
                try Data(#"{"bundle":"2.6.2"}"#.utf8).write(to: url)
            })
        }
    }

    @Test func missingAndInvalidSnapshotsNeverChooseDefault() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let machine = VPhoneLaunchpadMachinePath(libraryRoot: temp.url.path, name: "vm")
        try FileManager.default.createDirectory(at: machine.url, withIntermediateDirectories: true)
        #expect(try VPhoneLaunchpadMachineBinding.snapshot(machine) == nil)
        try Data(#"{"bundle":"../../escape"}"#.utf8).write(to: machine.url.appendingPathComponent("launchpad.json"))
        #expect(throws: (any Error).self) { try VPhoneLaunchpadMachineBinding.snapshot(machine) }
    }
}
