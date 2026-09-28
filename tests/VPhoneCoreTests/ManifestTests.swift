@testable import VPhoneCore
import Foundation
import Testing

struct ManifestTests {
    @Test func versionedManifestIsRejectedAndReportedWithoutRewriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundle = root.appendingPathComponent("versioned")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = bundle.appendingPathComponent("config.plist")
        try sampleManifest().write(to: config)
        var plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: config), format: nil) as? [String: Any])
        for value: Any in [2, 99, "2", true] {
            plist["schemaVersion"] = value
            let bytes = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try bytes.write(to: config)
            #expect(throws: (any Error).self) { try VPhoneBundle.load(at: bundle) }
            let scan = try VPhoneLibrary(root: root).scan()
            #expect(scan.bundles.isEmpty)
            #expect(scan.skipped.count == 1)
            #expect(scan.skipped.first?.reason.contains("schema") == true)
            #expect(try Data(contentsOf: config) == bytes)
        }
    }

    private func sampleManifest() -> VPhoneVirtualMachineManifest {
        VPhoneVirtualMachineManifest(
            cpuCount: 8,
            memorySize: 8 * 1024 * 1024 * 1024,
            romImages: .init(avpBooter: "AVPBooter.vresearch1.bin",
                             avpSEPBooter: "AVPSEPBooter.vresearch1.bin")
        )
    }

    @Test func roundTripsThroughPlist() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("config.plist")
        try sampleManifest().write(to: url)
        let loaded = try VPhoneVirtualMachineManifest.load(from: url)

        #expect(loaded.cpuCount == 8)
        #expect(loaded.memorySize == 8 * 1024 * 1024 * 1024)
        #expect(loaded.romImages?.avpBooter == "AVPBooter.vresearch1.bin")
    }

    @Test func updatingReplacesOnlyGivenFields() {
        let updated = sampleManifest().updating(cpuCount: 4, memorySize: nil, screenConfig: nil)
        #expect(updated.cpuCount == 4)
        #expect(updated.memorySize == 8 * 1024 * 1024 * 1024)
        // networkConfig is preserved when not passed.
        #expect(updated.networkConfig.mode == .nat)
    }

    @Test func networkConfigRoundTripsThroughPlist() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let net = VPhoneVirtualMachineManifest.NetworkConfig(
            mode: .bridged, macAddress: "", bridgeInterface: "en0")
        let url = dir.appendingPathComponent("config.plist")
        try sampleManifest().updating(networkConfig: net).write(to: url)
        let loaded = try VPhoneVirtualMachineManifest.load(from: url)

        #expect(loaded.networkConfig.mode == .bridged)
        #expect(loaded.networkConfig.bridgeInterface == "en0")
    }

    // Manifests written before bridgeInterface existed omit that key; they must
    // still decode, with bridgeInterface defaulting to nil.
    @Test func decodesManifestWithoutBridgeInterfaceKey() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("config.plist")
        try sampleManifest().write(to: url)  // default network → bridgeInterface nil
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("bridgeInterface"))  // nil optional is omitted from the plist

        let loaded = try VPhoneVirtualMachineManifest.load(from: url)
        #expect(loaded.networkConfig.bridgeInterface == nil)
    }
}
