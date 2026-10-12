import Foundation
import Testing
@testable import VPhoneCore

struct GuestEnvironmentCheckpointTests {
    @Test func v2IsAcceptedOnlyForRegular() throws {
        for variant in ["regular", "dev", "jb", "exp", "less"] {
            let options = VPhoneCreateEffectiveOptions(variant: variant, iphoneSource: nil, cloudosSource: nil,
                spoofBuild: nil, forceDscMaxSlide: false, enableFrida: false, cpuCount: 8, memoryMb: 8192,
                diskSizeGb: 64, guestEnvironment: .v2)
            let checkpoint = VPhoneCreateCheckpoint(identity: .init(name: "test", path: "/tmp/test", directoryId: "1:1"),
                options: options, tool: .init(executableSha256: nil, stageContractVersion: VPhoneCreateCheckpoint.stageContractVersion), now: Date())
            if variant == "regular" {
                try checkpoint.validate()
            } else {
                #expect(throws: VPhoneCreateCheckpointError.self) { try checkpoint.validate() }
            }
        }
    }

    @Test func historicalOptionsKeepDigestAndEnvironmentChangesBeginAtCFW() throws {
        let legacy = Data("""
        {"variant":"regular","force_dsc_max_slide":false,"enable_frida":false,"cpu_count":8,"memory_mb":8192,"disk_size_gb":64}
        """.utf8)
        let decoded = try VPhoneCreateJSON.decoder.decode(VPhoneCreateEffectiveOptions.self, from: legacy)
        let expected = VPhoneCreateEffectiveOptions(variant: "regular", iphoneSource: nil, cloudosSource: nil,
            spoofBuild: nil, forceDscMaxSlide: false, enableFrida: false, cpuCount: 8, memoryMb: 8192,
            diskSizeGb: 64, guestEnvironment: .classic)
        #expect(decoded.effectiveGuestEnvironment == .classic)
        #expect(decoded.digest == expected.digest)
        // Historical encoder: six keys, pretty-printed and sorted, without a profile key.
        let legacyObject = try JSONSerialization.jsonObject(with: legacy)
        let historicalEncoding = try JSONSerialization.data(withJSONObject: legacyObject, options: [.prettyPrinted, .sortedKeys])
        #expect(decoded.digest == VPhoneCreateDigest.sha256(historicalEncoding))
        let object = try #require(JSONSerialization.jsonObject(with: VPhoneCreateJSON.encoder.encode(expected)) as? [String: Any])
        #expect(object.count == 6)
        #expect(object["guest_environment"] == nil)
        var v2 = decoded
        v2.guestEnvironment = .v2
        #expect(v2.digest != decoded.digest)
        let change = try #require(decoded.changes(to: v2).first)
        #expect(change.field == "guest_environment")
        #expect(change.stage == .cfw)
        #expect(try VPhoneCreateJSON.decoder.decode(VPhoneCreateEffectiveOptions.self,
            from: VPhoneCreateJSON.encoder.encode(v2)).effectiveGuestEnvironment == .v2)
    }
}
