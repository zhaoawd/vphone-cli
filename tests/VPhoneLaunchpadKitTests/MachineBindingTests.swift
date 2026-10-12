import VPhoneCore
import Foundation
import Testing
@testable import VPhoneLaunchpadKit

struct MachineBindingTests {
    @Test func targetFeatureMinimumAndSameSeriesAreSeparateFromLegacyStore() {
        #expect(VPhoneLaunchpadCoreBundleVersion.minimum == "2.2.0")
        #expect(!VPhoneLaunchpadCoreBundleVersion.supportsTargetFeatures("2.5.9-local.ab12cd34"))
        #expect(VPhoneLaunchpadCoreBundleVersion.supportsTargetFeatures("2.6.0"))
        #expect(VPhoneLaunchpadCoreBundleVersion.supportsSeries("2.6.7-ci.abcdef0", host: "2.6.1-local.ab12cd34"))
        #expect(!VPhoneLaunchpadCoreBundleVersion.supportsSeries("2.7.0", host: "2.6.1"))
        #expect(!VPhoneLaunchpadCoreBundleVersion.supportsSeries("2.5.9", host: "2.5.8"))
        #expect(!VPhoneLaunchpadCoreBundleVersion.supportsSeries("../../2.6.1", host: "2.6.1"))
    }

    @Test func legacyThreeLayerBindingKeepsKernelUnknownAndHostChangesPreserveOtherLayers() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let machine = VPhoneLaunchpadMachinePath(libraryRoot: temp.url.path, name: "vm")
        try FileManager.default.createDirectory(at: machine.url, withIntermediateDirectories: true)
        let data = Data(#"{"bundle":"2.6.1-local.ab12cd34","guestEnvironment":"2.5.9","bootChain":"2.2.3"}"#.utf8)
        try data.write(to: machine.url.appendingPathComponent("launchpad.json"))
        guard case let .loaded(binding) = VPhoneLaunchpadMachineBinding.load(machine) else {
            Issue.record("binding missing"); return
        }
        #expect(binding.kernel == nil)
        let changed = try binding.replacingHost(with: "2.6.2-local.cd34ef56")
        #expect(changed.bundle != binding.bundle)
        #expect(changed.guestEnvironment == binding.guestEnvironment)
        #expect(changed.kernel == binding.kernel)
        #expect(changed.bootChain == binding.bootChain)
        #expect(try Data(contentsOf: machine.url.appendingPathComponent("launchpad.json")) == data)
    }

    @Test func missingCorruptUnsupportedAndLinkedBindingsAreDistinctAndNeverRewritten() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let machine = VPhoneLaunchpadMachinePath(libraryRoot: temp.url.path, name: "vm")
        try FileManager.default.createDirectory(at: machine.url, withIntermediateDirectories: true)
        let file = machine.url.appendingPathComponent("launchpad.json")
        #expect(VPhoneLaunchpadMachineBinding.load(machine) == .missing)
        for bytes in [Data("invalid".utf8), Data(#"{"bundle":"../../evil"}"#.utf8),
                      Data(#"{"bundle":"2.6.1","kernel":"../../evil"}"#.utf8), Data(repeating: 0, count: 65537)] {
            try bytes.write(to: file)
            guard case .invalid = VPhoneLaunchpadMachineBinding.load(machine) else { Issue.record("invalid binding accepted"); continue }
            #expect(try Data(contentsOf: file) == bytes)
        }
        try FileManager.default.removeItem(at: file)
        let target = temp.url.appendingPathComponent("outside.json")
        let bytes = Data(#"{"bundle":"2.6.1"}"#.utf8)
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        guard case .invalid = VPhoneLaunchpadMachineBinding.load(machine) else { Issue.record("linked binding accepted"); return }
        #expect(try Data(contentsOf: target) == bytes)
    }
}

extension MachineBindingTests {
    @Test func pendingOriginBytesAreNotCommittedBindings() throws {
        let temp = try LaunchpadTemporaryDirectory()
        let machine = VPhoneLaunchpadMachinePath(libraryRoot: temp.url.path, name: "vm")
        try FileManager.default.createDirectory(at: machine.url, withIntermediateDirectories: true)
        try Data(#"{"bundle":"2.6.1","kernel":"2.6.2"}"#.utf8).write(to: machine.url.appendingPathComponent("launchpad.json"))
        let before = try #require(try VPhoneLaunchpadMachineBinding.snapshot(machine))
        let pending = machine.url.appendingPathComponent(".firmware-transaction")
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try VPhoneLaunchpadMachineBinding.snapshot(machine) }
        #expect(!before.matches(machine))
        guard case .invalid = VPhoneLaunchpadMachineBinding.load(machine) else {
            Issue.record("pending origin exposed"); return
        }
        try FileManager.default.removeItem(at: pending)
        #expect(throws: (any Error).self) {
            try VPhoneLaunchpadMachineBinding.snapshot(machine, afterRead: {
                try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: false)
                try FileManager.default.removeItem(at: pending)
            })
        }
        #expect(throws: (any Error).self) {
            try VPhoneLaunchpadMachineBinding.snapshot(machine, afterRead: {
                try FileManager.default.createSymbolicLink(at: pending, withDestinationURL: temp.url)
            })
        }
    }
}
