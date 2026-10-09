import Foundation
import Testing
import VPhoneCore
@testable import vphone_cli

struct ExpectedBindingCLITests {
    @Test func unknownVMProtocolIsRefusedBeforeExecution() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let binary = root.appendingPathComponent("Contents/MacOS/vphone-vm")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info = root.appendingPathComponent("Contents/Info.plist")
        for value in ["", "unknown", "vphone.local-bound-launch.v1"] {
            try PropertyListSerialization.data(fromPropertyList: ["VPhoneBoundLaunchProtocol": value], format: .xml, options: 0).write(to: info)
            if value == "vphone.local-bound-launch.v1" { try VPhoneVMLaunchCommand.validateBoundLaunchProtocol(binary: binary) }
            else { #expect(throws: (any Error).self) { try VPhoneVMLaunchCommand.validateBoundLaunchProtocol(binary: binary) } }
        }
    }

    @Test func localWrapperRequiresTheExactBindingAndBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("launchpad.json")
        try Data(#"{"bundle":"2.6.1-local.12345678"}"#.utf8).write(to: path)
        let snapshot = try #require(try VPhoneMachineBinding.snapshot(root))
        let command = try VPhoneVMLaunchCommand.parse(["vm", "--expected-binding-sha256", snapshot.sha256,
                                                     "--expected-core-bundle", snapshot.binding.bundle])
        try command.validateExpectedBinding(snapshot)
        #expect(throws: (any Error).self) { try command.validateExpectedBinding(nil) }
        try Data(#"{"bundle":"2.6.2"}"#.utf8).write(to: path)
        #expect(throws: (any Error).self) { try command.validateExpectedBinding(VPhoneMachineBinding.snapshot(root)) }
        let wrongVersion = try VPhoneVMLaunchCommand.parse(["vm", "--expected-binding-sha256", snapshot.sha256,
                                                          "--expected-core-bundle", "2.6.2"])
        #expect(throws: (any Error).self) { try wrongVersion.validateExpectedBinding(snapshot) }
    }
}
