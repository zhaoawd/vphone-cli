@testable import FirmwarePatcher
import Foundation
import Testing
import VPhoneCoreKit
import VPhonePatchKit

@Suite("Trusted darwinOS restore isolation")
struct CryptexTrustedDarwinOSTests {
    @Test func `only an explicitly selected phone or pad writes the restore environment`() throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let firmware = root.appending(path: "Firmware")
        try FileManager.default.createDirectory(at: firmware, withIntermediateDirectories: true)
        let component: PlistDict = ["Info": ["Path": "old"]]
        let input: PlistDict = ["BuildIdentities": [[
            FirmwareManifest.osEnvironmentKey: "0x06",
            "Manifest": ["OS": component, "StaticTrustCache": component,
                         "Ap,SystemVolumeCanonicalMetadata": component, "SystemVolume": component],
        ]]]
        let data = try PropertyListSerialization.data(fromPropertyList: input, format: .xml, options: 0)
        for family in [VPhoneGuestDevice.Family.iPhone, .iPad, .watch, .appleTV, .homePod, .homeView] {
            for enabled in [false, true] {
                let patcher = CryptexFilesystemPatcher(buildManiest: data, restoreDir: root, verbose: false)
                patcher.guestFamily = family
                let identifier = FirmwareRestoreImagePatchSet.trustedDarwinOS
                patcher.gate = VPhonePatchGate(declared: [identifier], enabled: enabled ? [identifier] : [])
                let output = try patcher.setUpdatedComponentsInManifest(
                    filesystem: root.appending(path: "System.dmg"),
                    trustcache: firmware.appending(path: "cache.im4p"),
                    metadata: firmware.appending(path: "metadata.im4p"),
                    rootHash: firmware.appending(path: "hash.im4p"),
                )
                let identities = try #require(output["BuildIdentities"] as? [PlistDict])
                let environment = identities[0][FirmwareManifest.osEnvironmentKey] as? String
                let applies = enabled && (family == .iPhone || family == .iPad)
                #expect(environment == (applies ? "0x06" : nil))
            }
        }
    }

    @Test func `trusted darwinOS removes only NRDUpdated from the launchd cache and repeats safely`() throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "launchd.plist")
        let kept: PlistDict = ["Label": "vphoned"]
        try CustomFirmwareDaemons.savePlist([
            "LaunchDaemons": [CryptexFilesystemPatcher.nrdUpdatedJob: ["Label": "NRDUpdated"], "vphoned": kept],
            "Other": "preserved",
        ], to: file)
        let patcher = makePatcher(root)
        for _ in 0 ..< 2 {
            try patcher.dropNRDUpdated(fromLaunchdCache: file)
            let output = try CustomFirmwareDaemons.loadPlist(file)
            #expect(output["Other"] as? String == "preserved")
            let jobs = try #require(output["LaunchDaemons"] as? PlistDict)
            #expect(Set(jobs.keys) == ["vphoned"])
            #expect(NSDictionary(dictionary: try #require(jobs["vphoned"] as? PlistDict)).isEqual(to: kept))
        }
    }
}
