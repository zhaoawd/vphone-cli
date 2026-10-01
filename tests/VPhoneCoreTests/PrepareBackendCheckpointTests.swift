import Foundation
import Testing
@testable import VPhoneCore

struct PrepareBackendCheckpointTests {
    @Test func historicalEncodingDigestAndBackendStage() throws {
        let legacy = Data("""
        {"variant":"regular","force_dsc_max_slide":false,"enable_frida":false,"cpu_count":8,"memory_mb":8192,"disk_size_gb":64}
        """.utf8)
        let decoded = try VPhoneCreateJSON.decoder.decode(VPhoneCreateEffectiveOptions.self, from: legacy)
        let expected = VPhoneCreateEffectiveOptions(variant: "regular", iphoneSource: nil, cloudosSource: nil,
            spoofBuild: nil, forceDscMaxSlide: false, enableFrida: false, cpuCount: 8, memoryMb: 8192, diskSizeGb: 64)
        #expect(decoded.effectivePrepareBackend == .script)
        #expect(decoded.digest == expected.digest)
        let encoded = try VPhoneCreateJSON.encoder.encode(decoded)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object.count == 6)
        #expect(object["prepare_backend"] == nil)
        var native = decoded
        native.prepareBackend = .native
        #expect(native.digest != decoded.digest)
        let change = try #require(decoded.changes(to: native).first)
        #expect(change.field == "prepare_backend")
        #expect(change.stage == .prepare)
        let roundTrip = try VPhoneCreateJSON.decoder.decode(VPhoneCreateEffectiveOptions.self,
            from: VPhoneCreateJSON.encoder.encode(native))
        #expect(roundTrip.effectivePrepareBackend == .native)
    }
}
